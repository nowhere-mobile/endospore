#!/usr/bin/env bash
# test-devtoggles.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's SESSION DEVICE TOGGLES (NWP-20261027-05), run for real
# against stubbed `settings`, `cmd`, `dumpsys` and `svc`, under every shell the runner has, rather than grepped.
#
# WHY THIS IS COMMITTED. Airplane mode, battery saver, Data Saver and NFC are DEVICE-WIDE, a session can flip them, and
# nothing used to put them back: airplane mode left on leaves the gate offline, so the next sign-in cannot reach the
# store. roamd now records the GATE's value of each when a session first comes to the front and restores it at every
# release path and at boot. Every way this goes wrong is silent: a claim that recaptures the record stores a SESSION's
# values as the gate's (every later sign-out leaves the phone at them); a claim that writes a setting changes the phone
# before anyone asked; a release that ignores the owner flips the toggles of the session now in front; a write that
# reads as restored when the OS refused it lies to the daemon; a record dropped on a partial failure never retries; a
# boot sweep that ignores the record leaves a power-loss session's values on for whoever signs in next. What this pins:
#   - the CLAIM (op dtclaim): the gate's readable values are recorded in a fixed order, a key that does not read is left
#     out, the record is never rewritten, and NOTHING is written to any setting;
#   - the RELEASE (op dtrelease, and cleanstorage's reap): only the keys the session changed are written back, each
#     write is read back, another live owner is left alone, a failure keeps the owner and shrinks the record to the
#     keys still not at baseline, and the retry restores them;
#   - the BOOT SWEEP (fix 13): restores, keeps for a live owner, nothing to do without a record, one space-free token;
#   - the ops' arguments, and that the LOG carries the uid, key names and digits only: never a name, never a command's
#     output.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and its device roots are substituted (each
# substitution is checked); if an anchor moves, extraction fails loudly (exit 2) rather than a stale copy passing.
#
#   bash test-devtoggles.sh            # the behaviour cases, under bash, sh, dash and mksh where present
#   bash test-devtoggles.sh --mutate  # ... plus broken copies that must each be CONVICTED, under each shell
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

BEGIN_HDR='# ---- NWP-20261027-05: SESSION DEVICE TOGGLES (begin) ----------------------------------------------------------------'
END_HDR='# ---- NWP-20261027-05: SESSION DEVICE TOGGLES (end) ------------------------------------------------------------------'
LBEGIN_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------'
LEND_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------'
BOOT_HDR='  # --- fix 13: devtoggles (NWP-20261027-05) ---'
BOOT_END='  _swept="$_swept devtoggles=$DT_BOOT"'
MD_REAP='  md_release "$uid" reap   # NWP-20261026-05: the reap'"'"'s backstop for mobile data; another owner is left alone'
DT_REAP='  dt_release "$uid" reap   # NWP-20261027-05: the reap'"'"'s backstop for the device toggles; another owner is left alone'
CS_HDR='if [ "$op" = "cleanstorage" ]; then'
BS_HDR='if [ "$op" = "bootsweep" ]; then'
RESULT_PFX='  echo "[roamd] bootsweep result:'
APK_PFX='LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk '
ROOT_PFX='LOC_USER_ROOT=/data/user '
BASE_PFX='DT_BASE=/data/nowhere/devtoggles.base '

# prep <roamd.sh>: extract and substitute the blocks into a fresh dir ($R). 0, or 2 (the harness cannot run).
prep() {
  local f="$1" blk lblk boot live
  R=$(mktemp -d -p "$W") || return 2
  [ "$(grep -cxF "$BEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$END_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the device toggles block's begin/end anchors in $f" >&2; return 2; }
  [ "$(grep -cxF "$LBEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$LEND_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the location block's begin/end anchors in $f" >&2; return 2; }
  blk=$(awk -v b="$BEGIN_HDR" -v e="$END_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$blk" in *'dt_claim()'*'dt_release()'*'dt_boot()'*'"$op" = "dtclaim"'*) ;;
    *) echo "EXTRACTION FAILED: the functions or the op in the device toggles block" >&2; return 2 ;; esac
  lblk=$(awk -v b="$LBEGIN_HDR" -v e="$LEND_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$lblk" in *'loc_gone()'*'loc_why()'*) ;; *) echo "EXTRACTION FAILED: loc_gone/loc_why" >&2; return 2 ;; esac
  boot=$(awk -v h="$BOOT_HDR" -v e="$BOOT_END" '$0 == h {on = 1} on {print} on && $0 == e {exit}' "$f")
  case "$boot" in *dt_boot*'devtoggles=$DT_BOOT'*) ;; *) echo "EXTRACTION FAILED: the bootsweep category" >&2; return 2 ;; esac
  [ "$(grep -c "^$APK_PFX" <<< "$lblk")" = 1 ] && [ "$(grep -c "^$ROOT_PFX" <<< "$lblk")" = 1 ] \
    && [ "$(grep -c "^$BASE_PFX" <<< "$blk")" = 1 ] \
    || { echo "EXTRACTION FAILED: a device-root line to substitute" >&2; return 2; }
  lblk=$(sed -e 's@^LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk @LOC_PROVIDER_APK="$T/none.apk" @' \
             -e 's@^LOC_USER_ROOT=/data/user @LOC_USER_ROOT="$T/user" @' <<< "$lblk")
  blk=$(sed -e 's@^DT_BASE=/data/nowhere/devtoggles.base @DT_BASE="$T/nowhere/devtoggles.base" @' <<< "$blk")
  [ "$(grep -c '^LOC_USER_ROOT="\$T/user" ' <<< "$lblk")" = 1 ] && [ "$(grep -c '^LOC_PROVIDER_APK="\$T/none.apk" ' <<< "$lblk")" = 1 ] \
    && [ "$(grep -c '^DT_BASE="\$T/nowhere/devtoggles.base" ' <<< "$blk")" = 1 ] \
    || { echo "EXTRACTION FAILED: a substitution did not apply exactly once" >&2; return 2; }
  live=$(grep -v '^[[:space:]]*#' <<< "$lblk"$'\n'"$blk"$'\n'"$boot")
  if grep -qE '/system/|/data/' <<< "$live"; then
    echo "EXTRACTION FAILED: a device path is left in the live code after substitution" >&2; return 2
  fi
  printf '%s\n' "$lblk" > "$R/loc.sh"; printf '%s\n' "$blk" > "$R/dt.sh"; printf '%s\n' "$boot" > "$R/boot.sh"
  printf '%s\n' "$DT_REAP" > "$R/reap.sh"
  bash -n "$R/loc.sh" && bash -n "$R/dt.sh" && bash -n "$R/boot.sh" \
    || { echo "EXTRACTION FAILED: an extracted block does not parse" >&2; return 2; }
  # One table, $T/g.<key> (0 or 1; absent or anything else reads as unreadable). Per key: $T/deny-<key> makes a write
  # exit 1 with no change, $T/stuck-<key> makes it exit 0 with no change, $T/blind-<key> makes the read unparsable.
  # Every call is counted; any other call is recorded as unexpected.
  cat > "$R/stubs.sh" <<'EOF'
_gv() { if [ -f "$T/g.$1" ]; then cat "$T/g.$1"; fi; }
_gread() {  # _gread <key>: the table value, 0 or 1, or nothing
  [ -f "$T/blind-$1" ] && return 0
  case "$(_gv "$1")" in 0) echo 0 ;; 1) echo 1 ;; esac
}
_gwrite() {  # _gwrite <key> <value>
  echo NOISE-WRITE; echo NOISE-WRITE >&2
  [ -f "$T/deny-$1" ] && return 1
  [ -f "$T/stuck-$1" ] && return 0
  printf '%s' "$2" > "$T/g.$1"
  return 0
}
settings() {
  echo "settings $*" >> "$T/calls"
  if [ "$1 $2" = "get global" ]; then
    echo NOISE-SETTINGS >&2
    case "$3" in
      airplane_mode_on) _k=airplane ;;
      low_power) _k=saver ;;
      *) echo "settings $*" >> "$T/unexpected"; return 1 ;;
    esac
    _v=$(_gread "$_k"); if [ -n "$_v" ]; then echo "$_v"; else echo null; fi
    return 0
  fi
  echo "settings $*" >> "$T/unexpected"; return 1
}
cmd() {
  echo "cmd $*" >> "$T/calls"
  case "$1 $2 $3" in
    "connectivity airplane-mode enable") _gwrite airplane 1; return $? ;;
    "connectivity airplane-mode disable") _gwrite airplane 0; return $? ;;
    "power set-mode 1") _gwrite saver 1; return $? ;;
    "power set-mode 0") _gwrite saver 0; return $? ;;
    "netpolicy set restrict-background")
      case "$4" in true) _gwrite datasaver 1; return $? ;; false) _gwrite datasaver 0; return $? ;; esac ;;
    "netpolicy get restrict-background")
      echo NOISE-CMD >&2
      case "$(_gread datasaver)" in 1) echo "Restrict background status: enabled" ;; 0) echo "Restrict background status: disabled" ;; *) echo "garbage" ;; esac
      return 0 ;;
  esac
  echo "cmd $*" >> "$T/unexpected"; return 1
}
dumpsys() {
  echo "dumpsys $*" >> "$T/calls"
  if [ "$1" = nfc ]; then
    echo NOISE-DUMPSYS >&2
    echo "NfcService:"
    case "$(_gread nfc)" in
      1) echo "    mState=on"; echo "    mState=off" ;;
      0) echo "    mState=off"; echo "    mState=on" ;;
      *) echo "    mScreenState=ON" ;;
    esac
    return 0
  fi
  echo "dumpsys $*" >> "$T/unexpected"; return 1
}
svc() {
  echo "svc $*" >> "$T/calls"
  case "$1 $2" in
    "nfc enable") _gwrite nfc 1; return $? ;;
    "nfc disable") _gwrite nfc 0; return $? ;;
  esac
  echo "svc $*" >> "$T/unexpected"; return 1
}
ls() {
  if [ -f "$T/deny-ls" ]; then echo "ls: ${2:-$1}: Permission denied" >&2; return 1; fi
  command ls "$@"
}
EOF
  return 0
}

DRIVER='
STATE="$T/state"; LOG="$T/log"; RES="$T/res"
. "$R/stubs.sh"
case "$MODE" in
  op) op="$OPV"; uid="$UIDV"; name="$NAMEV"; . "$R/loc.sh"; . "$R/dt.sh"
      echo "the op block fell through" >> "$T/unexpected" ;;
  boot) op=bootsweep; uid=""; name=""; _swept=""; . "$R/loc.sh"; . "$R/dt.sh"; . "$R/boot.sh"
        printf "%s" "$_swept" > "$T/swept" ;;
  reap) op=cleanstorage; uid="$UIDV"; name=x; . "$R/loc.sh"; . "$R/dt.sh"; . "$R/reap.sh" ;;
esac'

# suite <roamd.sh> <shell path> <label> [quiet]: 0 all ok, 1 an assertion failed (the only verdict that convicts a
# mutant), 2 the harness could not run. prep must have run ($R).
suite() {
  local f="$1" SH="$2" LB="$3" quiet="${4:-}" PASS=0 FAIL=0 T out n v k cs end dl ml sm bs fx rl
  ok() { PASS=$((PASS+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$LB" "$1"; }
  no() { FAIL=$((FAIL+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$LB" "$1"; }

  # A device: $T/g.<key> is the toggle table, $T/nowhere/devtoggles.base the baseline record, $T/state/.devtoggles the
  # owner, $T/user/<n> user <n>'s CE directory (12 and 13 exist).
  mkdev() {
    T=$(mktemp -d -p "$W"); mkdir -p "$T/state" "$T/nowhere" "$T/user/12" "$T/user/13"
    : > "$T/calls"
  }
  setg() { printf '%s' "$2" > "$T/g.$1"; }
  getg() { if [ -f "$T/g.$1" ]; then cat "$T/g.$1"; else echo unset; fi; }
  setall() { setg airplane "$1"; setg saver "$2"; setg datasaver "$3"; setg nfc "$4"; }
  base() { if [ -f "$T/nowhere/devtoggles.base" ]; then cat "$T/nowhere/devtoggles.base"; else echo none; fi; }
  owner() { if [ -f "$T/state/.devtoggles" ]; then tr -d '\n' < "$T/state/.devtoggles"; else echo none; fi; }
  setbase() { printf '%b' "$1" > "$T/nowhere/devtoggles.base"; }
  setowner() { echo "$1" > "$T/state/.devtoggles"; }
  nwrites() { grep -cE '^(cmd connectivity airplane-mode|cmd power set-mode|cmd netpolicy set|svc nfc)' "$T/calls" 2>/dev/null || true; }
  ncalls() { grep -c . "$T/calls" 2>/dev/null || true; }
  drive() {  # drive <mode> <op> <uid> <name>
    env LC_ALL=C T="$T" R="$R" MODE="$1" OPV="${2:-}" UIDV="${3:-}" NAMEV="${4:-}" "$SH" -c "$DRIVER" >/dev/null 2>>"$T/stderr"
  }
  op() { drive op "$1" "$2" "$3"; cat "$T/res" 2>/dev/null; rm -f "$T/res"; }
  boot() { drive boot; cat "$T/swept" 2>/dev/null; }
  reap() { drive reap "" "$1"; }
  clean() {  # no harness error may hide behind a passing case
    if [ -s "$T/stderr" ] && grep -qE 'not found|unbound|[Ss]yntax error|bad substitution|parameter not set' "$T/stderr"; then
      no "$1: the harness reported $(head -n 1 "$T/stderr")"
    fi
    if [ -s "$T/stderr" ] && grep -q 'NOISE-' "$T/stderr"; then no "$1: a command's output reached stderr"; fi
    if [ -s "$T/unexpected" ]; then no "$1: unexpected calls: $(tr '\n' ';' < "$T/unexpected")"; fi
    rm -rf "$T"
  }
  FULL=$'airplane=0\nsaver=0\ndatasaver=0\nnfc=1'

  # --- the CLAIM ----------------------------------------------------------------------------------------------
  mkdev; setall 0 0 0 1
  out=$(op dtclaim 12 signin)
  [ "$out" = "OK CLAIMED 4" ] && ok "C1 a claim with no record -> OK CLAIMED 4" || no "C1 reply '$out'"
  [ "$(base)" = "$FULL" ] && ok "C1 the record holds the four keys in the fixed order" || no "C1 base '$(base)'"
  [ "$(owner)" = 12 ] && ok "C1 the owner is recorded" || no "C1 owner '$(owner)'"
  [ "$(nwrites)" = 0 ] && ok "C1 ZERO writes" || no "C1 $(nwrites) write(s)"
  grep -q '^\[roamd\] devtoggles user 12 (signin): recorded airplane=0 saver=0 datasaver=0 nfc=1 ' "$T/log" \
    && ok "C1 the log names the uid, keys and digits" || no "C1 log: $(cat "$T/log" 2>/dev/null)"
  [ -f "$T/nowhere/devtoggles.base.new" ] && no "C1 the scratch file is left behind" || ok "C1 no scratch file left"
  clean C1

  mkdev; setall 0 0 0 1
  op dtclaim 12 signin >/dev/null
  cp "$T/nowhere/devtoggles.base" "$T/first"
  setall 1 1 1 0
  out=$(op dtclaim 13 signin)
  cmp -s "$T/first" "$T/nowhere/devtoggles.base" && ok "C2 a second claim keeps the record byte for byte" \
    || no "C2 the record changed: $(base)"
  [ "$out" = "OK CLAIMED 4" ] && [ "$(owner)" = 13 ] && [ "$(nwrites)" = 0 ] \
    && ok "C2 ...replies OK CLAIMED 4, owner 13, no write" || no "C2 reply '$out', owner $(owner), $(nwrites) write(s)"
  clean C2

  mkdev; setall 0 0 0 1; : > "$T/blind-nfc"
  out=$(op dtclaim 12 signin)
  [ "$out" = "OK CLAIMED 3" ] && [ "$(base)" = $'airplane=0\nsaver=0\ndatasaver=0' ] \
    && ok "C3 an unreadable key is left out of the record" || no "C3 reply '$out', base '$(base)'"
  grep -q 'nfc unreadable' "$T/log" && ok "C3 ...and logged" || no "C3 log: $(cat "$T/log" 2>/dev/null)"
  clean C3

  mkdev; : > "$T/blind-airplane"; : > "$T/blind-saver"; : > "$T/blind-datasaver"; : > "$T/blind-nfc"
  out=$(op dtclaim 12 signin)
  [ "$out" = "OK CLAIMED 0" ] && [ "$(base)" = none ] && [ ! -f "$T/nowhere/devtoggles.base.new" ] \
    && ok "C4 nothing readable: no record file" || no "C4 reply '$out', base '$(base)'"
  clean C4

  # --- the RELEASE ---------------------------------------------------------------------------------------------
  mkdev; setall 0 0 0 0
  op dtclaim 12 signin >/dev/null
  setg airplane 1; setg nfc 1; : > "$T/calls"
  out=$(op dtrelease 12 signout)
  [ "$out" = "OK RESTORED 2" ] && ok "L1 a release after airplane and nfc were turned on -> OK RESTORED 2" || no "L1 reply '$out'"
  [ "$(getg airplane)" = 0 ] && [ "$(getg nfc)" = 0 ] && [ "$(getg saver)" = 0 ] && [ "$(getg datasaver)" = 0 ] \
    && ok "L1 all four read their baseline" || no "L1 values $(getg airplane)$(getg saver)$(getg datasaver)$(getg nfc)"
  [ "$(nwrites)" = 2 ] && grep -qx 'cmd connectivity airplane-mode disable' "$T/calls" && grep -qx 'svc nfc disable' "$T/calls" \
    && ok "L1 exactly those two writes" || no "L1 $(nwrites) write(s): $(tr '\n' ';' < "$T/calls")"
  [ "$(base)" = none ] && [ "$(owner)" = none ] && ok "L1 record and owner removed" || no "L1 base '$(base)', owner '$(owner)'"
  clean L1

  mkdev; setall 0 0 0 0; setbase 'airplane=0\nnfc=0\n'; setowner 13; setg airplane 1
  : > "$T/calls"
  out=$(op dtrelease 12 signout)
  [ "$out" = "OK KEPT" ] && [ "$(ncalls)" = 0 ] && [ "$(base)" = $'airplane=0\nnfc=0' ] && [ "$(owner)" = 13 ] && [ "$(getg airplane)" = 1 ] \
    && ok "L2 another live owner -> OK KEPT, zero calls, record and owner untouched" || no "L2 reply '$out', $(ncalls) call(s)"
  clean L2

  mkdev; setall 0 0 0 0; setbase 'airplane=0\n'; setowner 13; setg airplane 1; rmdir "$T/user/13"
  out=$(op dtrelease 12 signout)
  [ "$out" = "OK RESTORED 1" ] && [ "$(getg airplane)" = 0 ] && [ "$(owner)" = none ] \
    && ok "L3 an owner whose user is gone is no owner -> restored" || no "L3 reply '$out', airplane $(getg airplane)"
  clean L3
  mkdev; setall 0 0 0 0; setbase 'airplane=0\n'; setowner 13; setg airplane 1; rmdir "$T/user/13"; : > "$T/deny-ls"
  out=$(op dtrelease 12 signout)
  [ "$out" = "OK KEPT" ] && ok "L3 a denied directory check is not 'gone' -> OK KEPT" || no "L3 deny-ls reply '$out'"
  clean L3b

  mkdev; setall 0 0 0 0; setowner 12
  out=$(op dtrelease 12 signout)
  [ "$out" = "OK NONE" ] && [ "$(ncalls)" = 0 ] && [ "$(owner)" = none ] && [ "$(base)" = none ] \
    && ok "L4 no record -> OK NONE, zero calls, owner removed" || no "L4 reply '$out', $(ncalls) call(s), owner $(owner)"
  clean L4

  mkdev; setall 0 0 0 0
  op dtclaim 12 signin >/dev/null
  setg airplane 1; setg nfc 1; : > "$T/deny-airplane"
  out=$(op dtrelease 12 signout)
  [ "$out" = "ERR-DT airplane=1" ] && ok "L5 a denied write -> ERR-DT airplane=1" || no "L5 reply '$out'"
  [ "$(base)" = "airplane=0" ] && ok "L5 the record holds only the key not at baseline" || no "L5 base '$(base)'"
  [ "$(owner)" = 12 ] && [ "$(getg nfc)" = 0 ] && ok "L5 owner kept; the other key was restored" || no "L5 owner $(owner), nfc $(getg nfc)"
  rm -f "$T/deny-airplane"; : > "$T/calls"
  out=$(op dtrelease 12 reap)
  [ "$out" = "OK RESTORED 1" ] && [ "$(base)" = none ] && [ "$(owner)" = none ] && [ "$(getg airplane)" = 0 ] && [ "$(nwrites)" = 1 ] \
    && ok "L5 a second release with the deny lifted restores it" || no "L5 retry reply '$out', base '$(base)', $(nwrites) write(s)"
  clean L5
  mkdev; setall 0 0 0 0
  op dtclaim 12 signin >/dev/null
  setg datasaver 1; : > "$T/stuck-datasaver"
  out=$(op dtrelease 12 signout)
  [ "$out" = "ERR-DT datasaver=1" ] && [ "$(base)" = "datasaver=0" ] \
    && ok "L5 a stuck write (exit 0, no change) -> ERR-DT, never RESTORED" || no "L5 stuck reply '$out', base '$(base)'"
  clean L5b
  mkdev; setall 0 0 0 0
  op dtclaim 12 signin >/dev/null
  setg saver 1; setg datasaver 1; : > "$T/deny-saver"; : > "$T/stuck-datasaver"
  out=$(op dtrelease 12 signout)
  [ "$out" = "ERR-DT saver=1 datasaver=1" ] && ok "L5 two failures are both named, space-separated" || no "L5 two-key reply '$out'"
  clean L5c

  mkdev; setall 1 0 1 0
  op dtclaim 12 signin >/dev/null
  : > "$T/calls"
  out=$(op dtrelease 12 signout)
  [ "$out" = "OK RESTORED 0" ] && [ "$(nwrites)" = 0 ] && [ "$(base)" = none ] && [ "$(owner)" = none ] \
    && ok "L6 everything already at baseline -> zero writes, OK RESTORED 0, record dropped" \
    || no "L6 reply '$out', $(nwrites) write(s), base '$(base)'"
  clean L6

  # --- the REAP line and the BOOT SWEEP category -------------------------------------------------------------------
  cs=$(grep -nxF "$CS_HDR" "$f" | cut -d: -f1)
  dl=$(grep -nxF "$DT_REAP" "$f" | cut -d: -f1)
  ml=$(grep -nxF "$MD_REAP" "$f" | cut -d: -f1)
  if [ "$(grep -cxF "$DT_REAP" "$f")" = 1 ] && [ "$(grep -cxF "$CS_HDR" "$f")" = 1 ] && [ -n "$ml" ]; then
    end=$(awk -v s="$cs" 'NR > s && $0 == "fi" {print NR; exit}' "$f")
    sm=$(awk -v s="$cs" 'NR > s && $0 == "  stop_mediad" || (NR > s && index($0, "  stop_mediad ") == 1) {print NR; exit}' "$f")
    [ -n "$end" ] && [ "$dl" -gt "$cs" ] && [ "$dl" -lt "$end" ] && [ "$dl" = $((ml + 1)) ] && [ -n "$sm" ] && [ "$dl" -lt "$sm" ] \
      && ok "R1 the reap line is in cleanstorage once, right after md's and before stop_mediad" \
      || no "R1 placement: cleanstorage $cs..$end, md $ml, dt $dl, stop_mediad ${sm:-none}"
  else
    no "R1 the reap line is not in the file exactly once (cleanstorage header $(grep -cxF "$CS_HDR" "$f"))"
  fi
  mkdev; setall 0 0 0 0
  op dtclaim 12 signin >/dev/null
  setg nfc 1; : > "$T/calls"
  reap 12
  [ "$(getg nfc)" = 0 ] && [ "$(nwrites)" = 1 ] && [ "$(owner)" = none ] && [ "$(base)" = none ] \
    && ok "R2 the reap restores for the owner" || no "R2 nfc $(getg nfc), $(nwrites) write(s), owner $(owner)"
  clean R2
  mkdev; setall 0 0 0 0; setbase 'nfc=0\n'; setowner 13; setg nfc 1
  reap 12
  [ "$(getg nfc)" = 1 ] && [ "$(owner)" = 13 ] && ok "R2 ...and leaves another live owner alone" || no "R2 other owner: nfc $(getg nfc)"
  clean R2b

  bs=$(grep -nxF "$BS_HDR" "$f" | cut -d: -f1)
  fx=$(grep -nxF "$BOOT_HDR" "$f" | cut -d: -f1)
  rl=$(grep -n -F "$RESULT_PFX" "$f" | cut -d: -f1 | head -n 1)
  if [ "$(grep -cxF "$BOOT_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$BOOT_END" "$f")" = 1 ] && [ -n "$bs" ] && [ -n "$rl" ]; then
    [ "$fx" -gt "$bs" ] && [ "$fx" -lt "$rl" ] && ok "B1 fix 13 is in bootsweep once, before the result line" \
      || no "B1 placement: bootsweep $bs, fix 13 $fx, result $rl"
  else
    no "B1 fix 13's header or its append is not in the file exactly once"
  fi
  mkdev; setall 1 0 1 0; setbase 'airplane=0\ndatasaver=0\n'
  out=$(boot)
  [ "$out" = " devtoggles=baseline" ] && [ "$(getg airplane)" = 0 ] && [ "$(getg datasaver)" = 0 ] && [ "$(base)" = none ] \
    && ok "B2 a record and no owner: restored -> devtoggles=baseline, record removed" \
    || no "B2 _swept '$out', airplane $(getg airplane), datasaver $(getg datasaver), base $(base)"
  clean B2
  mkdev; setall 1 0 0 0; setbase 'airplane=0\n'; setowner 12
  out=$(boot)
  [ "$out" = " devtoggles=KEPT:user12" ] && [ "$(ncalls)" = 0 ] && [ "$(getg airplane)" = 1 ] && [ "$(base)" = "airplane=0" ] \
    && ok "B3 a live owner -> devtoggles=KEPT:user12, nothing written" || no "B3 _swept '$out', $(ncalls) call(s)"
  clean B3
  mkdev; setall 1 0 0 0
  out=$(boot)
  [ "$out" = " devtoggles=none" ] && [ "$(ncalls)" = 0 ] && ok "B4 no record -> devtoggles=none, zero calls" \
    || no "B4 _swept '$out', $(ncalls) call(s)"
  clean B4
  mkdev; setall 1 0 0 1; setbase 'airplane=0\nnfc=0\n'; : > "$T/deny-airplane"; : > "$T/deny-nfc"
  out=$(boot)
  case "$out" in
    " devtoggles=FAILED("*")") case "${out# }" in *' '*) no "B5 not one space-free token: '$out'" ;; *) ok "B5 a failed restore -> one token $out" ;; esac ;;
    *) no "B5 _swept '$out'" ;;
  esac
  [ "$out" = " devtoggles=FAILED(airplane,nfc)" ] && [ "$(base)" = $'airplane=0\nnfc=0' ] \
    && ok "B5 ...naming both keys, and the record is kept" || no "B5 _swept '$out', base '$(base)'"
  clean B5

  # --- the ops' arguments and the log ------------------------------------------------------------------------
  for o in dtclaim dtrelease; do
    for v in abc 9 1x ''; do
      mkdev; setall 1 1 1 1
      out=$(op "$o" "$v" signin)
      [ "$out" = ERR-UID ] && [ "$(ncalls)" = 0 ] && [ "$(base)" = none ] && ok "E1 $o refuses uid '$v'" \
        || no "E1 $o '$v' -> '$out', $(ncalls) call(s), base $(base)"
      clean "E1 $o $v"
    done
  done
  mkdev; setall 0 0 0 0
  op dtclaim 12 'zq Alice Smith' >/dev/null
  if grep -q '(other)' "$T/log" && ! grep -qE 'zq|Alice|Smith' "$T/log"; then ok "E2 the reason slot cannot put a name into the log"
  else no "E2 log: $(cat "$T/log" 2>/dev/null)"; fi
  setg airplane 1
  op dtrelease 12 'Bob' >/dev/null
  if ! grep -q 'Bob' "$T/log" && grep -q 'devtoggles user 12 (other): RESTORED 1 ' "$T/log"; then ok "E2 ...nor can a release's"
  else no "E2 release log: $(cat "$T/log" 2>/dev/null)"; fi
  clean E2
  mkdev; setall 0 0 0 0
  op dtclaim 12 signin >/dev/null
  setall 1 1 1 1; : > "$T/deny-nfc"
  op dtrelease 12 signout >/dev/null
  rm -f "$T/deny-nfc"
  op dtrelease 12 signout >/dev/null
  if ! grep -q 'NOISE-' "$T/log"; then ok "E3 no command output reaches the log"; else no "E3 log: $(cat "$T/log")"; fi
  clean E3

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
mut "X1 the record is rewritten on a second claim"       's/(  if )\[ -f "\$DT_BASE" \]; then(\n    # A record exists)/$1false; then$2/'
mut "X2 a claim writes a setting"                        's/(      _v=\$\(dt_read "\$_k"\)\n)(      case)/$1      dt_write "\$_k" "\$_v"\n$2/'
mut "X3 a release ignores another owner"                 's/if \[ -n "\$_o" \] && \[ "\$_o" != "\$_u" \]; then(\n    echo "\[roamd\] devtoggles)/if false; then$1/'
mut "X4 a failed write still replies OK"                 's/(  dt_restore\n  if )\[ -z "\$DT_FAILED" \](; then\n    rm -f "\$DT_OWNER")/$1true$2/'
mut "X5 the record is dropped on a partial failure"      's/  elif ! dt_base_put "\$_keep"; then/  elif rm -f "\$DT_BASE"; false; then/'
mut "X6 the cleanstorage line is removed"                's/^  dt_release "\$uid" reap   # NWP-20261027-05[^\n]*\n//m'
mut "X7 the boot category ignores the record"            's/if \[ "\$\(dt_base_count\)" = 0 \]; then rm -f "\$DT_BASE"; DT_BOOT=none/if true; then rm -f "\$DT_BASE"; DT_BOOT=none/'
mut "X8 an unreadable key is recorded as 0"              's/(dt_read\(\) \{.*?)\*\) echo \x27\?\x27 ;; esac/$1*) echo 0 ;; esac/s'
[ "$fails" = 0 ] && echo "== all $nmut mutations convicted (shells: ${LABELS[*]})" || { echo "== $fails mutation outcome(s) not convicted"; exit 1; }
