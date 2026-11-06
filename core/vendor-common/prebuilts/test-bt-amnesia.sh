#!/bin/bash
# Bluetooth amnesia control test (#154 / DIA-20260807-01) -- run against a connected device.
#
# WHY THIS EXISTS. The #154 bond roam/wipe was proven on a permissive userdebug lynx, then shipped into an
# ENFORCING endospore_priv world without the bluetooth sepolicy its own source comment asked for. It went inert
# in both directions -- bonds neither roamed with a profile nor cleared between sessions -- and kept logging
# "bt bonds wiped at logoff" the whole time. Nothing caught it because nothing ever asserted the OUTCOME.
#
# So this test exercises the code that is ACTUALLY INSTALLED: it lifts the BT block straight out of the
# device's /system/bin/nowhere_roamd.sh and evals it. A stale flash, a half-applied hot-patch, or a missing
# sepolicy grant all show up here as a failing assertion rather than as a reassuring log line.
#
# Usage: test-bt-amnesia.sh [serial]        (needs adb root; safe -- it only touches /data/misc/bluedroid,
#                                            which the Bluetooth stack rebuilds, and restores BT to OFF)
set -uo pipefail
# Git-bash/MSYS rewrites anything that looks like a unix path in an argument, so `adb push x /data/local/tmp/y`
# lands at "C:/Program Files/Git/data/local/tmp/y" and the push fails. Harmless everywhere else.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
ADB="adb${1:+ -s $1}"
$ADB root >/dev/null 2>&1; sleep 2

REMOTE=/data/local/tmp/bt-amnesia-test.sh
TMP=$(mktemp)
# ...and with conversion off, the LOCAL argument now needs it: adb is a Windows binary and cannot open a
# /tmp path. cygpath exists only under git-bash/cygwin, so this is a no-op on Linux and macOS.
LOCAL="$TMP"; command -v cygpath >/dev/null 2>&1 && LOCAL=$(cygpath -w "$TMP")
cat > "$TMP" <<'HARNESS'
#!/system/bin/sh
LOG=/data/local/tmp/bt-amnesia.log; STATE=/data/local/tmp/bt-amnesia-state
mkdir -p "$STATE"; : > "$LOG"
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
        else echo "  FAIL  $1: expected '$2' got '$3'"; fail=$((fail+1)); fi; }

# Lift the BT block out of the INSTALLED roamd, BY NAME: the four variables, the one-line bt_state, and each
# brace-terminated function from its `NAME() {` line to its first `}` line. This used to take whatever followed
# BT_DIR= up to the fourth `^}$`, so inserting ANY function in that stretch broke it -- NWP-20260914-04 put
# nav_seal_capture there, the count stopped short of bt_seal_capture and bt_reset, and from 2026-09-14 until
# NWP-20261011-51 the test failed "stale image?" on every correct image: a month in which it could not run.
# A moved anchor now fails by name as an EXTRACTION failure. Plain BRE only: toybox sed has no \| \+ \?.
ROAMD=/system/bin/nowhere_roamd.sh
[ -r "$ROAMD" ] || { echo "  FAIL  cannot read $ROAMD"; exit 1; }
BLOCK=$(sed -n '/^BT_DIR=/p; /^BT_APP_DIRS=/p; /^BT_FILES=/p; /^BT_NAME_KEYS=/p
/^bt_state() {/p
/^bt_default_name() {$/,/^}$/p
/^_bt_state_ok() {$/,/^}$/p
/^_bt_wait_off() {$/,/^}$/p
/^bt_seal_capture() {$/,/^}$/p
/^bt_reset() {$/,/^}$/p' "$ROAMD")
for _n in BT_DIR= BT_APP_DIRS= BT_FILES= BT_NAME_KEYS= \
          'bt_state() {' 'bt_default_name() {' '_bt_state_ok() {' '_bt_wait_off() {' \
          'bt_seal_capture() {' 'bt_reset() {'; do
  case "$BLOCK" in
    "$_n"*|*"
$_n"*) ;;
    *) echo "  FAIL  EXTRACTION FAILED -- ${_n%%[=\(]*} not found in $ROAMD (an anchor moved, or the image predates it)"
       _miss=1;;
  esac
done
[ -z "${_miss:-}" ] || exit 1
eval "$BLOCK"

echo "== the adapter is reachable at all (the grant that was missing) =="
S=$(bt_state); chk "bt_state parses" 0 "$(_bt_state_ok "$S"; echo $?)"
echo "   state=$S"

echo "== a wipe removes EVERYTHING under bluedroid, not just the two named files =="
printf '[Info]\nx=1\n\n[AA:BB:CC:DD:EE:FF]\nLinkKey = deadbeef\n' > "$BT_DIR/bt_config.conf"
printf '[00:00:00:00:00:00]\nx=1\n' > "$BT_DIR/bt_remote_dev_info.conf"
printf 'x\n' > "$BT_DIR/bt_config.bak"
printf 'x\n' > "$BT_DIR/some_unenumerated_file.conf"
bt_reset ""; chk "wipe rc" 0 $?
chk "bluedroid empty" "" "$(ls -A "$BT_DIR" 2>/dev/null)"

echo "== capture takes WHOLE files (the [Adapter] block is load-bearing: without it, Bonded devices: 0) =="
PROF=/data/local/tmp/bt-amnesia-prof; rm -rf "$PROF"; mkdir -p "$PROF/com.nowhere.chooser/files"
printf '[Info]\nx=1\n\n[Adapter]\nAddress = 11:22:33:44:55:66\n\n[11:22:33:44:55:66]\nLinkKey = cafe\n' > "$BT_DIR/bt_config.conf"
bt_seal_capture "$PROF"; chk "capture rc" 0 $?
chk "byte-identical copy" 0 "$(cmp -s "$BT_DIR/bt_config.conf" "$PROF/com.nowhere.chooser/files/bt-bond-bt_config"; echo $?)"
chk "[Adapter] carried"   1 "$(grep -c '^\[Adapter\]' "$PROF/com.nowhere.chooser/files/bt-bond-bt_config")"

echo "== login: a foreign leftover is destroyed, this profile's own state comes back =="
printf 'SOMEONE ELSE\n' > "$BT_DIR/bt_config.conf"
printf 'FOREIGN\n'      > "$BT_DIR/bt_remote_dev_info.conf"
bt_reset "$PROF"; chk "reset rc" 0 $?
chk "restored count"   1 "$BT_RESTORED"
chk "foreign destroyed" 0 "$(grep 'SOMEONE ELSE' "$BT_DIR/bt_config.conf" 2>/dev/null | wc -l | tr -d ' ')"
chk "ours restored"     0 "$(cmp -s "$PROF/com.nowhere.chooser/files/bt-bond-bt_config" "$BT_DIR/bt_config.conf"; echo $?)"
chk "foreign sibling gone" 0 "$([ -e "$BT_DIR/bt_remote_dev_info.conf" ] && echo 1 || echo 0)"
chk "owner"  bluetooth          "$(stat -c %U "$BT_DIR/bt_config.conf" 2>/dev/null)"
chk "label"  bluetooth_data_file "$(ls -Z "$BT_DIR/bt_config.conf" 2>/dev/null | awk '{print $1}' | cut -d: -f3)"

echo "== the device NAME must not survive a wipe, and must roam with the profile =="
settings put --user 0 secure bluetooth_name "departing-user-phone" >/dev/null 2>&1
settings put --user 0 global device_name    "departing-user-phone" >/dev/null 2>&1
P2=/data/local/tmp/bt-amnesia-prof2; rm -rf "$P2"; mkdir -p "$P2/com.nowhere.chooser/files"
bt_seal_capture "$P2" >/dev/null
chk "name captured" "departing-user-phone" "$(cat "$P2/com.nowhere.chooser/files/bt-name-secure-bluetooth_name" 2>/dev/null)"
bt_reset "" >/dev/null
# NWP-20260902-06: the wipe now SETS the model default rather than deleting. These two lines previously
# asserted `null`, which encoded the defect: a null tier-1 device name sends the common three-tier lookup
# into Settings.Secure.bluetooth_name, which THROWS for any app targeting SDK > 31, so the app's own
# Build.MODEL fallback is never reached and the exception escapes Application.onCreate. Amex 7.32.2 died at
# launch on exactly that stack. What amnesia requires is that the DEPARTING USER'S name does not survive --
# not that the field is empty -- so the assertion is now "it is the generic model default", which is both
# amnesia-correct and the value the apps themselves fall back to.
_DEF=$(getprop ro.product.model 2>/dev/null); [ -n "$_DEF" ] || _DEF="Android"
chk "bluetooth_name reset to the model default" "$_DEF" "$(settings get --user 0 secure bluetooth_name)"
chk "device_name reset to the model default"    "$_DEF" "$(settings get --user 0 global device_name)"
chk "departing name is GONE (the property that matters)" 0     "$(settings get --user 0 global device_name | grep -c 'departing-user-phone')"
bt_reset "$P2" >/dev/null
chk "name restored with the profile" "departing-user-phone" "$(settings get --user 0 secure bluetooth_name)"
settings delete --user 0 secure bluetooth_name >/dev/null 2>&1
settings delete --user 0 global device_name    >/dev/null 2>&1
rm -rf "$P2"

echo "== FAIL CLOSED: an unreadable bluedroid must not report a clean device =="
R="$BT_DIR"; BT_DIR=/data/misc/bluedroid-absent
bt_reset "";             chk "wipe rc is failure"    1 $?
bt_seal_capture "$PROF"; chk "capture rc is failure" 1 $?
chk "artifact PRESERVED (not read as 'user unpaired everything')" 1 \
    "$([ -e "$PROF/com.nowhere.chooser/files/bt-bond-bt_config" ] && echo 1 || echo 0)"
BT_DIR="$R"

echo "== FAIL CLOSED: an unreadable adapter state must abort before touching the config =="
printf 'KEEPME\n' > "$BT_DIR/bt_config.conf"
bt_state() { echo ""; }
bt_reset ""; chk "reset rc is failure" 1 $?
chk "config untouched" 1 "$(grep KEEPME "$BT_DIR/bt_config.conf" 2>/dev/null | wc -l | tr -d ' ')"

rm -rf "$PROF" "$STATE"; find "$BT_DIR" -mindepth 1 -exec rm -rf {} + 2>/dev/null
echo; echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" = 0 ]
HARNESS

$ADB push "$LOCAL" "$REMOTE" >/dev/null || { echo "push failed"; rm -f "$TMP"; exit 1; }
L=$(md5sum "$TMP" | cut -d' ' -f1)
R=$($ADB shell md5sum "$REMOTE" | tr -d '\r' | cut -d' ' -f1)
[ "$L" = "$R" ] || { echo "PUSHED FILE DIFFERS ($L vs $R) -- see the adb-push trap in AGENTS.md"; rm -f "$TMP"; exit 1; }
rm -f "$TMP"

$ADB shell sh "$REMOTE"; rc=$?
$ADB shell "rm -f $REMOTE /data/local/tmp/bt-amnesia.log" >/dev/null 2>&1
exit $rc
