#!/usr/bin/env bash
# test-bt-capture.sh [<nowhere_roamd.sh>] [--mutate] -- bt_seal_capture's bond and name halves, on the host (NWP-20261111-18).
#
# WHY THIS IS COMMITTED. bt_seal_capture runs at the top of EVERY `out` (periodic, manual and logoff seals) and in
# btpark at a cold lock. Its name half read `settings get` with no bound and no exit status, and deleted the
# profile's saved device-name artifact on EMPTY output. Empty output is never a value (an unset key prints `null`):
# it is a call that failed, was killed, or met a settings provider not answering. So a profile that had named its
# phone lost the artifact at a sign-out whose read failed, the logoff seal sealed the CE without it, and every later
# sign-in on any phone restored the model default: the name was gone for good. A hung read also held the seal with
# no bound. Now a non-zero status or empty output KEEPS the artifact and logs the key (never the value), `null` or
# the model default removes it, anything else is written through a .tmp + mv, and the read runs under
# `timeout -k 2 10` like cutoff_keep's. No other suite executes bt_seal_capture: test-bt-reset.sh covers bt_reset,
# test-coldlock-drops-ks-creds.sh stubs it, and core/vendor-common/prebuilts/test-bt-amnesia.sh needs a device.
#
# BT_DIR=, BT_FILES=, BT_NAME_KEYS=, bt_default_name and bt_seal_capture are extracted from nowhere_roamd.sh BY NAME
# (exit 2, EXTRACTION FAILED, when one is absent or the block does not parse), never copied. BT_DIR is re-pointed at
# a fake bluedroid dir after the block. settings, timeout and getprop are stubbed; cp, mv, rm, ls, chmod and date are
# real. Every case runs under every shell the runner has (bash, sh, dash, mksh; BTCAP_SHELLS=<paths> restricts it).
#
# ⚠ NO `cmd | grep -q` ANYWHERE IN THIS FILE: under pipefail an early-exiting grep -q makes the writer die of SIGPIPE
# and the pipeline FAIL although grep matched. Count matches in a file instead.
#
#   bash test-bt-capture.sh               # the cases
#   bash test-bt-capture.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
if [ -n "${BTCAP_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$BTCAP_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r=$(readlink -f "$p")
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

# The model getprop answers with, and a profile's own name for its phone. Neither is a real person's.
MODEL='Test Model 9'
PNAME='Probe Handset'

BLOCK=$(sed -n '/^BT_DIR=/p; /^BT_FILES=/p; /^BT_NAME_KEYS=/p; /^bt_default_name() {$/,/^}$/p; /^bt_seal_capture() {$/,/^}$/p' "$SUT")
for n in 'BT_DIR=' 'BT_FILES=' 'BT_NAME_KEYS=' 'bt_default_name() {' 'bt_seal_capture() {'; do
  case "$BLOCK" in *"$n"*) ;; *) echo "EXTRACTION FAILED: '$n' is absent from $SUT" >&2; exit 2 ;; esac
done
printf '%s\n' "$BLOCK" > "$W/block.sh"
for sh in "${SHELLS[@]}"; do
  "$sh" -n "$W/block.sh" 2>"$W/parse.err" || { echo "EXTRACTION FAILED: the block does not parse under $sh: $(cat "$W/parse.err")" >&2; exit 2; }
done

# --- the stubs (POSIX; they run inside every shell) ---------------------------------------------------------------
# settings get: answers from $T/get.<ns>.<key>: `value:<text>` prints <text>, `null` prints null, `empty` prints
#               nothing (rc 0), `fail` prints null and returns 1, `failv:<text>` prints <text> and returns 1. A missing
#               spec prints null. It never returns 124 itself: only timeout does, so a read outside timeout is caught.
# timeout:      `timeout -k 2 10 <cmd...>`; when $T/hang.<key> exists (the key is the last argument) it returns 124
#               without running the command, else it runs it.
# getprop:      prints $T/model.
STUBS=$(cat <<'EOS'
settings(){
  local _ns _k _s
  [ "$1" = get ] || return 0
  shift; [ "$1" = --user ] && shift 2
  _ns=$1; _k=$2
  _s=$(cat "$T/get.$_ns.$_k" 2>/dev/null)
  case "$_s" in
    value:*) printf '%s\n' "${_s#value:}" ;;
    empty) ;;
    fail) echo null; return 1 ;;
    failv:*) printf '%s\n' "${_s#failv:}"; return 1 ;;
    *) echo null ;;
  esac
  return 0
}
timeout(){
  local _k
  shift 3
  for _k; do :; done
  [ -e "$T/hang.$_k" ] && return 124
  "$@"
}
getprop(){ cat "$T/model"; }
EOS
)

FILES=com.nowhere.chooser/files
NB=bt-name-secure-bluetooth_name
NG=bt-name-global-device_name

# fresh: a case dir with a populated fake bluedroid, the profile's artifact dir, the model, both names = PNAME.
fresh(){
  local c
  c=$(mktemp -d -p "$W") || return 1
  mkdir -p "$c/bluedroid" "$c/prof/$FILES"
  printf '[Adapter]\nAddress = 00:11:22:33:44:55\n[aa:bb:cc:dd:ee:ff]\nLinkKey = \001\377fresh\n' > "$c/bluedroid/bt_config.conf"
  printf '[aa:bb:cc:dd:ee:ff]\nName = fresh\n' > "$c/bluedroid/bt_remote_dev_info.conf"
  printf 'not in BT_FILES\n' > "$c/bluedroid/bt_unenumerated.bin"
  printf '%s' "$MODEL" > "$c/model"
  printf 'value:%s' "$PNAME" > "$c/get.secure.bluetooth_name"
  printf 'value:%s' "$PNAME" > "$c/get.global.device_name"
  printf '%s' "$c"
}
# plant <dir>: the profile's artifacts from an earlier seal (old bonds, the name it chose), and copies to cmp against.
plant(){
  local c="$1" a
  printf 'old config\n' > "$c/prof/$FILES/bt-bond-bt_config"
  printf 'old remote\n' > "$c/prof/$FILES/bt-bond-bt_remote_dev_info"
  printf '%s' "$PNAME" > "$c/prof/$FILES/$NB"
  printf '%s' "$PNAME" > "$c/prof/$FILES/$NG"
  for a in bt-bond-bt_config bt-bond-bt_remote_dev_info "$NB" "$NG"; do cp "$c/prof/$FILES/$a" "$c/before.$a"; done
}
# spec <dir> <spec>: both name keys answer <spec>.
spec(){ printf '%s' "$2" > "$1/get.secure.bluetooth_name"; printf '%s' "$2" > "$1/get.global.device_name"; }
# run <shell> <dir> [<bt-dir>] [<pre-hook>]: the block + stubs, as roamd runs it (no -u, no pipefail). The status lands
# in <dir>/rc, the caller's _v and _rc after the call in <dir>/v_after and <dir>/rc_after.
run(){
  local sh="$1" c="$2" bd="${3:-$2/bluedroid}" hook="${4:-}"
  {
    printf 'T=%s; LOG=%s/log\n' "'$c'" "'$c'"
    cat "$W/block.sh"
    printf 'BT_DIR=%s\n' "'$bd'"
    printf '%s\n' "$STUBS"
    printf '%s\n' "$hook"
    printf 'bt_seal_capture "$T/prof"; echo $? > "$T/rc"\n'
    printf 'printf %%s "$_v" > "$T/v_after"; printf %%s "$_rc" > "$T/rc_after"\n'
  } > "$c/run.sh"
  "$sh" "$c/run.sh" >"$c/stdout" 2>&1
}
same(){ cmp -s "$1/before.$2" "$1/prof/$FILES/$2"; }
lines(){ grep -c -F -- "$2" "$1/log" 2>/dev/null; }
logof(){ cat "$1/log" 2>/dev/null; }

printf '%s' "$PNAME" > "$W/pname"

for sh in "${SHELLS[@]}"; do
  tag="[${sh##*/}]"
  LOGS=""

  C=$(fresh); run "$sh" "$C"
  if [ "$(cat "$C/rc")" = 0 ] && cmp -s "$C/bluedroid/bt_config.conf" "$C/prof/$FILES/bt-bond-bt_config" \
     && cmp -s "$C/bluedroid/bt_remote_dev_info.conf" "$C/prof/$FILES/bt-bond-bt_remote_dev_info" \
     && [ ! -e "$C/prof/$FILES/bt-bond-bt_unenumerated.bin" ] && [ ! -e "$C/prof/$FILES/bt-bond-bt_config.tmp" ] \
     && [ ! -e "$C/prof/$FILES/bt-bond-bt_remote_dev_info.tmp" ]; then
    ok "$tag C1 both bonds captured byte for byte, rc 0, no .tmp left"
  else no "$tag C1 rc $(cat "$C/rc"), files: $(ls "$C/prof/$FILES")"; fi

  C=$(fresh); plant "$C"; run "$sh" "$C" "$C/absent"
  if [ "$(cat "$C/rc")" = 1 ] && same "$C" bt-bond-bt_config && same "$C" bt-bond-bt_remote_dev_info \
     && same "$C" "$NB" && same "$C" "$NG" && [ "$(lines "$C" "unreadable at capture -- keeping this profile's existing artifacts")" = 1 ]; then
    ok "$tag C2 BT_DIR unreadable -> rc 1, every old artifact kept"
  else no "$tag C2 rc $(cat "$C/rc"), log: $(logof "$C")"; fi

  C=$(fresh); plant "$C"; rm -f "$C/bluedroid/bt_remote_dev_info.conf"; run "$sh" "$C"
  if [ "$(cat "$C/rc")" = 0 ] && [ ! -e "$C/prof/$FILES/bt-bond-bt_remote_dev_info" ] \
     && cmp -s "$C/bluedroid/bt_config.conf" "$C/prof/$FILES/bt-bond-bt_config"; then
    ok "$tag C3 one bond file absent -> its artifact removed, the other captured"
  else no "$tag C3 rc $(cat "$C/rc"), files: $(ls "$C/prof/$FILES")"; fi

  C=$(fresh); run "$sh" "$C"; LOGS="$LOGS $C"
  m1=$(stat -c %a "$C/prof/$FILES/$NB" 2>/dev/null); m2=$(stat -c %a "$C/prof/$FILES/$NG" 2>/dev/null)
  if cmp -s "$W/pname" "$C/prof/$FILES/$NB" && cmp -s "$W/pname" "$C/prof/$FILES/$NG" && [ "$m1:$m2" = 600:600 ] \
     && [ ! -e "$C/prof/$FILES/$NB.tmp" ] && [ ! -e "$C/prof/$FILES/$NG.tmp" ]; then
    ok "$tag C4 a name value -> both artifacts hold it exactly (no newline), mode 600, no .tmp"
  else no "$tag C4 '$(cat "$C/prof/$FILES/$NB" 2>/dev/null)' modes $m1:$m2, files: $(ls "$C/prof/$FILES")"; fi

  C=$(fresh); plant "$C"; spec "$C" null; run "$sh" "$C"
  if [ "$(cat "$C/rc")" = 0 ] && [ ! -e "$C/prof/$FILES/$NB" ] && [ ! -e "$C/prof/$FILES/$NG" ]; then
    ok "$tag C5 null -> both name artifacts removed"
  else no "$tag C5 rc $(cat "$C/rc"), files: $(ls "$C/prof/$FILES")"; fi

  C=$(fresh); plant "$C"; spec "$C" "value:$MODEL"; run "$sh" "$C"
  if [ "$(cat "$C/rc")" = 0 ] && [ ! -e "$C/prof/$FILES/$NB" ] && [ ! -e "$C/prof/$FILES/$NG" ]; then
    ok "$tag C6 the model default -> both name artifacts removed"
  else no "$tag C6 rc $(cat "$C/rc"), files: $(ls "$C/prof/$FILES")"; fi

  # C7 C8 C9: a read that did not happen keeps the saved name and says so, naming the key.
  for k in 7:empty:0 8:fail:1 9:hang:124; do
    cs=${k%%:*}; sp=${k#*:}; sp=${sp%%:*}; want=${k##*:}
    C=$(fresh); plant "$C"
    if [ "$sp" = hang ]; then spec "$C" null; : > "$C/hang.bluetooth_name"; : > "$C/hang.device_name"; else spec "$C" "$sp"; fi
    run "$sh" "$C"; LOGS="$LOGS $C"
    if [ "$(cat "$C/rc")" = 0 ] && same "$C" "$NB" && same "$C" "$NG" \
       && [ "$(lines "$C" "[roamd] bt: device name bluetooth_name unreadable (rc=$want) -- this profile's saved name is kept")" = 1 ] \
       && [ "$(lines "$C" "[roamd] bt: device name device_name unreadable (rc=$want) -- this profile's saved name is kept")" = 1 ]; then
      ok "$tag C$cs $sp (rc $want) -> both saved names kept, one unreadable line per key"
    else no "$tag C$cs $sp: rc $(cat "$C/rc"), files: $(ls "$C/prof/$FILES"), log: $(logof "$C")"; fi
  done

  # C10: the log never holds the value -- over C4, C7-C9, and a failed read whose output IS the name.
  C=$(fresh); plant "$C"; spec "$C" "failv:$PNAME"; run "$sh" "$C"; LOGS="$LOGS $C"
  same "$C" "$NB" && same "$C" "$NG" || no "$tag C10 a failed read that printed the name did not keep the artifacts"
  leak=""
  for c in $LOGS; do [ "$(lines "$c" "$PNAME")" = 0 ] || leak="$leak $(logof "$c")"; done
  [ -z "$leak" ] && ok "$tag C10 no log holds the name value" || no "$tag C10 the name leaked:$leak"

  C=$(fresh); run "$sh" "$C" "" "_v='caller-sentinel'; _rc='caller-rc'"
  if [ "$(cat "$C/v_after")" = caller-sentinel ] && [ "$(cat "$C/rc_after")" = caller-rc ] && cmp -s "$W/pname" "$C/prof/$FILES/$NB"; then
    ok "$tag C11 the caller's _v and _rc are unchanged by the call"
  else no "$tag C11 _v '$(cat "$C/v_after")', _rc '$(cat "$C/rc_after")'"; fi
done

[ "$(grep -c -F 'bt_seal_capture "$USERDIR"' "$SUT")" = 1 ] && ok "the out arm's call site is there once" || no "the out arm's call site count is not 1"
[ "$(grep -c -F 'bt_seal_capture "/data/user/$uid" || _btrc=1' "$SUT")" = 1 ] && ok "btpark's call site is there once" || no "btpark's call site count is not 1"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  mutate(){ local lbl="$1" m s; shift; m=$(mktemp -d -p "$W")
    if ! "$@" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN: $lbl: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $lbl"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      BTCAP_SHELLS="$s" bash "$0" "$m/m" >/dev/null 2>&1
      if [ $? -eq 1 ]; then ok "convicted under ${s##*/}: $lbl"; else no "NOT CONVICTED under ${s##*/}: $lbl -- suite passes (or cannot run) on broken code"; fi
    done
    rm -rf "$m"
  }
  H='/^bt_seal_capture() {$/,/^}$/'
  mutate "M1: case (a) folded back into rm" sed "$H"' s/^      continue$/      rm -f "$_out"; continue/' "$SUT"
  mutate "M2: _rc ignored" sed "$H"' s/if \[ "\$_rc" != 0 \] || \[ -z "\$_v" \]; then/if [ -z "$_v" ]; then/' "$SUT"
  mutate "M3: the timeout dropped" sed "$H"' s/timeout -k 2 10 settings get --user 0/settings get --user 0/' "$SUT"
  mutate "M4: local of _v dropped" sed "$H"' s/; local _v;/;/' "$SUT"
  mutate "M5: the null arm writes instead of removing" sed "$H"' s/null|"\$(bt_default_name)") rm -f "\$_out" ;;/null|"$(bt_default_name)") printf "%s" "$_v" > "$_out" ;;/' "$SUT"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
