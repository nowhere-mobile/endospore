#!/usr/bin/env bash
# test-lasttz-roam.sh [<nowhere_roamd.sh>] [--mutate] -- the profile's last time zone (Q148, NWP-20261102-06).
#
# Q148 (docs/product-decisions.md, 2026-10-20) drops the ipinfo.io tier: the zone is saved at sign-out and applied
# at the next sign-in as a SEED, with auto-detection on. This is the capture-and-surface half. Its failure modes are
# all silent: a bad read that keeps the old file pins a stale zone on the next handset; a loose pattern lets a
# path-shaped string reach the gate; a lasttz= written into nowhere-prefs breaks the 2026-10-10 account-sync rule
# (setPref rewrites that file whole, #159); a capture that is no longer called at `out` ships nothing.
#
# The three functions are extracted from nowhere_roamd.sh BY ANCHOR, each exactly once, never copied. getprop is
# stubbed. Every case runs under every shell found (bash, sh, dash, mksh).
#
#   bash test-lasttz-roam.sh            # the truth table + the source checks
#   bash test-lasttz-roam.sh --mutate   # ... plus mutants that must each CONVICT, under every shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"

extract() {  # $1 = script, $2 = dest lib -> 0 iff each function is found exactly once
  local f="$1" dest="$2" fn n
  : > "$dest"
  for fn in tz_zone_ok tz_seal_capture tz_surface; do
    n=$(grep -c "^${fn}() {\$" "$f")
    if [ "$n" != 1 ]; then echo "EXTRACTION FAILED: ${fn}() found $n times" >&2; return 1; fi
    sed -n "/^${fn}() {\$/,/^}\$/p" "$f" >> "$dest"
  done
  cat >> "$dest" <<'STUB'
getprop() { [ "$1" = persist.sys.timezone ] && printf '%s\n' "$TZVAL"; }
STUB
}

# suite <roamd> <shell> [quiet] -> 0 iff every check holds under that shell
suite() {
  local sut="$1" sh="$2" quiet="${3:-}" p=0 x=0
  local lib="$W/lib.$$.sh" logf="$W/log.$$" ud="$W/ud.$$" files pre src
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok   [%s] %s\n' "$sh" "$1"; }
  no() { x=$((x+1)); printf '  FAIL [%s] %s\n' "$sh" "$1"; }
  rm -rf "$ud"; files="$ud/com.nowhere.chooser/files"; mkdir -p "$files"
  : > "$logf"
  if ! extract "$sut" "$lib"; then no "extraction"; return 1; fi

  cap() { TZVAL="$1" LOG="$logf" "$sh" -c '. "$1"; tz_seal_capture "$2"' x "$lib" "$ud"; }
  surf() { LOG="$logf" "$sh" -c '. "$1"; tz_surface "$2" "$3"' x "$lib" "$ud" "$files/prefs.out"; }

  # capture: written
  local z
  for z in Europe/Berlin America/Argentina/Buenos_Aires Etc/GMT+5 Etc/GMT-5 UTC \
           "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
    printf 'Asia/Tokyo\n' > "$files/nowhere-lasttz"
    cap "$z"
    if [ "$(cat "$files/nowhere-lasttz" 2>/dev/null)" = "$z" ]; then ok "captured ${#z}-char zone"; else no "valid zone (${#z} chars) not written"; fi
  done
  # capture: a bad read REMOVES a stale file
  local bad
  for bad in "" "../x" "Europe/../x" "Europe/Ber lin" "Europe//x" "Europe/" "/Europe/Berlin" \
             "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
    printf 'Asia/Tokyo\n' > "$files/nowhere-lasttz"
    cap "$bad"
    if [ ! -e "$files/nowhere-lasttz" ]; then ok "bad read (${#bad} chars) removed the file"; else no "bad read (${#bad} chars) kept: $(cat "$files/nowhere-lasttz")"; fi
  done
  # no chooser dir: nothing created
  local nod="$W/nod.$$"; rm -rf "$nod"; mkdir -p "$nod"
  TZVAL=Europe/Berlin LOG="$logf" "$sh" -c '. "$1"; tz_seal_capture "$2"' x "$lib" "$nod"
  if [ -z "$(ls -A "$nod")" ]; then ok "no chooser dir -> nothing created"; else no "created files without a chooser dir"; fi
  rm -rf "$nod"
  # the log never names a zone (coarse location)
cap Europe/Berlin; cap "Europe/Ber lin"
  src=$(grep -c 'Berlin\|Ber lin' "$logf")
  if [ "$src" = 0 ]; then ok "log names no zone"; else no "log names a zone"; fi

  # surface
  printf 'tz=\nlocale=en-US\n' > "$files/prefs.out"; printf 'netloc=1\n' > "$files/nowhere-prefs"
  cp "$files/nowhere-prefs" "$W/prefs.ref.$$"
  printf 'Europe/Berlin\n' > "$files/nowhere-lasttz"
  surf
  if [ "$(cat "$files/prefs.out")" = "$(printf 'tz=\nlocale=en-US\nlasttz=Europe/Berlin')" ]; then ok "valid file -> lasttz= appended, old lines kept"; else no "surface: $(cat "$files/prefs.out")"; fi
  printf 'locale=en-US' > "$files/prefs.out"; surf
  if [ "$(cat "$files/prefs.out")" = "$(printf 'locale=en-US\nlasttz=Europe/Berlin')" ]; then ok "no trailing newline -> own line"; else no "no-newline surface: $(cat "$files/prefs.out")"; fi
  : > "$files/prefs.out"; surf
  if [ "$(cat "$files/prefs.out")" = "lasttz=Europe/Berlin" ]; then ok "empty prefs.out -> exactly lasttz="; else no "empty surface: $(cat "$files/prefs.out")"; fi
  local junk
  for junk in "../x" "Europe/Ber lin" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
    printf 'tz=\nlocale=en-US\n' > "$files/prefs.out"; printf '%s\n' "$junk" > "$files/nowhere-lasttz"
    surf
    if [ "$(cat "$files/prefs.out")" = "$(printf 'tz=\nlocale=en-US')" ]; then ok "malformed file (${#junk} chars) not surfaced"; else no "malformed surfaced: $(cat "$files/prefs.out")"; fi
  done
  printf 'tz=\n' > "$files/prefs.out"; rm -f "$files/nowhere-lasttz"; surf
  if [ "$(cat "$files/prefs.out")" = "tz=" ]; then ok "no file -> prefs.out unchanged"; else no "no-file surface changed prefs.out"; fi
  if cmp -s "$files/nowhere-prefs" "$W/prefs.ref.$$"; then ok "nowhere-prefs never touched"; else no "nowhere-prefs changed"; fi
  src=$(grep -c 'lasttz' "$files/nowhere-prefs")
  if [ "$src" = 0 ]; then ok "nowhere-prefs holds no lasttz"; else no "nowhere-prefs holds lasttz"; fi

  # source checks
  local outarm tzl al sf cpl btl
  outarm=$(awk '/^  out\)$/{f=1} f{print} f&&/^    ;;$/{exit}' "$sut")
  tzl=$(printf '%s\n' "$outarm" | grep -n 'tz_seal_capture "\$USERDIR"' | head -1 | cut -d: -f1)
  al=$(printf '%s\n' "$outarm" | grep -n 'aod_seal_capture "\$USERDIR"' | head -1 | cut -d: -f1)
  if [ -n "$tzl" ] && [ -n "$al" ] && [ "$tzl" -gt "$al" ]; then ok "out calls tz_seal_capture after aod_seal_capture"; else no "out does not call tz_seal_capture after aod_seal_capture"; fi
  sf=$(grep -n '^ *tz_surface "\$USERDIR" "\$STATE/prefs.out"' "$sut" | cut -d: -f1)
  cpl=$(grep -n '&& cp "\$USERDIR/com.nowhere.chooser/files/nowhere-prefs" "\$STATE/prefs.out"' "$sut" | head -1 | cut -d: -f1)
  btl=$(grep -n 'if bt_reset "\$USERDIR"' "$sut" | head -1 | cut -d: -f1)
  if [ -n "$sf" ] && [ -n "$cpl" ] && [ -n "$btl" ] && [ "$sf" -gt "$cpl" ] && [ "$sf" -lt "$btl" ] && [ "$(printf '%s\n' "$sf" | wc -l)" = 1 ]; then
    ok "roam-in calls tz_surface once, after the prefs.out copy"; else no "tz_surface call missing, repeated or misplaced (call '$sf', copy '$cpl', bt_reset '$btl')"; fi
  src=$(sed -n '/^tz_seal_capture() {$/,/^}$/p; /^tz_surface() {$/,/^}$/p' "$sut" | grep -c '>>* *"[^"]*nowhere-prefs')
  if [ "$src" = 0 ]; then ok "no function writes nowhere-prefs"; else no "a function writes nowhere-prefs"; fi

  rm -rf "$ud" "$lib" "$logf" "$W/prefs.ref.$$"
  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh" "$p" "$x"
  [ "$x" = 0 ]
}

RC=0
for s in $SHELLS; do
  echo "== as committed [$s] =="
  suite "$SUT" "$s" || RC=1
done
if [ "$MUTATE" = no ]; then echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; fi
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo; echo "== mutations (each MUST be convicted under every shell) =="
MRC=0
# A mutant that did not apply is not evidence: it must exist, be non-empty and differ from the source.
apply_mut() {  # $1 dest, $2 sed expr
  sed "$2" "$SUT" > "$1" 2>/dev/null || return 1
  [ -s "$1" ] || return 1
  ! cmp -s "$1" "$SUT"
}
mutant() {  # $1 label, $2 sed expr
  local m sh; m=$(mktemp -p "$W")
  if ! apply_mut "$m" "$2"; then
    printf '  ⚠ NOT APPLIED  %s -- sed failed or changed nothing; NOT a conviction\n' "$1"; MRC=1; rm -f "$m"; return
  fi
  for sh in $SHELLS; do
    if suite "$m" "$sh" quiet >/dev/null; then printf '  ⚠ SURVIVED  %s [%s]\n' "$1" "$sh"; MRC=1; else printf '  convicted   %s [%s]\n' "$1" "$sh"; fi
  done
  rm -f "$m"
}
mutant "Z1 a bad read keeps the old file" \
  's#rm -f "\$_out" "\$_out.tmp" 2>/dev/null#:#'
mutant "Z2 the pattern accepts '..'" \
  's#\*\[!A-Za-z0-9_+/-\]\*#*[!A-Za-z0-9_+/.-]*#'
mutant "Z3 lasttz= written into nowhere-prefs" \
  's#>> "\$_p" 2>>#>> "$1/com.nowhere.chooser/files/nowhere-prefs" 2>>#'
mutant "Z4 the call in out removed" \
  '/^    tz_seal_capture "\$USERDIR"/d'
mutant "Z5 tz_surface skips the check" \
  's#tz_zone_ok "\$_z" || {#true || {#'
echo; [ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ a mutation survived or did not apply"
exit $MRC
