#!/usr/bin/env bash
# test-home-pin.sh [<nowhere_roamd.sh>] [--mutate] -- the grant arm's HOME pin is logged as it happened (NWP-20261107-15).
#
# WHY THIS IS COMMITTED. A roamed session's HOME is pinned twice (#46): roamd's `grant` arm runs `cmd package
# set-home-activity` first, then the chooser's ensureRoamedHomeRole (#131) verifies and re-asserts the HOME role holder,
# logging to logcat only. roam.log -- the log an issue report carries -- is therefore the only persisted record of the
# first pin, and the arm used to write "pinned launcher3" whatever the exit status was. cmd's stdio goes to /dev/null
# (the su:s0 fd denial), so the status is the only signal, and nav_apply's rule applies: a line that only appears on
# success is indistinguishable from the feature not existing. Cases, under every shell found (bash sh dash mksh):
#   - rc 0 -> one `pinned launcher3 as user 10 home` line, no FAILED line, cmd's argv exactly as before;
#   - rc 1 -> one `home pin FAILED for user 10 (rc=1)` line and no `pinned` line;
#   - home_pin returns 0 on both (the grant goes on);
#   - the grant arm calls `home_pin "$uid"` before `nav_apply "$uid"` and holds no bare set-home-activity line.
# home_pin and the arm are extracted from nowhere_roamd.sh BY ANCHOR, never copied.
#
#   bash test-home-pin.sh            # the cases
#   bash test-home-pin.sh --mutate   # ... plus mutants that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

PINARGS='package set-home-activity --user 10 com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher'

# extract <script> <fn-out> <arm-out> -> 0 when both anchors were found
extract() {
  sed -n '/^home_pin() {$/,/^}$/p' "$1" > "$2"
  sed -n '/^  grant)$/,/^    ;;$/p' "$1" > "$3"
  [ -s "$2" ] && [ -s "$3" ]
}

# suite <script> <shell> [quiet] -> 0 when every case behaved
suite() {
  local f="$1" sh_="$2" quiet="${3:-}" p=0 x=0 fn arm logf cmdlog n pinned failed rc line_home line_nav
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh_" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh_" "$1"; }
  fn=$(mktemp -p "$W") || return 2; arm=$(mktemp -p "$W") || return 2
  logf=$(mktemp -p "$W") || return 2; cmdlog=$(mktemp -p "$W") || return 2
  extract "$f" "$fn" "$arm" || { no "EXTRACTION FAILED -- home_pin or the grant arm is missing in $f"; rm -f "$fn" "$arm" "$logf" "$cmdlog"; return 1; }

  # runpin <cmd rc> -> prints home_pin's own status; the log and cmd's argv land in $logf / $cmdlog
  runpin() {
    : > "$logf"; : > "$cmdlog"
    LOG="$logf" CMDLOG="$cmdlog" CMDRC="$1" "$sh_" -c "cmd() { echo \"\$*\" >> \"\$CMDLOG\"; return \"\$CMDRC\"; }
. '$fn'
home_pin 10
echo \$?"
  }

  rc=$(runpin 0)
  pinned=$(grep -c 'pinned launcher3 as user 10 home' "$logf"); failed=$(grep -c 'home pin FAILED' "$logf")
  [ "$pinned" = 1 ] && [ "$failed" = 0 ] && ok "rc 0 -> one pinned line, no FAILED line" || no "rc 0: pinned=$pinned failed=$failed"
  [ "$(cat "$cmdlog")" = "$PINARGS" ] && ok "cmd's args are exactly the old pin's" || no "cmd args: $(cat "$cmdlog")"
  [ "$rc" = 0 ] && ok "returns 0 after a pin that landed" || no "rc 0 returned '$rc'"

  rc=$(runpin 1)
  pinned=$(grep -c 'pinned launcher3' "$logf"); failed=$(grep -c 'home pin FAILED for user 10 (rc=1)' "$logf")
  [ "$failed" = 1 ] && [ "$pinned" = 0 ] && ok "rc 1 -> one FAILED line carrying the status, no pinned line" || no "rc 1: pinned=$pinned failed=$failed"
  [ "$rc" = 0 ] && ok "returns 0 after a pin that failed (the grant goes on)" || no "rc 1 returned '$rc'"

  n=$(grep -c 'set-home-activity' "$arm")
  line_home=$(grep -n '^    home_pin "\$uid"$' "$arm" | head -1 | cut -d: -f1)
  line_nav=$(grep -n '^    nav_apply "\$uid"' "$arm" | head -1 | cut -d: -f1)
  if [ -n "$line_home" ] && [ -n "$line_nav" ] && [ "$line_home" -lt "$line_nav" ]; then ok "the arm calls home_pin \"\$uid\" before nav_apply"
  else no "the arm's home_pin call is missing or not before nav_apply (home=${line_home:-none} nav=${line_nav:-none})"; fi
  [ "$n" = 0 ] && ok "the arm holds no bare set-home-activity line" || no "the arm still holds $n set-home-activity line(s)"

  rm -f "$fn" "$arm" "$logf" "$cmdlog"
  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh_" "$p" "$x"
  [ "$x" = 0 ]
}

probe=$(mktemp -p "$W") || exit 2; probe2=$(mktemp -p "$W") || exit 2
extract "$SUT" "$probe" "$probe2" || { echo "EXTRACTION FAILED -- home_pin or the grant arm is missing in $SUT"; exit 2; }
rm -f "$probe" "$probe2"

RC=0
for s in $SHELLS; do
  echo "== as committed [$s] =="
  suite "$SUT" "$s" || RC=1
done
[ "$MUTATE" = no ] && { echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; }
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit "$RC"; }

echo; echo "== mutants (each MUST be convicted under every shell) =="
MRC=0
mutant() {  # $1 label, $2 sed expr
  local m s_; m=$(mktemp -p "$W") || { MRC=1; return; }
  sed "$2" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then printf '  ⚠ DID NOT APPLY  %s\n' "$1"; MRC=1; rm -f "$m"; return; fi
  for s_ in $SHELLS; do
    if suite "$m" "$s_" quiet; then printf '  ⚠ SURVIVED  [%s] %s\n' "$s_" "$1"; MRC=1; else printf '  convicted   [%s] %s\n' "$s_" "$1"; fi
  done
  rm -f "$m"
}
mutant "the status is ignored (the old code: pinned on both paths)" 's|^  if \[ "\$_rc" = 0 \]; then$|  if true; then|'
mutant "the FAILED line on a pin that landed"                        's|^  if \[ "\$_rc" = 0 \]; then$|  if false; then|'
mutant "the pin goes to user 0"                                      '/^home_pin() {$/,/^}$/ s|--user "\$_uid"|--user 0|'
mutant "the arm's home_pin call is removed"                          '/^    home_pin "\$uid"$/d'
echo; [ "$MRC" = 0 ] && echo "all mutants convicted" || echo "SOME MUTANTS NOT CONVICTED"
exit $MRC
