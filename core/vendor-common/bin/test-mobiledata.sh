#!/usr/bin/env bash
# test-mobiledata.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's SESSION-SCOPED MOBILE DATA (NWP-20261026-05), run for
# real against a stubbed `settings` and `cmd`, under every shell the runner has, rather than grepped.
#
# WHY THIS IS COMMITTED. Mobile data is a DEVICE setting. roamd now applies one profile's choice of it while that
# profile's session is in front and puts the GATE'S OWN value back whenever it is not. Unlike location (whose baseline
# is the constant 0), the gate's value is known only to the phone, so it is kept in a one-digit record outside the
# tmpfs. Every way this goes wrong is silent: a claim that recaptures the record records a PROFILE's value as the
# gate's (every later sign-out leaves the phone at that profile's choice); a release that ignores the owner switches
# the data of the session now in front; a boot sweep that never restores leaves the profile's choice on after a power
# loss; a write that reads as applied when telephony refused it lies to the chooser; a record that outlives a refused
# write retries at every boot until a stale digit overrides the owner's own setting. What this pins:
#   - the CHOICE (op mdapply): tri-state -- the first mobiledata= line, blanks and CR stripped, exactly 1 or 0; anything
#     else is no choice, which means the gate's value; the reply is OK APPLIED only when the value reads back, and ends ` data_roaming=?` here (the real token is test-dataroaming.sh's);
#   - the BASELINE RECORD: written before the phone is changed, only when none exists, never rewritten (the recapture
#     trap), kept when the write is refused, dropped by a release or boot sweep that finds the phone already at it;
#   - the RELEASE (op mdrelease, and cleanstorage's reap) and the BOOT SWEEP (fix 12): restore, keep for another live
#     owner, nothing to do without a record, one space-free token on every path, inside the op and before its result line;
#   - the PER-SUBSCRIPTION key, and with no default data subscription ? and nothing written, the legacy mobile_data
#     key never read (NWP-20261117-17); LOGS carry the uid and values only and no cmd or settings output reaches them.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and its device roots are substituted (each
# substitution is checked); if an anchor moves, extraction fails loudly (exit 2) rather than a stale copy passing.
#
#   bash test-mobiledata.sh            # the behaviour cases, under bash, sh, dash and mksh where present
#   bash test-mobiledata.sh --mutate   # ... plus broken copies that must each be CONVICTED, under each shell
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

BEGIN_HDR='# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (begin) ------------------------------------------------------------'
END_HDR='# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (end) --------------------------------------------------------------'
LBEGIN_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------'
LEND_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------'
BOOT_HDR='  # --- fix 12: mobiledata (NWP-20261026-05) ---'
BOOT_END='  _swept="$_swept mobiledata=$MD_BOOT"'
FIX11_END='  _swept="$_swept locglobals=$LOC_BOOT"'
LOC_REAP='  loc_release "$uid" reap   # NWP-20261016-45: the reap'"'"'s backstop for the location globals; another owner is left alone'
MD_REAP='  md_release "$uid" reap   # NWP-20261026-05: the reap'"'"'s backstop for mobile data; another owner is left alone'
APK_PFX='LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk '
ROOT_PFX='LOC_USER_ROOT=/data/user '
BASE_PFX='MD_BASE=/data/nowhere/mobiledata.base '

# prep <roamd.sh>: extract and substitute the blocks into a fresh dir ($R). 0, or 2 (the harness cannot run).
prep() {
  local f="$1" blk lblk boot
  R=$(mktemp -d -p "$W") || return 2
  [ "$(grep -cxF "$BEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$END_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the mobile data block's begin/end anchors in $f" >&2; return 2; }
  [ "$(grep -cxF "$LBEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$LEND_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the location block's begin/end anchors in $f" >&2; return 2; }
  blk=$(awk -v b="$BEGIN_HDR" -v e="$END_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$blk" in *'md_claim()'*'md_release()'*'md_boot()'*'"$op" = "mdapply"'*) ;;
    *) echo "EXTRACTION FAILED: the functions or the op in the mobile data block" >&2; return 2 ;; esac
  lblk=$(awk -v b="$LBEGIN_HDR" -v e="$LEND_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$lblk" in *'loc_gone()'*'loc_why()'*) ;; *) echo "EXTRACTION FAILED: loc_gone/loc_why" >&2; return 2 ;; esac
  boot=$(awk -v h="$BOOT_HDR" -v e="$BOOT_END" '$0 == h {on = 1} on {print} on && $0 == e {exit}' "$f")
  case "$boot" in *md_boot*'mobiledata=$MD_BOOT'*) ;; *) echo "EXTRACTION FAILED: the bootsweep category" >&2; return 2 ;; esac
  [ "$(grep -c "^$APK_PFX" <<< "$lblk")" = 1 ] && [ "$(grep -c "^$ROOT_PFX" <<< "$lblk")" = 1 ] \
    && [ "$(grep -c "^$BASE_PFX" <<< "$blk")" = 1 ] \
    || { echo "EXTRACTION FAILED: a device-root line to substitute" >&2; return 2; }
  lblk=$(sed -e 's@^LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk @LOC_PROVIDER_APK="$T/none.apk" @' \
             -e 's@^LOC_USER_ROOT=/data/user @LOC_USER_ROOT="$T/user" @' <<< "$lblk")
  blk=$(sed -e 's@^MD_BASE=/data/nowhere/mobiledata.base @MD_BASE="$T/nowhere/mobiledata.base" @' <<< "$blk")
  [ "$(grep -c '^LOC_USER_ROOT="\$T/user" ' <<< "$lblk")" = 1 ] && [ "$(grep -c '^LOC_PROVIDER_APK="\$T/none.apk" ' <<< "$lblk")" = 1 ] \
    && [ "$(grep -c '^MD_BASE="\$T/nowhere/mobiledata.base" ' <<< "$blk")" = 1 ] \
    || { echo "EXTRACTION FAILED: a substitution did not apply exactly once" >&2; return 2; }
  if grep -v '^[[:space:]]*#' <<< "$lblk"$'\n'"$blk"$'\n'"$boot" | grep -qE '/system/|/data/'; then
    echo "EXTRACTION FAILED: a device path is left in the live code after substitution" >&2; return 2
  fi
  printf '%s\n' "$lblk" > "$R/loc.sh"; printf '%s\n' "$blk" > "$R/md.sh"; printf '%s\n' "$boot" > "$R/boot.sh"
  printf '%s\n' "$MD_REAP" > "$R/reap.sh"
  bash -n "$R/loc.sh" && bash -n "$R/md.sh" && bash -n "$R/boot.sh" \
    || { echo "EXTRACTION FAILED: an extracted block does not parse" >&2; return 2; }
  cat > "$R/stubs.sh" <<'EOF'
settings() {
  echo "settings $*" >> "$T/calls"
  if [ "$1 $2" = "get global" ]; then
    echo NOISE-SETTINGS >&2
    [ -f "$T/blind-get" ] && return 0
    if [ -f "$T/g.$3" ]; then cat "$T/g.$3"; echo; else echo null; fi
    return 0
  fi
  echo "settings $*" >> "$T/unexpected"; return 1
}
cmd() {
  echo "cmd $*" >> "$T/calls"
  if [ "$1 $2" = "phone data" ] && { [ "$3" = enable ] || [ "$3" = disable ]; }; then
    echo NOISE-CMD; echo NOISE-CMD >&2
    [ -f "$T/deny-cmd" ] && return 1
    [ -f "$T/stuck-cmd" ] && return 0
    _s=""; [ -f "$T/g.multi_sim_data_call" ] && _s=$(cat "$T/g.multi_sim_data_call")
    case "$_s" in ''|*[!0-9]*|0*) _k=mobile_data ;; *) _k=mobile_data$_s ;; esac
    if [ "$3" = enable ]; then printf 1 > "$T/g.$_k"; else printf 0 > "$T/g.$_k"; fi
    return 0
  fi
  echo "cmd $*" >> "$T/unexpected"; return 1
}
# NWP-20261028-07: data roaming is test-dataroaming.sh's (it runs the real dr_claim and dr_release); here the token the op
# arm appends to an mdapply reply is fixed at ?.
dr_claim() { DR_SEEN='?'; }
dr_release() { :; }
hs_release() { HS_VERDICT="OK RELEASED"; }   # NWP-20261028-10: the hotspot is test-hotspot-release.sh's
userdir_recheck() { :; }; userdir_pending_add() { :; }   # NWP-20261104-14: the users/<n> re-check is test-userdir-orphan.sh, not this suite
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
  op) op="$OPV"; uid="$UIDV"; name="$NAMEV"; . "$R/loc.sh"; . "$R/md.sh"
      echo "the op block fell through" >> "$T/unexpected" ;;
  boot) op=bootsweep; uid=""; name=""; _swept=""; . "$R/loc.sh"; . "$R/md.sh"; . "$R/boot.sh"
        printf "%s" "$_swept" > "$T/swept" ;;
  reap) op=cleanstorage; uid="$UIDV"; name=x; . "$R/loc.sh"; . "$R/md.sh"; . "$R/reap.sh" ;;
esac'

# suite <roamd.sh> <shell path> <label> [quiet]: 0 all ok, 1 an assertion failed (the only verdict that convicts a
# mutant), 2 the harness could not run. prep must have run ($R).
suite() {
  local f="$1" SH="$2" LB="$3" quiet="${4:-}" PASS=0 FAIL=0 T out at n v o c
  ok() { PASS=$((PASS+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$LB" "$1"; }
  no() { FAIL=$((FAIL+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$LB" "$1"; }

  # A device: $T/g.<key> is the global table, $T/nowhere/mobiledata.base the baseline record, $T/state/.mobiledata the
  # owner, $T/user/<n> user <n>'s CE directory (12 and 13 exist).
  mkdev() {
    T=$(mktemp -d -p "$W"); mkdir -p "$T/state" "$T/nowhere" "$T/user/12/com.nowhere.chooser/files" "$T/user/13/com.nowhere.chooser/files"
    : > "$T/calls"; setg multi_sim_data_call 1   # the default data subscription is 1 unless a case says otherwise
  }
  prefs() { printf '%b' "$2" > "$T/user/$1/com.nowhere.chooser/files/nowhere-prefs"; }
  setg() { printf '%s' "$2" > "$T/g.$1"; }
  nosub() { rm -f "$T/g.multi_sim_data_call"; }   # no default data subscription: multi_sim_data_call unset
  getg() { if [ -f "$T/g.$1" ]; then cat "$T/g.$1"; else echo unset; fi; }
  base() { if [ -f "$T/nowhere/mobiledata.base" ]; then cat "$T/nowhere/mobiledata.base"; else echo none; fi; }
  owner() { if [ -f "$T/state/.mobiledata" ]; then tr -d '\n' < "$T/state/.mobiledata"; else echo none; fi; }
  setbase() { printf '%s' "$1" > "$T/nowhere/mobiledata.base"; }
  setowner() { echo "$1" > "$T/state/.mobiledata"; }
  ncmd() { grep -c '^cmd ' "$T/calls" 2>/dev/null || true; }
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
    if [ -s "$T/stderr" ] && grep -q 'NOISE-' "$T/stderr"; then no "$1: cmd or settings output reached stderr"; fi
    if [ -s "$T/unexpected" ]; then no "$1: unexpected calls: $(tr '\n' ';' < "$T/unexpected")"; fi
    rm -rf "$T"
  }

  # --- the CLAIM ----------------------------------------------------------------------------------------------
  mkdev; prefs 12 'tz=\nmobiledata=1\n'; setg mobile_data1 0
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && ok "A1 choice 1 at gate 0 -> OK APPLIED mobile_data=1" || no "A1 reply '$out'"
  [ "$(base)" = 0 ] && ok "A1 the gate's 0 is recorded" || no "A1 base '$(base)', want 0"
  [ "$(owner)" = 12 ] && [ "$(getg mobile_data1)" = 1 ] && ok "A1 owner 12, value 1" || no "A1 owner '$(owner)', value $(getg mobile_data1)"
  [ "$(ncmd)" = 1 ] && ok "A1 one cmd call" || no "A1 $(ncmd) cmd call(s)"
  grep -q '^\[roamd\] mobiledata user 12 (signin): mobile_data=1 APPLIED (reads 1) ' "$T/log" \
    && ok "A1 the log names the uid and values" || no "A1 log: $(cat "$T/log" 2>/dev/null)"
  clean A1

  mkdev; prefs 12 'mobiledata=0\n'; setg mobile_data1 1
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=0 data_roaming=?" ] && [ "$(base)" = 1 ] && [ "$(getg mobile_data1)" = 0 ] \
    && ok "A2 choice 0 at gate 1 -> baseline 1, value 0" || no "A2 reply '$out', base $(base), value $(getg mobile_data1)"
  clean A2

  for v in 0 1; do
    mkdev; prefs 12 'tz=\nlocale=en-US\n'; setg mobile_data1 "$v"
    out=$(op mdapply 12 signin)
    [ "$out" = "OK APPLIED mobile_data=$v data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] && [ "$(getg mobile_data1)" = "$v" ] \
      && ok "A3 no choice at $v: no cmd call, no baseline, OK APPLIED mobile_data=$v" \
      || no "A3 ($v) reply '$out', $(ncmd) cmd, base $(base)"
    [ "$(owner)" = 12 ] && ok "A3 ($v) the owner is recorded" || no "A3 ($v) owner '$(owner)'"
    clean "A3 $v"
  done

  mkdev; prefs 12 'mobiledata=1\n'; setg mobile_data1 1
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] \
    && ok "A4 a choice equal to the current value writes nothing" || no "A4 reply '$out', $(ncmd) cmd, base $(base)"
  clean A4

  mkdev; prefs 12 'mobiledata=0\nmobiledata=1\n'; setg mobile_data1 1
  out=$(op mdapply 12 live)
  [ "$out" = "OK APPLIED mobile_data=0 data_roaming=?" ] && [ "$(base)" = 1 ] && ok "A5 the first line wins" || no "A5 first-line: '$out', base $(base)"
  clean A5a
  mkdev; prefs 12 'mobiledata= 1 \r\n'; setg mobile_data1 0
  out=$(op mdapply 12 live)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && [ "$(getg mobile_data1)" = 1 ] && ok "A5 ' 1 \\r' is On" || no "A5 blanks/CR: '$out'"
  clean A5b
  for v in 'mobiledatax=1' 'MOBILEDATA=1' 'mobiledata=2' 'mobiledata=true' 'mobiledata=' 'xmobiledata=1'; do
    mkdev; prefs 12 "$v\n"; setg mobile_data1 0
    out=$(op mdapply 12 live)
    [ "$out" = "OK APPLIED mobile_data=0 data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] \
      && ok "A5 '$v' is no choice" || no "A5 '$v' -> '$out', $(ncmd) cmd, base $(base)"
    clean "A5 $v"
  done

  mkdev; prefs 12 'mobiledata=1\n'
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=? data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] \
    && ok "A6 a choice with an unreadable current value: ERR-MD, no cmd call, no baseline" \
    || no "A6 reply '$out', $(ncmd) cmd, base $(base)"
  clean A6

  mkdev; prefs 12 'mobiledata=1\n'; setg mobile_data1 0; : > "$T/deny-cmd"
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=0 data_roaming=?" ] && ok "A7 a denied write -> ERR-MD mobile_data=0" || no "A7 reply '$out'"
  [ "$(base)" = 0 ] && ok "A7 the baseline record is KEPT (written before the write)" || no "A7 base '$(base)'"
  grep -q 'NOT APPLIED (reads 0)' "$T/log" && ok "A7 the log says NOT APPLIED" || no "A7 log: $(cat "$T/log" 2>/dev/null)"
  clean A7

  mkdev; prefs 12 'mobiledata=1\n'; setg mobile_data1 0; : > "$T/stuck-cmd"
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=0 data_roaming=?" ] && ok "A8 a stuck write (exit 0, no change) -> ERR-MD" || no "A8 reply '$out'"
  clean A8

  mkdev; prefs 12 'mobiledata=1\n'; prefs 13 'tz=\n'; setg mobile_data1 0
  op mdapply 12 signin >/dev/null
  out=$(op mdapply 13 signin)
  [ "$(base)" = 0 ] && [ "$(getg mobile_data1)" = 0 ] && [ "$out" = "OK APPLIED mobile_data=0 data_roaming=?" ] \
    && ok "A9 the recapture trap: 13's no-choice claim keeps the baseline 0 and sets 0" \
    || no "A9a reply '$out', base $(base), value $(getg mobile_data1)"
  clean A9a
  mkdev; prefs 12 'mobiledata=1\n'; prefs 13 'mobiledata=0\n'; setg mobile_data1 0
  op mdapply 12 signin >/dev/null
  out=$(op mdapply 13 signin)
  [ "$(base)" = 0 ] && [ "$out" = "OK APPLIED mobile_data=0 data_roaming=?" ] && ok "A9 ...and 13's Off claim does not recapture it either" \
    || no "A9b reply '$out', base $(base)"
  clean A9b

  mkdev; prefs 12 'mobiledata=1\n'; setg multi_sim_data_call 3; setg mobile_data3 0; setg mobile_data1 1; setg mobile_data 1
  out=$(op mdapply 12 signin)
  [ "$out" = "OK APPLIED mobile_data=1 data_roaming=?" ] && [ "$(getg mobile_data3)" = 1 ] && [ "$(getg mobile_data)" = 1 ] && [ "$(ncmd)" = 1 ] \
    && [ "$(base)" = 0 ] && ok "A10 multi_sim_data_call=3 reads and writes mobile_data3" \
    || no "A10 reply '$out', mobile_data3 $(getg mobile_data3), $(ncmd) cmd, base $(base)"
  clean A10a
  # NWP-20261117-17: with no default data subscription the legacy mobile_data key is no SIM's value. A claim reads no
  # setting, writes nothing and replies ERR-MD (lynx 2026102901: legacy 1 while both SIMs read 0 -> OK APPLIED, a lie).
  for v in unset null -1 0 x1; do
    for c in 'mobiledata=1\n' 'tz=\n'; do
      mkdev; prefs 12 "$c"; setg mobile_data 1; setg mobile_data1 0
      if [ "$v" = unset ]; then nosub; else setg multi_sim_data_call "$v"; fi
      out=$(op mdapply 12 signin)
      n=$(grep -cxF 'settings get global mobile_data' "$T/calls")
      [ "$out" = "ERR-MD mobile_data=? data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] \
        && [ "$(getg mobile_data)" = 1 ] && [ "$(getg mobile_data1)" = 0 ] && [ "$n" = 0 ] \
        && ok "A10 multi_sim_data_call=$v, prefs '${c%\\n}': ERR-MD, no cmd call, no baseline, the legacy key never read" \
        || no "A10 ($v, '${c%\\n}') reply '$out', $(ncmd) cmd, base $(base), $n legacy read(s)"
      grep -q '^\[roamd\] mobiledata user 12 (signin): no default data subscription -- nothing written ' "$T/log" \
        && ok "A10 ($v, '${c%\\n}') the log says no default data subscription" || no "A10 ($v) log: $(cat "$T/log" 2>/dev/null)"
      clean "A10 $v"
    done
  done

  mkdev; nosub; setbase 0; prefs 12 'mobiledata=1\n'; setg mobile_data 0
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=? data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = 0 ] && [ "$(getg mobile_data)" = 0 ] \
    && ok "A12 no subscription with a baseline record: ERR-MD, no cmd call, the record kept" \
    || no "A12 reply '$out', $(ncmd) cmd, base $(base), legacy $(getg mobile_data)"
  grep -q '^\[roamd\] mobiledata user 12 (signin): no default data subscription -- nothing written ' "$T/log" \
    && ok "A12 the log says no default data subscription" || no "A12 log: $(cat "$T/log" 2>/dev/null)"
  clean A12

  mkdev; setbase 0; prefs 12 'mobiledata=1\n'
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=? data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = 0 ] \
    && ok "A13 an unreadable mobile_data1 with a baseline record: ERR-MD, no cmd call, the record kept" \
    || no "A13 reply '$out', $(ncmd) cmd, base $(base)"
  grep -q '^\[roamd\] mobiledata user 12 (signin): current value unreadable -- nothing written ' "$T/log" \
    && ok "A13 the log says the current value is unreadable" || no "A13 log: $(cat "$T/log" 2>/dev/null)"
  clean A13

  mkdev; prefs 12 'tz=\n'
  out=$(op mdapply 12 signin)
  [ "$out" = "ERR-MD mobile_data=? data_roaming=?" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] \
    && ok "A11 no choice, no record, unreadable current: ERR-MD mobile_data=?, nothing written" \
    || no "A11 reply '$out', $(ncmd) cmd, base $(base)"
  grep -q '^\[roamd\] mobiledata user 12 (signin): current value unreadable and no choice -- nothing written ' "$T/log" \
    && ok "A11 the log says unreadable and no choice" || no "A11 log: $(cat "$T/log" 2>/dev/null)"
  clean A11

  # --- the RELEASE --------------------------------------------------------------------------------------------
  mkdev; setg mobile_data1 1; setbase 0; setowner 12
  out=$(op mdrelease 12 signout)
  [ "$out" = "OK BASELINE mobile_data=0" ] && [ "$(getg mobile_data1)" = 0 ] && [ "$(base)" = none ] && [ "$(owner)" = none ] \
    && ok "B1 the owner's release restores the gate's value and removes both records" \
    || no "B1 reply '$out', value $(getg mobile_data1), base $(base), owner $(owner)"
  clean B1

  mkdev; setg mobile_data1 1; setbase 0; setowner 13
  out=$(op mdrelease 12 reap)
  [ "$out" = "OK KEPT" ] && [ "$(ncalls)" = 0 ] && [ "$(getg mobile_data1)" = 1 ] && [ "$(base)" = 0 ] && [ "$(owner)" = 13 ] \
    && ok "B2 another live owner: OK KEPT, no call, nothing changed" \
    || no "B2 reply '$out', $(ncalls) call(s), value $(getg mobile_data1), base $(base), owner $(owner)"
  clean B2

  mkdev; setg mobile_data1 1; setbase 0; setowner 14
  out=$(op mdrelease 12 reap)
  [ "$out" = "OK BASELINE mobile_data=0" ] && [ "$(getg mobile_data1)" = 0 ] \
    && ok "B3 an owner whose user is gone is no owner: restored" || no "B3 reply '$out', value $(getg mobile_data1)"
  clean B3

  mkdev; setg mobile_data1 1; setbase 0; setowner 14; : > "$T/deny-ls"
  out=$(op mdrelease 12 reap)
  [ "$out" = "OK KEPT" ] && [ "$(owner)" = 14 ] && ok "B4 a denied lookup is not proof the owner is gone: KEPT" \
    || no "B4 reply '$out', owner $(owner)"
  clean B4

  mkdev; setg mobile_data1 1; setowner 12
  out=$(op mdrelease 12 signout)
  [ "$out" = "OK NONE" ] && [ "$(ncmd)" = 0 ] && [ "$(owner)" = none ] && [ "$(getg mobile_data1)" = 1 ] \
    && ok "B5 no record: OK NONE, no cmd call, the owner forgotten" || no "B5 reply '$out', $(ncmd) cmd, owner $(owner)"
  clean B5

  mkdev; setg mobile_data1 1; setbase 0; setowner 12; : > "$T/deny-cmd"
  out=$(op mdrelease 12 signout)
  [ "$out" = "ERR-MD mobile_data=1" ] && [ "$(base)" = 0 ] && [ "$(owner)" = 12 ] \
    && ok "B6 a failed restore keeps both records and replies ERR-MD" \
    || no "B6 reply '$out', base $(base), owner $(owner)"
  clean B6

  mkdev; setg mobile_data1 0; setbase 0; setowner 12
  out=$(op mdrelease 12 signout)
  [ "$out" = "OK BASELINE mobile_data=0" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] && [ "$(owner)" = none ] \
    && ok "B7 the phone already reads the baseline (a refused claim): dropped with ZERO cmd calls" \
    || no "B7 reply '$out', $(ncmd) cmd, base $(base), owner $(owner)"
  clean B7

  mkdev; nosub; setg mobile_data 1; setbase 0; setowner 12
  out=$(op mdrelease 12 signout)
  [ "$out" = "ERR-MD mobile_data=?" ] && [ "$(base)" = 0 ] && [ "$(owner)" = 12 ] \
    && ok "B8 no subscription: the release replies ERR-MD and keeps both records" \
    || no "B8 reply '$out', base $(base), owner $(owner)"
  clean B8

  # --- the REAP -------------------------------------------------------------------------------------------------
  at=$(awk -v l="$LOC_REAP" -v m="$MD_REAP" '/^if \[ "\$op" = "cleanstorage" \]; then$/ {op = NR} $0 == l {ll = NR} $0 == m {ml = NR}
    op && !mm && /^  stop_mediad / {mm = NR} END {print op " " ll " " ml " " mm}' "$f")
  set -- $at
  if [ "$#" = 4 ] && [ "$1" -lt "$2" ] && [ "$3" = $(( $2 + 1 )) ] && [ "$3" -lt "$4" ] && [ "$(grep -cxF "$MD_REAP" "$f")" = 1 ]; then
    ok "C1 cleanstorage releases mobile data, once, right after the location release and before stop_mediad"
  else no "C1 the reap's md release line is missing, duplicated or misplaced (op/loc/md/stop_mediad: $at)"; fi
  mkdev; setg mobile_data1 1; setbase 0; setowner 12
  reap 12
  [ "$(getg mobile_data1)" = 0 ] && [ "$(base)" = none ] && [ "$(owner)" = none ] \
    && ok "C2 the reap of the owner restores the gate's value" || no "C2 value $(getg mobile_data1), base $(base), owner $(owner)"
  clean C2

  # --- the BOOT SWEEP -------------------------------------------------------------------------------------------
  at=$(awk -v h="$BOOT_HDR" -v f11="$FIX11_END" '/^if \[ "\$op" = "bootsweep" \]; then$/ {op = NR} $0 == f11 {p = NR} $0 == h {blk = NR}
    /echo "\[roamd\] bootsweep result:\$_swept/ {res = NR} END {print (op && p > op && blk > p && res > blk) ? "in" : "out"}' "$f")
  [ "$at" = in ] && [ "$(grep -cxF "$BOOT_HDR" "$f")" = 1 ] \
    && ok "D1 the category sits inside the bootsweep op, once, after fix 11 and before the result line" || no "D1 the category is misplaced"
  mkdev; setg mobile_data1 1; setbase 0
  out=$(boot)
  [ "$out" = " mobiledata=baseline" ] && [ "$(getg mobile_data1)" = 0 ] && [ "$(base)" = none ] \
    && ok "D2 a record and no owner: restored -> mobiledata=baseline" || no "D2 _swept '$out', value $(getg mobile_data1), base $(base)"
  clean D2
  mkdev; setg mobile_data1 1; setbase 0; setowner 12
  out=$(boot)
  [ "$out" = " mobiledata=KEPT:user12" ] && [ "$(ncalls)" = 0 ] && [ "$(getg mobile_data1)" = 1 ] && [ "$(base)" = 0 ] \
    && ok "D3 a live owner -> mobiledata=KEPT:user12, nothing written" || no "D3 _swept '$out', $(ncalls) call(s)"
  clean D3
  mkdev; setg mobile_data1 1
  out=$(boot)
  [ "$out" = " mobiledata=none" ] && [ "$(ncalls)" = 0 ] && ok "D4 no record -> mobiledata=none, zero calls" \
    || no "D4 _swept '$out', $(ncalls) call(s)"
  clean D4
  mkdev; setg mobile_data1 1; setbase 0; : > "$T/deny-cmd"
  out=$(boot)
  case "$out" in
    " mobiledata=FAILED("*")") case "${out# }" in *' '*) no "D5 not one space-free token: '$out'" ;; *) ok "D5 a failed restore -> one token $out" ;; esac ;;
    *) no "D5 _swept '$out'" ;;
  esac
  [ "$(base)" = 0 ] && ok "D5 ...and the record is kept" || no "D5 base '$(base)'"
  clean D5
  mkdev; setg mobile_data1 0; setbase 0
  out=$(boot)
  [ "$out" = " mobiledata=baseline" ] && [ "$(ncmd)" = 0 ] && [ "$(base)" = none ] \
    && ok "D6 the phone already reads the record: mobiledata=baseline, dropped, zero cmd calls" \
    || no "D6 _swept '$out', $(ncmd) cmd, base $(base)"
  clean D6
  mkdev; nosub; setg mobile_data 1; setbase 0
  out=$(boot)
  [ "$out" = " mobiledata=FAILED(?)" ] && [ "$(base)" = 0 ] \
    && ok "D7 no subscription: mobiledata=FAILED(?), the record kept" || no "D7 _swept '$out', base $(base)"
  clean D7

  # --- the ops' arguments and the log ------------------------------------------------------------------------
  for o in mdapply mdrelease; do
    for v in abc 5 '' 9x; do
      mkdev; setg mobile_data1 1; setbase 0
      out=$(op "$o" "$v" signin)
      [ "$out" = ERR-UID ] && [ "$(ncalls)" = 0 ] && [ "$(base)" = 0 ] && ok "E1 $o refuses uid '$v'" || no "E1 $o '$v' -> '$out', $(ncalls) call(s)"
      clean "E1 $o $v"
    done
  done
  mkdev; prefs 12 'mobiledata=1\n'; setg mobile_data1 0
  op mdapply 12 'zq Alice Smith' >/dev/null
  if grep -q '(other)' "$T/log" && ! grep -qE 'zq|Alice|Smith' "$T/log"; then ok "E2 the reason slot cannot put a name into the log"
  else no "E2 log: $(cat "$T/log" 2>/dev/null)"; fi
  op mdrelease 12 'Bob' >/dev/null
  ! grep -q 'Bob' "$T/log" && ok "E2 ...nor can a release's" || no "E2 release log: $(cat "$T/log" 2>/dev/null)"
  if ! grep -q 'NOISE-' "$T/log"; then ok "E3 no cmd or settings output reaches the log"; else no "E3 log: $(cat "$T/log")"; fi
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
mut "M1 a claim always recaptures the baseline"          's/if \[ -z "\$_b" \]; then(\n    # No record)/if true; then$1/'
mut "M2 the baseline is written after md_write, on success only" 's/if ! md_base_put "\$_cur"; then/if false; then/; s/(  if md_write "\$_t"; then\n)/$1    [ -z "\$_b" ] \&\& md_base_put "\$_cur"\n/'
mut "M3 no choice is treated as Off"                     's/  else _t="\$_cur"; fi/  else _t=0; fi/'
mut "M4 2 counts as On"                                  's/(0\|1\) echo "\$_v" ;;) esac/$1 2) echo 1 ;; esac/'
mut "M5 the per-subscription key is ignored"             's/"mobile_data\$_s"/mobile_data/'
mut "M6 a release ignores another owner"                 's/(md_release\(\) \{.*?)if \[ -n "\$_o" \] && \[ "\$_o" != "\$_u" \]; then/$1if false; then/s'
mut "M7 a successful release keeps the baseline file"    's/(  if md_write "\$_b"; then\n    rm -f )"\$MD_BASE" "\$MD_OWNER"/$1"\$MD_OWNER"/'
mut "M8 a failed release removes the baseline file"      's/(    # Both records stay[^\n]*\n)/$1    rm -f "\$MD_BASE"\n/'
mut "M9 the boot sweep ignores a live owner"             's/  if \[ -n "\$_o" \]; then MD_BOOT="KEPT:user\$_o"; return 0; fi\n//'
mut "M10 the boot category runs after the result line"   's/(  # --- fix 12: mobiledata \(NWP-20261026-05\) ---\n.*?  _swept="\$_swept mobiledata=\$MD_BOOT"\n)(.*?  echo "\[roamd\] bootsweep result:[^\n]*\n)/$2$1/s'
mut "M11 the cleanstorage line is removed"               's/^  md_release "\$uid" reap   # NWP-20261026-05[^\n]*\n//m'
mut "M12 a claim writes when nothing changes"            's/  if \[ "\$_cur" = "\$_t" \]; then\n/  if false; then\n/'
mut "M13 md_write trusts the exit status alone"          's/\[ "\$_rc" = 0 \] && \[ "\$MD_SEEN" = "\$_v" \]/[ "\$_rc" = 0 ]/'
mut "M14 a release always writes (no already-at-baseline check)" 's/  if \[ "\$_cur" = "\$_b" \]; then\n(    # Already there)/  if false; then\n$1/'
mut "M15 no choice with an unreadable current value replies APPLIED" 's/(and no choice -- nothing written \$\(date\)" >> "\$LOG"\n)/$1      MD_VERDICT="OK APPLIED mobile_data=?"; return 0\n/'
mut "M16 md_read falls back to the legacy key with no subscription" 's/^  if \[ -z "\$_s" \]; then echo .\?.; return 0; fi\n//m'
mut "M17 md_claim writes when the value is ? and a record exists" 's/(  _cur=\$\(md_read\)\n(?:  #[^\n]*\n)*)  if \[ "\$_cur" = .\?. \]; then/$1  if [ "\$_cur" = "?" ] \&\& [ -z "\$_b" ]; then/'
[ "$fails" = 0 ] && echo "== all $nmut mutations convicted (shells: ${LABELS[*]})" || { echo "== $fails mutation outcome(s) not convicted"; exit 1; }
