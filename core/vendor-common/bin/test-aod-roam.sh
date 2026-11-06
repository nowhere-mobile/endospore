#!/usr/bin/env bash
# test-aod-roam.sh [<nowhere_roamd.sh>] [--mutate] -- the always-on-display roam (NWP-20260922-02).
#
# WHY THIS IS COMMITTED. Like the navigation-mode roam it is cloned from (NWP-20260914-04), the whole
# feature is two small shell functions whose failure modes are ALL SILENT. An unreadable capture must
# CLEAR the file, not leave a stale one that forces AOD on at the next login on a different handset. A
# malformed capture must degrade to the device default, not be shoved into `settings put`. And the apply
# must log on failure as loudly as on success -- because the thing most likely to break it (the su:s0 fd
# denial on `settings`, or SettingsProvider refusing a cross-user write) produces no error anywhere, only
# a phone that quietly keeps the wrong setting. Every one of those is a branch a healthy device never
# exercises, and none of them can be seen by reading a green log.
#
# The functions are extracted from nowhere_roamd.sh BY ANCHOR, never copied, so a stale copy here cannot
# keep passing after the real code moves.
#
#   bash test-aod-roam.sh            # the truth table + the degrade paths
#   bash test-aod-roam.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# NWP-20261108-17: the capture waits for this session's apply (the .aodapplied.<uid> marker aod_apply writes), so a
# periodic seal inside a long sign-in cannot read the new user's unset row and delete the profile's record.
#
# NWP-20261121-12: the T-A1..T-A3 cases plant the apply's marker path as a DIRECTORY, so its `( : > marker )` fails (as
# root too), and check that the apply still returns, keeps its rc, logs its outcome and makes the control's settings
# writes. Bash runs as --posix there: a bare `: >` that fails ends only a POSIX shell. No capture runs after a plant: its
# `[ ! -e marker ]` guard reads a directory as present. A real failed create leaves no file, as the no-marker cases show.
#
# Pure logic -- no device, no SettingsProvider, no store. `settings` is stubbed.
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
extract() {  # $1 = script -> stdout: the two aod functions
  local f="$1" out
  out=$(sed -n '/^aod_seal_capture() {$/,/^}$/p; /^aod_apply() {$/,/^}$/p' "$f")
  case "$out" in
    *aod_seal_capture*aod_apply*) printf '%s\n' "$out" ;;
    *) return 1 ;;
  esac
}

# suite <script> [quiet] -> 0 if every case behaved. Own counters, never touches globals.
suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 fns tmp files logf
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  fns=$(extract "$f") || { no "EXTRACTION FAILED -- the aod functions moved in $f"; return 1; }
  tmp=$(mktemp -d -p "$W"); files="$tmp/user/com.nowhere.chooser/files"; logf="$tmp/roam.log"
  mkdir -p "$files" "$tmp/state"

  # Stubs: `settings get` answers from $AODVAL; `settings put` records its argv and exits per $PUTRC.
  # One stub serves both verbs, because the real code calls the same binary for each and a stub that
  # could not tell them apart would hide an apply that accidentally read instead of wrote.
  local stubs; stubs=$(cat <<'EOS'
settings(){
  case "${1:-}" in
    get) printf '%s\n' "${AODVAL:-}" ;;
    put) printf '%s\n' "$*" > "$PUTLOG"; return "${PUTRC:-0}" ;;
    *)   return 0 ;;
  esac
}
EOS
)
  run() {  # run <fn and args...> with the fixtures in place
    LOG="$logf" STATE="$tmp/state" PUTLOG="$tmp/put" AOD_USER_ROOT="$tmp" AODVAL="${AODVAL:-}" PUTRC="${PUTRC:-0}" \
      "$SHX" -c "$stubs
$fns
$*"
  }

  # ---- aod_seal_capture: writes on a good read, CLEARS on a bad one --------------------------------
  local mk="$tmp/state/.aodapplied.10"
  # V1: no marker -> a VALID live value that differs from the record must not touch it.
  rm -f "$mk"; : > "$logf"; printf '0\n' > "$files/nowhere-aod"; cp "$files/nowhere-aod" "$tmp/rec"
  AODVAL=1 run "aod_seal_capture '$tmp/user' 10" >/dev/null
  cmp -s "$tmp/rec" "$files/nowhere-aod" && ok "no marker: the record is kept byte for byte against a valid live value" || no "capture ran before this session's apply"
  grep -q 'not applied yet this session for user 10' "$logf" && ok "no marker: the keep is LOGGED" || no "the not-applied keep was silent"
  # V2: marked.
  : > "$mk"
  AODVAL=1 run "aod_seal_capture '$tmp/user' 10" >/dev/null
  [ "$(cat "$files/nowhere-aod" 2>/dev/null)" = "1" ] && ok "capture writes 1 (AOD on)" || no "capture did not write 1"
  AODVAL=0 run "aod_seal_capture '$tmp/user' 10" >/dev/null
  [ "$(cat "$files/nowhere-aod" 2>/dev/null)" = "0" ] && ok "capture writes 0 (AOD off) -- an explicit off must roam too" || no "capture did not write 0"
  AODVAL="" run "aod_seal_capture '$tmp/user' 10" >/dev/null
  [ ! -e "$files/nowhere-aod" ] && ok "empty read CLEARS a stale capture (never a forced mode next login)" || no "stale capture survived an empty read"
  AODVAL=junk run "aod_seal_capture '$tmp/user' 10" >/dev/null
  [ ! -e "$files/nowhere-aod" ] && ok "malformed read leaves no file" || no "malformed read wrote a file"
  AODVAL=2 run "aod_seal_capture '$tmp/user' 10" >/dev/null
  [ ! -e "$files/nowhere-aod" ] && ok "out-of-range read (2) leaves no file" || no "out-of-range read wrote a file"
  grep -q 'capture cleared' "$logf" && ok "the clear is LOGGED" || no "the clear was silent"
  rm -f "$mk"

  # ---- aod_apply: writes through the binder, degrades, and logs on BOTH outcomes --------------------
  # aod_apply reads ${AOD_USER_ROOT:-/data/user}/<uid>/... -- the testability seam nav_apply has too. The
  # fixture user dir IS $tmp/user, so point the root at its parent with uid = "user".
  apply() { run aod_apply user >/dev/null; }
  local am="$tmp/state/.aodapplied.user"
  : > "$logf"; rm -f "$tmp/put" "$am"; rm -f "$files/nowhere-aod"
  apply
  [ ! -e "$tmp/put" ] && grep -q 'no capture' "$logf" && ok "no file -> nothing written, and it SAYS so" || no "no-file path was silent or wrote"
  [ -e "$am" ] && ok "no file -> the session is marked applied" || no "no file did not mark"

  : > "$logf"; rm -f "$tmp/put" "$am"; printf '1\n' > "$files/nowhere-aod"
  apply
  grep -q 'put --user user secure doze_always_on 1' "$tmp/put" 2>/dev/null \
    && ok "capture 1 -> settings put doze_always_on 1 for that user" || no "apply did not write correctly: $(cat "$tmp/put" 2>/dev/null)"
  grep -q 'applied doze_always_on=1' "$logf" && ok "success is logged" || no "success was silent"
  [ -e "$am" ] && ok "applied -> the session is marked" || no "applied did not mark"

  # ⚠ 0 MUST BE APPLIED, NOT SKIPPED. A profile that turned AOD OFF has to turn it off on the next
  # handset too -- treating 0 as "nothing to do" would let a device default of on override the profile.
  : > "$logf"; rm -f "$tmp/put"; printf '0\n' > "$files/nowhere-aod"
  apply
  grep -q 'put --user user secure doze_always_on 0' "$tmp/put" 2>/dev/null \
    && ok "capture 0 is APPLIED, not skipped (an explicit off must win over the device default)" || no "capture 0 was not written"

  # ⚠ THE ASSERTION NAMES THE VALUE, NOT JUST THE WORD "malformed". The first version grepped only for
  # 'malformed' and passed while the line printed an EMPTY value -- the sanitiser had already stripped the
  # very bytes the branch exists to report, so the one diagnostic for a corrupt roamed capture said nothing
  # about it, and the suite blessed that. A log line that cannot name what was wrong is not a diagnostic.
  : > "$logf"; rm -f "$tmp/put" "$am"; printf 'zz\n' > "$files/nowhere-aod"
  apply
  [ ! -e "$tmp/put" ] && grep -q "malformed (got 'zz')" "$logf" \
    && ok "malformed capture -> nothing written, and the log NAMES the offending bytes" \
    || no "malformed capture was written, silent, or logged without the value: $(grep malformed "$logf" 2>/dev/null)"

  [ -e "$am" ] && ok "malformed -> the session is marked (the live row is the device default)" || no "malformed did not mark"

  : > "$logf"; rm -f "$tmp/put" "$am"; printf '1\n' > "$files/nowhere-aod"
  PUTRC=1 apply
  grep -q 'settings put FAILED' "$logf" && ok "a FAILED put is logged (the su:s0 fd denial is not invisible)" || no "put failure was silent"
  [ ! -e "$am" ] && ok "a failed put -> NOT marked (the live row is not the profile's)" || no "a failed put marked the session"

  # ---- T-A1..T-A3: aod_apply returns and logs with a marker that cannot be written (NWP-20261121-12) ------
  # The marker path is a DIRECTORY, so `: >` on it fails as root too. Bash runs as --posix: POSIX makes a
  # redirection error on a special builtin fatal, so only a POSIX shell shows a bare `: >` ending the op.
  prun() {  # run, but bash as --posix
    local o=""; [ "$SHX" = bash ] && o=--posix
    LOG="$logf" STATE="$tmp/state" PUTLOG="$tmp/put" AOD_USER_ROOT="$tmp" AODVAL="${AODVAL:-}" PUTRC="${PUTRC:-0}" \
      "$SHX" ${o:+"$o"} -c "$stubs
$fns
$*"
  }
  local tg="[$SHX]"; [ "$SHX" = bash ] && tg="[bash --posix]"
  trunc_case() {  # $1 label, $2 the outcome log text -> control run, then the same run with the marker planted
    local out rc crc ctl="$tmp/ctlput"
    : > "$logf"; rm -rf "$am" "$tmp/put" "$ctl"
    prun "aod_apply user" >/dev/null 2>&1; crc=$?
    [ "$crc" = 0 ] && ok "$tg $1: the control run returns 0" || no "$tg $1: the control run returns $crc"
    [ -f "$am" ] && ok "$tg $1: the control run writes the marker" || no "$tg $1: the control run did not reach the marker"
    [ -e "$tmp/put" ] && cp "$tmp/put" "$ctl"
    : > "$logf"; rm -rf "$am" "$tmp/put"; mkdir -p "$am"
    if ( : > "$am" ) 2>/dev/null; then no "$tg $1: the plant did not block the write"; fi
    # The child keeps aod_apply's own status and exits with it: an `echo` last would hide a non-zero return.
    out=$(prun 'aod_apply user; _r=$?; echo REACHED; exit "$_r"' 2>/dev/null); rc=$?
    case "$out" in *REACHED*) ok "$tg $1: aod_apply returns to its caller" ;; *) no "$tg $1: the shell ended inside aod_apply (no REACHED)" ;; esac
    [ "$rc" = "$crc" ] && ok "$tg $1: aod_apply returns $rc, as in the control run" || no "$tg $1: aod_apply returns $rc, the control run $crc"
    grep -qF "$2" "$logf" && ok "$tg $1: the outcome is logged ($2)" || no "$tg $1: no '$2' in the log"
    if [ -e "$ctl" ]; then cmp -s "$ctl" "$tmp/put"; else [ ! -e "$tmp/put" ]; fi \
      && ok "$tg $1: the settings writes equal the control's" || no "$tg $1: the settings writes differ from the control's"
    [ -d "$am" ] && ok "$tg $1: the plant is still a directory" || no "$tg $1: the plant is gone"
    rm -rf "$am" "$ctl"
  }
  # The seal capture's guard is `[ ! -e marker ]`, and a directory reads as present: no capture runs after a plant.
  rm -f "$files/nowhere-aod"
  trunc_case "T-A1 no capture, marker unwritable" "aod: no capture for user user"
  printf 'zz\n' > "$files/nowhere-aod"
  trunc_case "T-A2 malformed, marker unwritable" "aod: capture for user user is malformed (got 'zz')"
  printf '1\n' > "$files/nowhere-aod"
  : > "$logf"; rm -rf "$am" "$tmp/put"; prun "aod_apply user" >/dev/null 2>&1
  grep -qF 'put --user user secure doze_always_on 1' "$tmp/put" 2>/dev/null \
    && ok "$tg T-A3: the control takes the settings put branch" || no "$tg T-A3: the control did not put doze_always_on 1"
  PUTRC=0 trunc_case "T-A3 applied, marker unwritable" "aod: applied doze_always_on=1 for user user"
  rm -f "$files/nowhere-aod" "$tmp/put"

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
# ⚠⚠ A MUTANT THAT DID NOT APPLY IS NOT EVIDENCE. The first version of this harness had a mutation whose
# sed used `|` as both the delimiter AND a literal; sed errored, the mutant file was EMPTY, extraction
# failed, and the suite duly "failed" -- which printed `convicted` for a mutation that never existed. That
# is the /dev/null mutation from test-agent-fresh.sh one level up: a check that cannot fail. So every
# mutant is now verified NON-EMPTY and actually DIFFERENT from the source before its result is believed.
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
control() {  # $1 label, $2 sed expr -- a change that must NOT be convicted
  local m; m=$(mktemp -p "$W")
  if ! apply_mut "$m" "$2"; then
    printf '  ⚠ NOT APPLIED  CONTROL: %s -- sed failed or changed nothing\n' "$1"; MRC=1; rm -f "$m"; return
  fi
  for SHX in $SHELLS; do
    if suite "$m" quiet; then printf '  ok (survived) [%s] CONTROL: %s\n' "$SHX" "$1"; else printf '  ⚠ CONVICTED  [%s] CONTROL: %s\n' "$SHX" "$1"; MRC=1; fi
  done
  rm -f "$m"
}
mutant "a bad read no longer clears the stale capture" \
  's|      rm -f "\$_out" "\$_out.tmp" 2>/dev/null|      : nothing|'
mutant "the malformed-capture guard is dropped (junk reaches settings put)" \
  's|    \*) echo "\[roamd\] aod: capture for user \$_uid is malformed|    zzz) echo "[roamd] aod: capture for user $_uid is malformed|'
mutant "the put failure is no longer logged" \
  's|settings put FAILED|applied doze_always_on=|'
# ⚠ `#` as the delimiter, deliberately: `|` is literal in this pattern, so using it as the delimiter too
# is what produced the phantom conviction above.
mutant "capture accepts any value (out-of-range is written)" \
  's#^    0|1)#    0|1|2|junk)#'
mutant "G2 the capture guard is removed" \
  '/^aod_seal_capture() {$/,/^}$/s|^  if \[ ! -e "\$STATE/.aodapplied.\$_uid" \]; then$|  if false; then|'
mutant "G4 aod_apply marks on a failed put" \
  '/^aod_apply() {$/,/^}$/s|^    echo "\[roamd\] aod: settings put FAILED|    : > "$STATE/.aodapplied.$_uid"; echo "[roamd] aod: settings put FAILED|'
mutant "G8 aod_apply no longer marks after a successful put" \
  '/^aod_apply() {$/,/^}$/{/settings put --user/{n;s|^    ( : > "\$STATE/.aodapplied.\$_uid" ) 2>>"\$LOG"; chmod 600 "\$STATE/.aodapplied.\$_uid" 2>/dev/null$|    :|}}'
mutant "the in arm no longer clears the markers" \
  's|^    rm -f "\$STATE/.navapplied.\$uid" "\$STATE/.aodapplied.\$uid" 2>/dev/null.*$|    :|'
# T1..T3 (NWP-20261121-12): one marker site each goes back to the bare `: >`, which ends a POSIX shell on an unwritable marker.
mutant "T1 aod_apply's no-capture marker is a bare : > again" \
  '/^aod_apply() {$/,/^}$/s#^  \[ -f "\$_f" \] || { ( : > "\$STATE/.aodapplied.\$_uid" ) 2>>"\$LOG";#  [ -f "$_f" ] || { : > "$STATE/.aodapplied.$_uid" 2>>"$LOG";#'
mutant "T2 aod_apply's malformed marker is a bare : > again" \
  '/^aod_apply() {$/,/^}$/s#^       ( : > "\$STATE/.aodapplied.\$_uid" ) 2>>"\$LOG"; chmod#       : > "$STATE/.aodapplied.$_uid" 2>>"$LOG"; chmod#'
mutant "T3 aod_apply's applied marker is a bare : > again" \
  '/^aod_apply() {$/,/^}$/s#^    ( : > "\$STATE/.aodapplied.\$_uid" ) 2>>"\$LOG"; chmod#    : > "$STATE/.aodapplied.$_uid" 2>>"$LOG"; chmod#'
# R1..R3 (NWP-20261121-12, RF-001): each branch keeps its log line but returns 7 when the marker is a directory. Only the
# rc assertion sees this, so the case must compare aod_apply's own status, not the status of the `echo` after it.
mutant "R1 aod_apply's no-capture branch returns 7 on an unwritable marker" \
  '/^aod_apply() {$/,/^}$/{/aod: no capture for user/s#; return 0; }$#; [ -d "$STATE/.aodapplied.$_uid" ] \&\& return 7; return 0; }#}'
mutant "R2 aod_apply's malformed branch returns 7 on an unwritable marker" \
  '/^aod_apply() {$/,/^}$/s#^\(       ( : > "\$STATE/.aodapplied.\$_uid" ) 2>>"\$LOG"; chmod 600 "\$STATE/.aodapplied.\$_uid" 2>/dev/null; \)return 0 ;;$#\1[ -d "$STATE/.aodapplied.$_uid" ] \&\& return 7; return 0 ;;#'
mutant "R3 aod_apply returns 7 on an unwritable marker after the put" \
  '/^aod_apply() {$/,/^}$/s#^  return 0$#  [ -d "$STATE/.aodapplied.$_uid" ] \&\& return 7; return 0#'
# ⚠ CONTROL: the suite pins BEHAVIOUR, not incidentals. It must not fail on a byte-count widening that
# cannot change the parse for the only two legal values -- otherwise it is a snapshot test wearing a
# behavioural test's clothes, and every harmless edit becomes a red suite someone learns to ignore.
control "head -c 8 widened to head -c 16 (same parse for 0/1)" \
  's|head -c 8 "\$_f"|head -c 16 "$_f"|'
echo; [ "$MRC" = 0 ] && echo "all mutations convicted, control survived" || echo "⚠ a mutation survived or the control was convicted"
exit $MRC
