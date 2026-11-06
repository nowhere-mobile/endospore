#!/usr/bin/env bash
# test-dataroaming.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's SESSION-SCOPED DATA ROAMING (NWP-20261028-07), run for
# real against a stubbed `am` (the gate's DataRoamingReceiver) under every shell the runner has, rather than grepped.
#
# WHY THIS IS COMMITTED. Data roaming is a per-subscription DEVICE setting. The Mobile data switch covers it (decided
# 2026-10-19): the profile's choice is applied while its session is in front and the GATE'S OWN value goes back whenever
# it is not. The gate's value is known only to the phone, so it is kept in a one-line record outside the tmpfs, and every
# way this goes wrong is silent: a claim that recaptures the record stores a PROFILE's value as the gate's; a release that
# restores the default data SIM instead of the recorded one leaves the recorded SIM's roaming switched on; a write that
# reads as applied when siminfo does not show it lies to the chooser; a reply change could break the mobile-data parsers.
# What this pins:
#   - the CHOICE (dataroaming=, md_choice's rules) and the CLAIM (op mdapply): the reply gains ` data_roaming=<0|1|?>`
#     after the mobile-data verdict, which stays byte for byte what md_claim set; the value is the receiver's read-back;
#   - the BASELINE RECORD `<sub>:<v>`: written before the phone is changed, only when none exists, never rewritten, kept
#     when the write is refused, dropped when a release or boot finds that sub already at it;
#   - the RELEASE (op mdrelease, which keeps md's reply byte for byte, and cleanstorage's reap) and the BOOT SWEEP (fix 14):
#     restore the RECORDED sub, keep for another live owner, nothing to do without a record, one space-free token;
#   - NO `settings` call anywhere: the data_roaming key is inert, the write goes through the receiver.
# `am` is an executable stub on PATH (dr_call runs it under `timeout`, which execs a binary, so a function would be bypassed).
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and its device roots are substituted (each
# substitution is checked); if an anchor moves, extraction fails loudly (exit 2) rather than a stale copy passing.
#
#   bash test-dataroaming.sh            # the behaviour cases, under bash, sh, dash and mksh where present
#   bash test-dataroaming.sh --mutate   # ... plus broken copies that must each be CONVICTED, under each shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

SHELLS=(); LABELS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p"); LABELS+=("$s")
done

BEGIN_HDR='# ---- NWP-20261028-07: SESSION-SCOPED DATA ROAMING (begin) ------------------------------------------------------------'
END_HDR='# ---- NWP-20261028-07: SESSION-SCOPED DATA ROAMING (end) --------------------------------------------------------------'
MD_BEGIN_HDR='# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (begin) ------------------------------------------------------------'
HS_BEGIN_HDR='# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (begin) ----------------------------------------------------------------'
HS_END_HDR='# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (end) ------------------------------------------------------------------'
LBEGIN_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------'
LEND_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------'
OP_HDR='if [ "$op" = "mdapply" ] || [ "$op" = "mdrelease" ]; then'
BOOT_HDR='  # --- fix 14: dataroaming (NWP-20261028-07) ---'
BOOT_END='  _swept="$_swept dataroaming=$DR_BOOT"'
FIX13_END='  _swept="$_swept devtoggles=$DT_BOOT"'
DT_REAP='  dt_release "$uid" reap   # NWP-20261027-05: the reap'"'"'s backstop for the device toggles; another owner is left alone'
DR_REAP='  dr_release "$uid" reap   # NWP-20261028-07: the reap'"'"'s backstop for data roaming; another owner is left alone'
APK_PFX='LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk '
ROOT_PFX='LOC_USER_ROOT=/data/user '
BASE_PFX='DR_BASE=/data/nowhere/dataroaming.base '

# prep <roamd.sh>: extract and substitute the pieces into a fresh dir ($R). 0, or 2 (the harness cannot run).
prep() {
  local f="$1" blk lblk boot oparm
  R=$(mktemp -d -p "$W") || return 2
  [ "$(grep -cxF "$BEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$END_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the data roaming block's begin/end anchors in $f" >&2; return 2; }
  [ "$(grep -cxF "$LBEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$LEND_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the location block's begin/end anchors in $f" >&2; return 2; }
  blk=$(awk -v b="$BEGIN_HDR" -v e="$END_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$blk" in *'dr_claim()'*'dr_release()'*'dr_boot()'*) ;;
    *) echo "EXTRACTION FAILED: the functions in the data roaming block" >&2; return 2 ;; esac
  lblk=$(awk -v b="$LBEGIN_HDR" -v e="$LEND_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$lblk" in *'loc_gone()'*'loc_why()'*) ;; *) echo "EXTRACTION FAILED: loc_gone/loc_why" >&2; return 2 ;; esac
  oparm=$(awk -v h="$OP_HDR" '$0 == h {on = 1} on {print} on && $0 == "fi" {exit}' "$f")
  case "$oparm" in *'md_claim '*'md_release '*'exit 0'*) ;; *) echo "EXTRACTION FAILED: the op arm" >&2; return 2 ;; esac
  boot=$(awk -v h="$BOOT_HDR" -v e="$BOOT_END" '$0 == h {on = 1} on {print} on && $0 == e {exit}' "$f")
  case "$boot" in *dr_boot*'dataroaming=$DR_BOOT'*) ;; *) echo "EXTRACTION FAILED: the bootsweep category" >&2; return 2 ;; esac
  [ "$(grep -c "^$APK_PFX" <<< "$lblk")" = 1 ] && [ "$(grep -c "^$ROOT_PFX" <<< "$lblk")" = 1 ] \
    && [ "$(grep -c "^$BASE_PFX" <<< "$blk")" = 1 ] \
    || { echo "EXTRACTION FAILED: a device-root line to substitute" >&2; return 2; }
  lblk=$(sed -e 's@^LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk @LOC_PROVIDER_APK="$T/none.apk" @' \
             -e 's@^LOC_USER_ROOT=/data/user @LOC_USER_ROOT="$T/user" @' <<< "$lblk")
  blk=$(sed -e 's@^DR_BASE=/data/nowhere/dataroaming.base @DR_BASE="$T/nowhere/dataroaming.base" @' <<< "$blk")
  [ "$(grep -c '^LOC_USER_ROOT="\$T/user" ' <<< "$lblk")" = 1 ] && [ "$(grep -c '^LOC_PROVIDER_APK="\$T/none.apk" ' <<< "$lblk")" = 1 ] \
    && [ "$(grep -c '^DR_BASE="\$T/nowhere/dataroaming.base" ' <<< "$blk")" = 1 ] \
    || { echo "EXTRACTION FAILED: a substitution did not apply exactly once" >&2; return 2; }
  if grep -v '^[[:space:]]*#' <<< "$lblk"$'\n'"$blk"$'\n'"$boot" | grep -qE '/system/|/data/'; then
    echo "EXTRACTION FAILED: a device path is left in the live code after substitution" >&2; return 2
  fi
  printf '%s\n' "$lblk" > "$R/loc.sh"; printf '%s\n' "$blk" > "$R/dr.sh"; printf '%s\n' "$boot" > "$R/boot.sh"
  printf '%s\n' "$oparm" > "$R/oparm.sh"; printf '%s\n' "$DR_REAP" > "$R/reap.sh"
  bash -n "$R/loc.sh" && bash -n "$R/dr.sh" && bash -n "$R/boot.sh" && bash -n "$R/oparm.sh" \
    || { echo "EXTRACTION FAILED: an extracted piece does not parse" >&2; return 2; }
  mkdir "$R/bin" || return 2
  # The gate's receiver, as a device: $T/roam.<sub> is each subscription's data roaming, $T/defsub the default data sub,
  # $T/mode one of honours (default) | denies | ignores | silent | late
  # (a well-formed reply, then exit 124 as timeout(1) does when it kills a slow am). One line per call in $T/calls.
  cat > "$R/bin/am" <<'EOF'
#!/bin/sh
op=""; val=""; sub=""
while [ $# -gt 0 ]; do
  case "$1" in
    --es) [ "$2" = op ] && op="$3"; shift 3 ;;
    --ei) case "$2" in value) val="$3" ;; sub) sub="$3" ;; esac; shift 3 ;;
    *) shift ;;
  esac
done
echo "NOISE-AM" >&2
echo "$op value=${val:--} sub=${sub:--}" >> "$T/calls"
mode=honours; [ -f "$T/mode" ] && mode=$(cat "$T/mode")
[ "$mode" = silent ] && exit 0
echo 'Broadcasting: Intent { act=com.nowhere.chooser.action.DATA_ROAMING }'
reply() { printf 'Broadcast completed: result=-1, data="%s"\r\n' "$1"; [ "$mode" = late ] && exit 124; exit 0; }
case "${sub:-0}" in 0) [ -f "$T/defsub" ] && sub=$(cat "$T/defsub") ;; esac
[ -n "$sub" ] || reply "ERR-DR nosub"
[ -f "$T/roam.$sub" ] || reply "ERR-DR unreadable"
if [ "$op" = set ]; then
  [ "$mode" = denies ] && reply "ERR-DR denied"
  [ "$mode" = ignores ] || printf '%s' "$val" > "$T/roam.$sub"
fi
reply "OK sub=$sub data_roaming=$(cat "$T/roam.$sub")"
EOF
  # `settings` must never be called: any call is recorded and fails.
  cat > "$R/bin/settings" <<'EOF'
#!/bin/sh
echo "settings $*" >> "$T/settings-calls"
exit 1
EOF
  chmod +x "$R/bin/am" "$R/bin/settings"
  return 0
}

DRIVER='
STATE="$T/state"; LOG="$T/log"; RES="$T/res"
md_claim() { MD_VERDICT=$(cat "$T/md-verdict" 2>/dev/null || echo "OK APPLIED mobile_data=1"); }
md_release() { MD_VERDICT="OK BASELINE mobile_data=0"; }
hs_release() { HS_VERDICT="OK RELEASED"; }   # NWP-20261028-10: the hotspot is test-hotspot-release.sh, not this suite
userdir_recheck() { :; }; userdir_pending_add() { :; }   # NWP-20261104-14: the users/<n> re-check is test-userdir-orphan.sh, not this suite
case "$MODE" in
  op) op="$OPV"; uid="$UIDV"; name="$NAMEV"; . "$R/loc.sh"; . "$R/dr.sh"; . "$R/oparm.sh"
      echo "the op arm fell through" >> "$T/unexpected" ;;
  boot) op=bootsweep; uid=""; name=""; _swept=""; . "$R/loc.sh"; . "$R/dr.sh"; . "$R/boot.sh"
        printf "%s" "$_swept" > "$T/swept" ;;
  reap) op=cleanstorage; uid="$UIDV"; name=x; . "$R/loc.sh"; . "$R/dr.sh"; . "$R/reap.sh" ;;
esac'

# suite <roamd.sh> <shell path> <label> [quiet]: 0 all ok, 1 an assertion failed (the only verdict that convicts a
# mutant), 2 the harness could not run. prep must have run ($R).
suite() {
  local f="$1" SH="$2" LB="$3" quiet="${4:-}" PASS=0 FAIL=0 T out at v x
  ok() { PASS=$((PASS+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$LB" "$1"; }
  no() { FAIL=$((FAIL+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$LB" "$1"; }

  # A device: sub 3 is the default data sub and reads 0; $T/nowhere/dataroaming.base is the record, $T/state/.dataroaming
  # the owner, $T/user/<n> user <n>'s CE directory (12 and 13 exist).
  mkdev() {
    T=$(mktemp -d -p "$W"); mkdir -p "$T/state" "$T/nowhere" "$T/user/12/com.nowhere.chooser/files" "$T/user/13/com.nowhere.chooser/files"
    : > "$T/calls"; printf 3 > "$T/defsub"; printf 0 > "$T/roam.3"
  }
  prefs() { printf '%b' "$2" > "$T/user/$1/com.nowhere.chooser/files/nowhere-prefs"; }
  setroam() { printf '%s' "$2" > "$T/roam.$1"; }
  roam() { if [ -f "$T/roam.$1" ]; then cat "$T/roam.$1"; else echo unset; fi; }
  base() { if [ -f "$T/nowhere/dataroaming.base" ]; then cat "$T/nowhere/dataroaming.base"; else echo none; fi; }
  owner() { if [ -f "$T/state/.dataroaming" ]; then tr -d '\n' < "$T/state/.dataroaming"; else echo none; fi; }
  setbase() { printf '%s' "$1" > "$T/nowhere/dataroaming.base"; }
  setowner() { echo "$1" > "$T/state/.dataroaming"; }
  nset() { grep -c '^set ' "$T/calls" 2>/dev/null || true; }
  ncalls() { grep -c . "$T/calls" 2>/dev/null || true; }
  drive() {  # drive <mode> <op> <uid> <name>
    env LC_ALL=C PATH="$R/bin:$PATH" T="$T" R="$R" MODE="$1" OPV="${2:-}" UIDV="${3:-}" NAMEV="${4:-}" "$SH" -c "$DRIVER" >/dev/null 2>>"$T/stderr"
  }
  op() { drive op "$1" "$2" "$3"; cat "$T/res" 2>/dev/null; rm -f "$T/res"; }
  boot() { drive boot; cat "$T/swept" 2>/dev/null; }
  reap() { drive reap "" "$1"; }
  clean() {  # no harness error may hide behind a passing case; R11: `settings` was never called
    if [ -s "$T/stderr" ] && grep -qE 'not found|unbound|[Ss]yntax error|bad substitution|parameter not set' "$T/stderr"; then
      no "$1: the harness reported $(head -n 1 "$T/stderr")"
    fi
    if [ -s "$T/stderr" ] && grep -q 'NOISE-' "$T/stderr"; then no "$1: am output reached stderr"; fi
    if [ -f "$T/log" ] && grep -q 'NOISE-' "$T/log"; then no "$1: am output reached the log"; fi
    if [ -s "$T/settings-calls" ]; then no "$1: settings was called: $(tr '\n' ';' < "$T/settings-calls")"; fi
    if [ -s "$T/unexpected" ]; then no "$1: unexpected: $(tr '\n' ';' < "$T/unexpected")"; fi
    rm -rf "$T"
  }

  # --- the CLAIM ----------------------------------------------------------------------------------------------
  mkdev; prefs 12 'tz=\ndataroaming=1\n'
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=1" ] && ok "R1 choice 1 at gate 0 -> the reply ends  data_roaming=1" || no "R1 reply '$out'"
  [ "$(base)" = "3:0" ] && ok "R1 the gate's 0 is recorded with its sub: 3:0" || no "R1 base '$(base)'"
  [ "$(roam 3)" = 1 ] && [ "$(owner)" = 12 ] && [ "$(nset)" = 1 ] && ok "R1 phone 1, owner 12, one set call" \
    || no "R1 roam $(roam 3), owner $(owner), $(nset) set call(s)"
  grep -q '^\[roamd\] dataroaming user 12 (signin): sub=3 data_roaming=1 APPLIED (reads 1) ' "$T/log" \
    && ok "R1 the log names the uid, the sub and values" || no "R1 log: $(cat "$T/log" 2>/dev/null)"
  clean R1

  for v in 0 1; do
    mkdev; prefs 12 'tz=\nlocale=en-US\n'; setroam 3 "$v"
    out=$(op mdapply 12 signin)
    [ "$out" = "OK APPLIED mobile_data=1 data_roaming=$v" ] && [ "$(nset)" = 0 ] && [ "$(base)" = none ] && [ "$(roam 3)" = "$v" ] \
      && ok "R2 no choice and no record at $v: no set call, no record, the reply ends the value a get read" \
      || no "R2 ($v) reply '$out', $(nset) set(s), base $(base)"
    [ "$(owner)" = 12 ] && ok "R2 ($v) the owner is recorded" || no "R2 ($v) owner '$(owner)'"
    clean "R2 $v"
  done

  mkdev; prefs 12 'dataroaming= 1 \r\n'
  out=$(op mdapply 12 live)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=1" ] && [ "$(roam 3)" = 1 ] && ok "R3 ' 1 \\r' is On" || no "R3 blanks/CR: '$out'"
  clean R3a
  mkdev; prefs 12 'dataroaming=0\ndataroaming=1\n'; setroam 3 1
  out=$(op mdapply 12 live)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=0" ] && [ "$(base)" = "3:1" ] && ok "R3 the first line wins" || no "R3 first-line: '$out', base $(base)"
  clean R3b
  for v in 'dataroamingx=1' 'DATAROAMING=1' 'dataroaming=2' 'dataroaming=true' 'dataroaming=' 'xdataroaming=1' 'mobiledata=1'; do
    mkdev; prefs 12 "$v\n"
    out=$(op mdapply 12 live)
    [ "$out" = "OK APPLIED mobile_data=1 data_roaming=0" ] && [ "$(nset)" = 0 ] && [ "$(base)" = none ] \
      && ok "R3 '$v' is no choice" || no "R3 '$v' -> '$out', $(nset) set(s), base $(base)"
    clean "R3 $v"
  done

  # the recapture trap
  mkdev; prefs 12 'dataroaming=1\n'; prefs 13 'tz=\n'
  op mdapply 12 signin >/dev/null
  out=$(op mdapply 13 signin)
  [ "$(base)" = "3:0" ] && [ "$(roam 3)" = 0 ] && [ "$(owner)" = 13 ] && [ "$out" = "OK APPLIED mobile_data=1 data_roaming=0" ] \
    && ok "R4 the recapture trap: 13's no-choice claim keeps 3:0 and puts the phone back to 0" \
    || no "R4a reply '$out', base $(base), roam $(roam 3), owner $(owner)"
  clean R4a
  mkdev; prefs 12 'dataroaming=1\n'; prefs 13 'dataroaming=1\n'
  op mdapply 12 signin >/dev/null
  out=$(op mdapply 13 signin)
  [ "$(base)" = "3:0" ] && [ "$(roam 3)" = 1 ] && ok "R4 ...and 13's On claim does not recapture it either" || no "R4b reply '$out', base $(base)"
  clean R4b

  # a refused, an ignored and a silent write are never applied
  mkdev; prefs 12 'dataroaming=1\n'; echo denies > "$T/mode"
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && ok "R5 a denied set -> the token is data_roaming=?, md's part byte for byte" || no "R5 reply '$out'"
  [ "$(base)" = "3:0" ] && [ "$(roam 3)" = 0 ] && ok "R5 the record is KEPT, the phone unchanged" || no "R5 base '$(base)', roam $(roam 3)"
  grep -q 'NOT APPLIED (reads ?)' "$T/log" && ok "R5 the log says NOT APPLIED" || no "R5 log: $(cat "$T/log" 2>/dev/null)"
  clean R5a
  mkdev; prefs 12 'dataroaming=1\n'; echo denies > "$T/mode"; echo "ERR-MD mobile_data=0" > "$T/md-verdict"
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=0 data_roaming=?" ] && ok "R5 an md error stays md's, roaming's outcome only appended" || no "R5b reply '$out'"
  clean R5b
  mkdev; prefs 12 'dataroaming=1\n'; echo ignores > "$T/mode"
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=0" ] && [ "$(roam 3)" = 0 ] && ok "R5 an ignored set shows the old value, not applied" || no "R5c reply '$out'"
  grep -q 'NOT APPLIED (reads 0)' "$T/log" && ok "R5 ...and the log says NOT APPLIED" || no "R5c log: $(cat "$T/log" 2>/dev/null)"
  clean R5c

  mkdev; prefs 12 'dataroaming=1\n'; echo silent > "$T/mode"
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && [ "$(base)" = none ] && [ "$(nset)" = 0 ] \
    && ok "R10 am printing nothing -> ?, no record written, nothing set" || no "R10 reply '$out', base $(base), $(nset) set(s)"
  clean R10a
  mkdev; prefs 12 'dataroaming=1\n'; setbase 3:0; setowner 12; setroam 3 1; echo silent > "$T/mode"
  out=$(op mdrelease 12 signout)
  [ "$out" = "OK BASELINE mobile_data=0" ] && [ "$(base)" = "3:0" ] && [ "$(owner)" = 12 ] \
    && ok "R10 a silent receiver on release: both records kept, never applied" || no "R10 reply '$out', base $(base), owner $(owner)"
  clean R10b
  mkdev; prefs 12 'dataroaming=1\n'; setbase 3:0; setowner 12; setroam 3 1; echo ignores > "$T/mode"
  op mdrelease 12 signout >/dev/null
  [ "$(base)" = "3:0" ] && [ "$(owner)" = 12 ] && ok "R10 an ignored restore keeps both records" || no "R10 ignores: base $(base), owner $(owner)"
  clean R10c
  mkdev; prefs 12 'dataroaming=1\n'; echo late > "$T/mode"
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && [ "$(base)" = none ] \
    && ok "R10 a well-formed reply from a call that exited 124 -> ?, never applied" || no "R10 late: reply '$out', base $(base)"
  clean R10d
  mkdev; prefs 12 'dataroaming=1\n'; setbase 3:0; setowner 12; setroam 3 1; echo late > "$T/mode"
  out=$(op mdrelease 12 signout)
  [ "$(base)" = "3:0" ] && [ "$(owner)" = 12 ] && ok "R10 a restore whose call exited 124 keeps both records" || no "R10 late release: base $(base), owner $(owner)"
  clean R10e

  # --- the RELEASE ----------------------------------------------------------------------------------------------
  mkdev; setbase 3:0; setowner 12; setroam 3 1; setroam 4 1; printf 4 > "$T/defsub"
  out=$(op mdrelease 12 signout)
  [ "$(roam 3)" = 0 ] && [ "$(roam 4)" = 1 ] && ok "R6 the RECORDED sub is restored, the new default sub left alone" || no "R6 roam3 $(roam 3), roam4 $(roam 4)"
  grep -q '^set value=0 sub=3$' "$T/calls" && [ "$(nset)" = 1 ] && ok "R6 the set call carries sub=3" || no "R6 calls: $(tr '\n' ';' < "$T/calls")"
  [ "$(base)" = none ] && [ "$(owner)" = none ] && ok "R6 record and owner gone" || no "R6 base $(base), owner $(owner)"
  [ "$out" = "OK BASELINE mobile_data=0" ] && ok "R12 the mdrelease RES is md's byte for byte" || no "R12 reply '$out'"
  clean R6

  mkdev; setbase 3:0; setowner 12; setroam 3 1; setowner 13
  out=$(op mdrelease 12 reap)
  [ "$(ncalls)" = 0 ] && [ "$(roam 3)" = 1 ] && [ "$(base)" = "3:0" ] && [ "$(owner)" = 13 ] \
    && ok "R7 another live owner: KEPT, no call, nothing changed" || no "R7 $(ncalls) call(s), roam $(roam 3), base $(base), owner $(owner)"
  [ "$out" = "OK BASELINE mobile_data=0" ] && ok "R12 ...and the RES is still md's" || no "R12 reply '$out'"
  clean R7a
  mkdev; setbase 3:0; setroam 3 1; setowner 14
  op mdrelease 12 reap >/dev/null
  [ "$(roam 3)" = 0 ] && ok "R7 an owner whose user is gone is no owner: restored" || no "R7b roam $(roam 3)"
  clean R7b

  mkdev; setbase 3:0; setowner 12
  op mdrelease 12 signout >/dev/null
  [ "$(nset)" = 0 ] && [ "$(base)" = none ] && [ "$(owner)" = none ] && ok "R8 the phone already at the baseline: zero set calls, record dropped" \
    || no "R8 $(nset) set(s), base $(base), owner $(owner)"
  clean R8
  mkdev; setroam 3 1; setowner 12
  op mdrelease 12 signout >/dev/null
  [ "$(ncalls)" = 0 ] && [ "$(owner)" = none ] && [ "$(roam 3)" = 1 ] && ok "R8 no record: no call, the owner forgotten" || no "R8 none: $(ncalls) call(s), owner $(owner)"
  clean R8b

  # a claim whose default data sub is not the recorded one writes nothing
  mkdev; prefs 12 'dataroaming=0\n'; setbase 3:0; setroam 4 1; printf 4 > "$T/defsub"
  out=$(op mdapply 12 signin)
  [ "$(nset)" = 0 ] && [ "$(base)" = "3:0" ] && [ "$out" = "OK APPLIED mobile_data=1 data_roaming=1" ] && [ "$(roam 4)" = 1 ] \
    && ok "R13 the record is for sub 3 and the data sub is 4: nothing written, record kept" || no "R13 $(nset) set(s), base $(base), reply '$out'"
  clean R13

  # --- the REAP -------------------------------------------------------------------------------------------------
  at=$(awk -v d="$DT_REAP" -v r="$DR_REAP" '/^if \[ "\$op" = "cleanstorage" \]; then$/ {op = NR} $0 == d {dl = NR} $0 == r {rl = NR}
    op && !mm && /^  stop_mediad / {mm = NR} END {print op " " dl " " rl " " mm}' "$f")
  set -- $at
  if [ "$#" = 4 ] && [ "$1" -lt "$2" ] && [ "$3" = $(( $2 + 1 )) ] && [ "$3" -lt "$4" ] && [ "$(grep -cxF "$DR_REAP" "$f")" = 1 ]; then
    ok "P1 cleanstorage releases data roaming, once, right after the device toggles' release and before stop_mediad"
  else no "P1 the reap's dr release line is missing, duplicated or misplaced (op/dt/dr/stop_mediad: $at)"; fi
  mkdev; setroam 3 1; setbase 3:0; setowner 12
  reap 12
  [ "$(roam 3)" = 0 ] && [ "$(base)" = none ] && [ "$(owner)" = none ] \
    && ok "R14 the reap of the owner restores the gate's value" || no "R14 roam $(roam 3), base $(base), owner $(owner)"
  clean R14

  # --- the BOOT SWEEP -------------------------------------------------------------------------------------------
  at=$(awk -v h="$BOOT_HDR" -v f13="$FIX13_END" '/^if \[ "\$op" = "bootsweep" \]; then$/ {op = NR} $0 == f13 {p = NR} $0 == h {blk = NR}
    /echo "\[roamd\] bootsweep result:\$_swept/ {res = NR} END {print (op && p > op && blk > p && res > blk) ? "in" : "out"}' "$f")
  [ "$at" = in ] && [ "$(grep -cxF "$BOOT_HDR" "$f")" = 1 ] \
    && ok "P2 the category sits inside the bootsweep op, once, after fix 13 and before the result line" || no "P2 the category is misplaced"
  at=$(awk -v e="$END_HDR" -v m="$MD_BEGIN_HDR" -v hb="$HS_BEGIN_HDR" -v he="$HS_END_HDR" '$0 == e {el = NR} $0 == m {ml = NR} $0 == hb {hl = NR} $0 == he {hel = NR}
    END {print (el && (ml == el + 1 || (hl == el + 1 && hel > hl && ml == hel + 1))) ? "ok" : "no"}' "$f")
  [ "$at" = ok ] && ok "P3 the data roaming block ends directly before the mobile data block (only the hotspot release block may sit between)" || no "P3 the block is misplaced"
  x=$(grep -v '^[[:space:]]*#' "$R/dr.sh" | grep -E '(^|[^A-Za-z_./-])settings([^A-Za-z_]|$)' || true)
  [ -z "$x" ] && ok "R11 the block has no settings command" || no "R11 settings in live code: $x"

  mkdev; setroam 3 1; setbase 3:0
  out=$(boot)
  [ "$out" = " dataroaming=baseline" ] && [ "$(roam 3)" = 0 ] && [ "$(base)" = none ] \
    && ok "R9 a record and no owner: restored -> dataroaming=baseline" || no "R9a _swept '$out', roam $(roam 3), base $(base)"
  clean R9a
  mkdev; setroam 3 1; setbase 3:0; setowner 12
  out=$(boot)
  [ "$out" = " dataroaming=KEPT:user12" ] && [ "$(ncalls)" = 0 ] && [ "$(roam 3)" = 1 ] && [ "$(base)" = "3:0" ] \
    && ok "R9 a live owner -> dataroaming=KEPT:user12, nothing written" || no "R9b _swept '$out', $(ncalls) call(s)"
  clean R9b
  mkdev; setroam 3 1
  out=$(boot)
  [ "$out" = " dataroaming=none" ] && [ "$(ncalls)" = 0 ] && ok "R9 no record -> dataroaming=none, zero calls" || no "R9c _swept '$out', $(ncalls) call(s)"
  clean R9c
  mkdev; setroam 3 1; setbase 3:0; echo denies > "$T/mode"
  out=$(boot)
  case "$out" in
    " dataroaming=FAILED("*")") case "${out# }" in *' '*) no "R9 not one space-free token: '$out'" ;; *) ok "R9 a failed restore -> one token $out" ;; esac ;;
    *) no "R9d _swept '$out'" ;;
  esac
  [ "$(base)" = "3:0" ] && ok "R9 ...and the record is kept" || no "R9d base '$(base)'"
  clean R9d
  mkdev; setroam 3 1; setbase 3:0; echo ignores > "$T/mode"
  out=$(boot)
  [ "$out" = " dataroaming=FAILED(1)" ] && [ "$(base)" = "3:0" ] && ok "R9 an ignored restore -> FAILED(1), record kept" || no "R9e _swept '$out', base $(base)"
  clean R9e
  mkdev; setroam 3 0; setbase 3:0
  out=$(boot)
  [ "$out" = " dataroaming=baseline" ] && [ "$(nset)" = 0 ] && [ "$(base)" = none ] \
    && ok "R9 the phone already reads the record: baseline, dropped, zero set calls" || no "R9f _swept '$out', $(nset) set(s), base $(base)"
  clean R9f
  mkdev; setroam 3 1; setroam 4 0; setbase 3:0; printf 4 > "$T/defsub"
  out=$(boot)
  [ "$out" = " dataroaming=baseline" ] && [ "$(roam 3)" = 0 ] && ok "R9 the boot restores the recorded sub when the default changed" || no "R9g _swept '$out', roam3 $(roam 3)"
  clean R9g

  # --- the ops' arguments and the log ------------------------------------------------------------------------
  for x in mdapply mdrelease; do
    for v in abc 5 '' 9x; do
      mkdev; setroam 3 1; setbase 3:0
      out=$(op "$x" "$v" signin)
      [ "$out" = ERR-UID ] && [ "$(ncalls)" = 0 ] && [ "$(base)" = "3:0" ] && ok "E1 $x refuses uid '$v'" || no "E1 $x '$v' -> '$out', $(ncalls) call(s)"
      clean "E1 $x $v"
    done
  done
  mkdev; prefs 12 'dataroaming=1\n'
  op mdapply 12 'zq Alice Smith' >/dev/null
  if grep -q '(other)' "$T/log" && ! grep -qE 'zq|Alice|Smith' "$T/log"; then ok "E2 the reason slot cannot put a name into the log"
  else no "E2 log: $(cat "$T/log" 2>/dev/null)"; fi
  op mdrelease 12 'Bob' >/dev/null
  ! grep -q 'Bob' "$T/log" && ok "E2 ...nor can a release's" || no "E2 release log: $(cat "$T/log" 2>/dev/null)"
  clean E2

  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$LB" "$PASS" "$FAIL"
  [ "$FAIL" = 0 ] && return 0 || return 1
}

# runall <roamd.sh> [quiet] -> the worst verdict over the shells
runall() {
  local f="$1" q="${2:-}" i rc worst=0
  prep "$f" || return 2
  for i in "${!SHELLS[@]}"; do
    suite "$f" "${SHELLS[$i]}" "${LABELS[$i]}" "$q"; rc=$?
    [ "$rc" -gt "$worst" ] && worst=$rc
  done
  rm -rf "$R"
  return "$worst"
}

echo "== $SUT"
echo "shells: ${LABELS[*]}"
runall "$SUT"; rc=$?
if [ "$rc" != 0 ]; then echo "FAILED (rc=$rc)"; exit "$rc"; fi
[ "$MUTATE" = yes ] || exit 0

echo
echo "== mutations (each must be CONVICTED by an assertion under EACH shell; one that does not apply or breaks the harness is a failure)"
fails=0; nmut=0
mut() {  # mut <label> <perl -0pe program>
  local i rc m="$W/mutant.sh"
  nmut=$((nmut+1))
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  prep "$m" || { echo "  BROKEN    $1 -- the mutant could not be extracted"; fails=$((fails+1)); return; }
  for i in "${!SHELLS[@]}"; do
    suite "$m" "${SHELLS[$i]}" "${LABELS[$i]}" quiet >/dev/null 2>&1; rc=$?
    case "$rc" in
      1) echo "  convicted [${LABELS[$i]}] $1" ;;
      0) echo "  SURVIVED  [${LABELS[$i]}] $1"; fails=$((fails+1)) ;;
      *) echo "  BROKEN    [${LABELS[$i]}] $1 -- the harness could not run it (rc=$rc), which is not a conviction"; fails=$((fails+1)) ;;
    esac
  done
  rm -rf "$R"
}
mut "N1 a claim always recaptures the baseline"          's/if \[ -z "\$_rec" \]; then(\n    # No record)/if true; then$1/'
mut "N2 dr_release ignores another owner"                's/(dr_release\(\) \{.*?)if \[ -n "\$_o" \] && \[ "\$_o" != "\$_u" \]; then/$1if false; then/s'
mut "N3 the release restores the default sub, not the recorded one" 's/if dr_write "\$_bv" "\$_bs"; then(\n    rm -f "\$DR_BASE" "\$DR_OWNER")/if dr_write "\$_bv" ""; then$1/'
mut "N4 an OK reply whose data_roaming differs is written" 's/dr_call set "\$1" "\$2" && \[ "\$DR_SEEN" = "\$1" \]/dr_call set "\$1" "\$2"/'
mut "N5 the boot sweep ignores DR_BASE"                  's/(dr_boot\(\) \{.*?)_rec=\$\(dr_base\)/$1_rec=/s'
mut "N6 the op arm's dr_claim is removed"                's/^    dr_claim "\$uid"[^\n]*\n//m'
mut "N7 the reap line is removed"                        's/^  dr_release "\$uid" reap   # NWP-20261028-07[^\n]*\n//m'
mut "N8 the token is appended to the mdrelease RES too"  's/^    MD_VERDICT="\$MD_VERDICT data_roaming=[^\n]*\n//m; s/(  echo "\$MD_VERDICT" > "\$RES"; chmod 600 "\$RES"; exit 0\nfi\n# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA \(end\))/  MD_VERDICT="\$MD_VERDICT data_roaming=\$DR_SEEN"\n$1/'
mut "N9 dr_call accepts a reply after a failed (timed out) am" 's/\n  \[ "\$_rc" -eq 0 \] \|\| return 1//'
[ "$fails" = 0 ] && echo "== all $nmut mutations convicted (shells: ${LABELS[*]})" || { echo "== $fails mutation outcome(s) not convicted"; exit 1; }
