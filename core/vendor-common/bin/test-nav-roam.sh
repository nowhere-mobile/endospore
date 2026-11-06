#!/usr/bin/env bash
# test-nav-roam.sh [<nowhere_roamd.sh>] [--mutate] -- the navigation-mode roam (NWP-20260914-04).
#
# WHY THIS IS COMMITTED. The whole feature is two small shell functions whose failure modes are all SILENT:
# a captured mode that maps to no overlay must degrade to "edition default" (not a broken enable-exclusive),
# an unreadable capture must CLEAR the file (not leave a stale one that forces a mode next login), and the
# apply must log on failure as loudly as on success -- because on an enforcing user build the one thing
# that can break it (a missing overlay_service find) produces no error at all, only a phone that quietly
# keeps the edition default. Every one of those is a branch a healthy device never exercises.
#
# The functions are extracted from nowhere_roamd.sh BY ANCHOR, never copied, so a stale copy here cannot
# keep passing after the real code moves.
#
#   bash test-nav-roam.sh            # the truth table + the degrade paths
#   bash test-nav-roam.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# NWP-20261108-17: the capture waits for this session's apply (the .navapplied.<uid> marker nav_apply writes), and once
# marked an EMPTY read keeps the record -- the mirror is written for the current user only, so it stays empty until
# after the switch-in. A read of `null` keeps it too: that is what `settings get` prints for a row never set. Without that a periodic seal inside a long sign-in deleted the profile's record.
#
# NWP-20261121-12: the T-N1/T-N2 cases plant the apply's marker path as a DIRECTORY, so its `( : > marker )` fails (as
# root too), and check that the apply still returns, keeps its rc, logs its outcome and makes the control's settings
# writes. Bash runs as --posix there: a bare `: >` that fails ends only a POSIX shell. No capture runs after a plant: its
# `[ ! -e marker ]` guard reads a directory as present. A real failed create leaves no file, as the no-marker cases show.
#
# Pure logic -- no device, no overlay manager, no store. `cmd` and `settings` are stubbed.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
# The cases run under every shell found (the device's /system/bin/sh is mksh); ROAM_SHELLS overrides.
SHELLS=""
if [ -n "${ROAM_SHELLS:-}" ]; then SHELLS="$ROAM_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
SHX=bash

# --- extraction -------------------------------------------------------------------------------------------
extract() {  # $1 = script -> stdout: the three nav functions
  local f="$1" out
  out=$(sed -n '/^nav_seal_capture() {$/,/^}$/p; /^nav_pkg_for() {$/,/^}$/p; /^nav_apply() {$/,/^}$/p' "$f")
  case "$out" in
    *nav_seal_capture*nav_pkg_for*nav_apply*) printf '%s\n' "$out" ;;
    *) return 1 ;;
  esac
}

# suite <script> [quiet] -> 0 if every case behaved. Own counters, never touches globals.
suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 fns tmp root files logf
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  fns=$(extract "$f") || { no "EXTRACTION FAILED -- the nav functions moved in $f"; return 1; }
  tmp=$(mktemp -d -p "$W"); root="$tmp/overlay"; files="$tmp/user/com.nowhere.chooser/files"; logf="$tmp/roam.log"
  mkdir -p "$tmp/state" "$root/NavigationBarMode3Button" "$root/NavigationBarModeGestural" "$files"
  : > "$root/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk"
  : > "$root/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"

  # Stubs: `settings get` answers from $NAVMODE; `cmd` records its argv and exits per $CMDRC.
  local stubs; stubs=$(cat <<'EOS'
settings(){ printf '%s\n' "${NAVMODE:-}"; }
cmd(){ printf '%s\n' "$*" > "$CMDLOG"; return "${CMDRC:-0}"; }
EOS
)
  run() {  # run <fn and args...> with the fixtures in place
    LOG="$logf" STATE="$tmp/state" CMDLOG="$tmp/cmd" NAV_OVERLAY_ROOT="$root" NAVMODE="${NAVMODE:-}" CMDRC="${CMDRC:-0}" \
      "$SHX" -c "$stubs
$fns
$*"
  }

  # ---- nav_pkg_for: the truth table -----------------------------------------------------------------
  [ "$(run nav_pkg_for 0)" = "com.android.internal.systemui.navbar.threebutton" ] && ok "0 -> threebutton" || no "0 -> '$(run nav_pkg_for 0)'"
  [ "$(run nav_pkg_for 2)" = "com.android.internal.systemui.navbar.gestural" ]    && ok "2 -> gestural"    || no "2 -> '$(run nav_pkg_for 2)'"
  [ -z "$(run nav_pkg_for 1)" ] && ok "1 (2-button) -> nothing; no product ships it" || no "1 mapped to '$(run nav_pkg_for 1)'"
  [ -z "$(run nav_pkg_for x)" ] && ok "garbage -> nothing" || no "garbage mapped"
  rm "$root/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"
  [ -z "$(run nav_pkg_for 2)" ] && ok "2 with the APK absent -> nothing (degrades, never a broken enable)" || no "mapped to an absent APK"
  : > "$root/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"

  # ---- nav_seal_capture: waits for this session's apply; writes a good read, KEEPS an empty one, CLEARS junk --
  local mk="$tmp/state/.navapplied.10"
  # V1: no marker -> a VALID live value that differs from the record must not touch it.
  rm -f "$mk"; : > "$logf"; printf '0\n' > "$files/nowhere-nav"; cp "$files/nowhere-nav" "$tmp/rec"
  NAVMODE=2 run "nav_seal_capture '$tmp/user' 10" >/dev/null
  cmp -s "$tmp/rec" "$files/nowhere-nav" && ok "no marker: the record is kept byte for byte against a valid live value" || no "capture ran before this session's apply"
  grep -q 'not applied yet this session for user 10' "$logf" && ok "no marker: the keep is LOGGED" || no "the not-applied keep was silent"
  # V2: marked.
  : > "$mk"
  NAVMODE=2 run "nav_seal_capture '$tmp/user' 10" >/dev/null
  [ "$(cat "$files/nowhere-nav" 2>/dev/null)" = "2" ] && ok "marked: capture writes the mode" || no "marked: capture did not write 2"
  NAVMODE=0 run "nav_seal_capture '$tmp/user' 10" >/dev/null
  [ "$(cat "$files/nowhere-nav" 2>/dev/null)" = "0" ] && ok "marked: capture writes 0" || no "marked: capture did not write 0"
  : > "$logf"; cp "$files/nowhere-nav" "$tmp/rec"
  NAVMODE="" run "nav_seal_capture '$tmp/user' 10" >/dev/null
  cmp -s "$tmp/rec" "$files/nowhere-nav" && ok "marked: an empty read KEEPS the record (the mirror is empty until after the switch-in)" || no "an empty read removed or changed the record"
  grep -q 'no mode resolved yet for user 10' "$logf" && ok "marked: the empty keep is LOGGED" || no "the empty keep was silent"
  : > "$logf"
  NAVMODE=null run "nav_seal_capture '$tmp/user' 10" >/dev/null
  cmp -s "$tmp/rec" "$files/nowhere-nav" && ok "marked: a null read (unset row) KEEPS the record" || no "a null read removed or changed the record"
  grep -q 'no mode resolved yet for user 10' "$logf" && ok "marked: the null keep is LOGGED" || no "the null keep was silent"
  NAVMODE=junk run "nav_seal_capture '$tmp/user' 10" >/dev/null
  [ ! -e "$files/nowhere-nav" ] && ok "marked: a malformed read leaves no file" || no "malformed read wrote or kept a file"
  grep -q 'capture cleared' "$logf" && ok "the clear is LOGGED" || no "the clear was silent"
  rm -f "$mk"

  # ---- nav_apply: applies, degrades, and logs on BOTH outcomes ---------------------------------------
  # nav_apply reads ${NAV_USER_ROOT:-/data/user}/<uid>/... -- the same testability seam nav_pkg_for has for
  # the overlay root. The fixture user dir IS $tmp/user, so point the root at its parent with uid = "user".
  apply() { NAV_USER_ROOT="$tmp" run nav_apply user >/dev/null; }
  local am="$tmp/state/.navapplied.user"
  : > "$logf"; rm -f "$tmp/cmd" "$am"; rm -f "$files/nowhere-nav"
  apply
  [ ! -e "$tmp/cmd" ] && grep -q 'no capture' "$logf" && ok "no file -> nothing applied, and it SAYS so" || no "no-file path was silent or applied"
  [ -e "$am" ] && ok "no file -> the session is marked applied" || no "no file did not mark"
  : > "$logf"; rm -f "$tmp/cmd" "$am"; printf '2\n' > "$files/nowhere-nav"
  apply
  grep -q 'enable-exclusive --user user --category com.android.internal.systemui.navbar.gestural' "$tmp/cmd" 2>/dev/null \
    && ok "mode 2 -> enable-exclusive gestural for the user" || no "apply did not call cmd correctly: $(cat "$tmp/cmd" 2>/dev/null)"
  grep -q 'applied mode 2' "$logf" && ok "success is logged" || no "success was silent"
  [ -e "$am" ] && ok "applied -> the session is marked" || no "applied did not mark"
  : > "$logf"; rm -f "$tmp/cmd" "$am"; printf '1\n' > "$files/nowhere-nav"
  apply
  [ ! -e "$tmp/cmd" ] && grep -q 'no overlay on this image' "$logf" && ok "unmapped mode -> nothing applied, logged" || no "unmapped mode was applied or silent"
  [ ! -e "$am" ] && ok "no overlay -> NOT marked (the record names a mode this image cannot apply)" || no "no overlay marked the session"
  : > "$logf"; rm -f "$tmp/cmd" "$am"; printf '0\n' > "$files/nowhere-nav"
  CMDRC=1 apply
  grep -q 'enable-exclusive FAILED' "$logf" && ok "a FAILED enable is logged (the enforcing-build no-op is not invisible)" || no "cmd failure was silent"
  [ ! -e "$am" ] && ok "a failed enable -> NOT marked (the live mode is not the profile's)" || no "a failed enable marked the session"

  # ---- T-N1/T-N2: nav_apply returns and logs with a marker that cannot be written (NWP-20261121-12) -------
  # The marker path is a DIRECTORY, so `: >` on it fails as root too. Bash runs as --posix: POSIX makes a
  # redirection error on a special builtin fatal, so only a POSIX shell shows a bare `: >` ending the op.
  prun() {  # run, but bash as --posix
    local o=""; [ "$SHX" = bash ] && o=--posix
    LOG="$logf" STATE="$tmp/state" CMDLOG="$tmp/cmd" NAV_OVERLAY_ROOT="$root" NAVMODE="${NAVMODE:-}" CMDRC="${CMDRC:-0}" \
      NAV_USER_ROOT="$tmp" "$SHX" ${o:+"$o"} -c "$stubs
$fns
$*"
  }
  local tg="[$SHX]"; [ "$SHX" = bash ] && tg="[bash --posix]"
  trunc_case() {  # $1 label, $2 the outcome log text -> control run, then the same run with the marker planted
    local out rc crc ctl="$tmp/ctlcmd"
    : > "$logf"; rm -rf "$am" "$tmp/cmd" "$ctl"
    prun "nav_apply user" >/dev/null 2>&1; crc=$?
    [ "$crc" = 0 ] && ok "$tg $1: the control run returns 0" || no "$tg $1: the control run returns $crc"
    [ -f "$am" ] && ok "$tg $1: the control run writes the marker" || no "$tg $1: the control run did not reach the marker"
    [ -e "$tmp/cmd" ] && cp "$tmp/cmd" "$ctl"
    : > "$logf"; rm -rf "$am" "$tmp/cmd"; mkdir -p "$am"
    if ( : > "$am" ) 2>/dev/null; then no "$tg $1: the plant did not block the write"; fi
    # The child keeps nav_apply's own status and exits with it: an `echo` last would hide a non-zero return.
    out=$(prun 'nav_apply user; _r=$?; echo REACHED; exit "$_r"' 2>/dev/null); rc=$?
    case "$out" in *REACHED*) ok "$tg $1: nav_apply returns to its caller" ;; *) no "$tg $1: the shell ended inside nav_apply (no REACHED)" ;; esac
    [ "$rc" = "$crc" ] && ok "$tg $1: nav_apply returns $rc, as in the control run" || no "$tg $1: nav_apply returns $rc, the control run $crc"
    grep -qF "$2" "$logf" && ok "$tg $1: the outcome is logged ('$2')" || no "$tg $1: no '$2' in the log"
    if [ -e "$ctl" ]; then cmp -s "$ctl" "$tmp/cmd"; else [ ! -e "$tmp/cmd" ]; fi \
      && ok "$tg $1: the settings writes equal the control's" || no "$tg $1: the settings writes differ from the control's"
    [ -d "$am" ] && ok "$tg $1: the plant is still a directory" || no "$tg $1: the plant is gone"
    rm -rf "$am" "$ctl"
  }
  # The seal capture's guard is `[ ! -e marker ]`, and a directory reads as present: no capture runs after a plant.
  rm -f "$files/nowhere-nav"
  trunc_case "T-N1 no capture, marker unwritable" "nav: no capture for user user"
  printf '2\n' > "$files/nowhere-nav"
  : > "$logf"; rm -rf "$am" "$tmp/cmd"; prun "nav_apply user" >/dev/null 2>&1
  grep -qF 'enable-exclusive --user user --category com.android.internal.systemui.navbar.gestural' "$tmp/cmd" 2>/dev/null \
    && ok "$tg T-N2: the control takes the enable-exclusive branch" || no "$tg T-N2: the control did not call enable-exclusive"
  CMDRC=0 trunc_case "T-N2 applied, marker unwritable" "nav: applied mode 2"
  rm -f "$files/nowhere-nav" "$tmp/cmd"

  # ---- V5: the `in` arm clears both markers, after the vpn/sync clear and before the commit arm ---------
  local arm n v c
  arm=$(sed -n '/^  in)$/,/^  out)$/p' "$f")
  n=$(printf '%s\n' "$arm" | grep -nF '    rm -f "$STATE/.navapplied.$uid" "$STATE/.aodapplied.$uid" 2>/dev/null' | head -1 | cut -d: -f1)
  v=$(printf '%s\n' "$arm" | grep -nF '      "$STATE/.syncretry.$uid" "$STATE/.vpndeferred.$uid" "$STATE/.vpnretry.$uid" 2>/dev/null' | head -1 | cut -d: -f1)
  c=$(printf '%s\n' "$arm" | grep -nF '      rm -rf "$PARK" 2>> "$LOG"' | head -1 | cut -d: -f1)
  if [ -n "$n" ] && [ -n "$v" ] && [ -n "$c" ] && [ "$v" -lt "$n" ] && [ "$n" -lt "$c" ]; then
    ok "the in arm clears both markers, after the vpn/sync clear and before the commit arm"
  else
    no "the in arm's marker clear is missing or misplaced (v='$v' n='$n' c='$c')"
  fi

  rm -rf "$tmp"
  [ -n "$quiet" ] || printf '  (%d ok, %d failed)\n' "$p" "$x"
  [ "$x" = 0 ]
}

echo "== as committed =="
RC=0
for SHX in $SHELLS; do
  echo "-- $SHX"; suite "$SUT" || RC=1
done
[ "$MUTATE" = no ] && { echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; }
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo; echo "== mutations (each MUST be convicted) =="
MRC=0
apply_mut() {  # $1 dest, $2 sed expr -> 0 iff a real, different, non-empty mutant was produced
  sed "$2" "$SUT" > "$1" 2>/dev/null || return 1
  [ -s "$1" ] || return 1
  ! cmp -s "$1" "$SUT"
}
mutant() {  # $1 label, $2 sed expr
  local m; m=$(mktemp -p "$W")
  if ! apply_mut "$m" "$2"; then
    printf '  ⚠ NOT APPLIED  %s -- sed failed or changed nothing; NOT a conviction\n' "$1"; MRC=1; rm -f "$m"; return
  fi
  for SHX in $SHELLS; do
    if suite "$m" quiet; then printf '  ⚠ SURVIVED  [%s] %s\n' "$SHX" "$1"; MRC=1; else printf '  convicted   [%s] %s\n' "$SHX" "$1"; fi
  done
  rm -f "$m"
}
mutant "a bad read no longer clears the stale capture"     's|      rm -f "\$_out" "\$_out.tmp" 2>/dev/null|      : nothing|'
mutant "an unmapped mode is applied anyway"                 's|  if \[ -z "\$_pkg" \]; then|  if false; then|'
mutant "the enable failure is no longer logged"             's|enable-exclusive FAILED|applied mode|'
# ⚠ This pattern deliberately stops BEFORE the line-continuation backslash. A first version tried to match it
# with '\\\\', which sed reads as TWO literal backslashes; the source has one, so the sed never matched, the
# "mutant" was byte-identical to the original, and it SURVIVED -- while a manual re-run through a different
# quoting layer halved the backslashes and appeared to convict. A mutation that only applies from one shell is
# the /dev/null mutation from test-agent-fresh.sh again: a check that cannot fail, one level up.
mutant "the APK existence test is dropped (broken enable on a lean image)" 's|\[ -f "\${NAV_OVERLAY_ROOT:-/product/overlay}/NavigationBarModeGestural[^]]*\]|true|'
mutant "G1 the capture guard is removed" \
  '/^nav_seal_capture() {$/,/^}$/s|^  if \[ ! -e "\$STATE/.navapplied.\$_uid" \]; then$|  if false; then|'
mutant "G3 nav_apply marks on a failed enable-exclusive" \
  '/^nav_apply() {$/,/^}$/s|^    echo "\[roamd\] nav: enable-exclusive FAILED|    : > "$STATE/.navapplied.$_uid"; echo "[roamd] nav: enable-exclusive FAILED|'
mutant "G5 nav_apply marks on no-overlay" \
  '/^nav_apply() {$/,/^}$/{/has no overlay on this image/s|^    echo |    : > "$STATE/.navapplied.$_uid"; echo |}'
mutant "the in arm no longer clears the markers" \
  's|^    rm -f "\$STATE/.navapplied.\$uid" "\$STATE/.aodapplied.\$uid" 2>/dev/null.*$|    :|'
mutant "G7 an empty read clears again" \
  '/^nav_seal_capture() {$/,/^}$/s#^    ""|null)$#    "__never__")#'
mutant "G7b a null read clears again" \
  '/^nav_seal_capture() {$/,/^}$/s#^    ""|null)$#    "")#'
mutant "G9 nav_apply no longer marks after a successful enable-exclusive" \
  '/^nav_apply() {$/,/^}$/{/cmd overlay enable-exclusive/{n;s|^    ( : > "\$STATE/.navapplied.\$_uid" ) 2>>"\$LOG"; chmod 600 "\$STATE/.navapplied.\$_uid" 2>/dev/null$|    :|}}'
mutant "G10 nav_apply no longer marks on no capture" \
  '/^nav_apply() {$/,/^}$/s#^  \[ -f "\$_f" \] || { ( : > "\$STATE/.navapplied.\$_uid" ) 2>>"\$LOG"; chmod 600 "\$STATE/.navapplied.\$_uid" 2>/dev/null; #  [ -f "$_f" ] || { #'
# T1/T2 (NWP-20261121-12): one marker site each goes back to the bare `: >`, which ends a POSIX shell on an unwritable marker.
mutant "T1 nav_apply's no-capture marker is a bare : > again" \
  '/^nav_apply() {$/,/^}$/s#^  \[ -f "\$_f" \] || { ( : > "\$STATE/.navapplied.\$_uid" ) 2>>"\$LOG";#  [ -f "$_f" ] || { : > "$STATE/.navapplied.$_uid" 2>>"$LOG";#'
mutant "T2 nav_apply's applied marker is a bare : > again" \
  '/^nav_apply() {$/,/^}$/s#^    ( : > "\$STATE/.navapplied.\$_uid" ) 2>>"\$LOG"; chmod#    : > "$STATE/.navapplied.$_uid" 2>>"$LOG"; chmod#'
# R1/R2 (NWP-20261121-12, RF-001): each branch keeps its log line but returns 7 when the marker is a directory. Only the
# rc assertion sees this, so the case must compare nav_apply's own status, not the status of the `echo` after it.
mutant "R1 nav_apply's no-capture branch returns 7 on an unwritable marker" \
  '/^nav_apply() {$/,/^}$/{/nav: no capture for user/s#; return 0; }$#; [ -d "$STATE/.navapplied.$_uid" ] \&\& return 7; return 0; }#}'
mutant "R2 nav_apply returns 7 on an unwritable marker after enable-exclusive" \
  '/^nav_apply() {$/,/^}$/s#^  return 0$#  [ -d "$STATE/.navapplied.$_uid" ] \&\& return 7; return 0#'
echo; [ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
