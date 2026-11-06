#!/usr/bin/env bash
# test-bootsweep-appcode.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's `appcode0` category
# (NWP-20261024-02), run for real rather than grepped.
#
# The `in` arm stages a profile's #apps scope (cleartext APKs + manifest.tsv, which names every app) in the
# user-0 chooser's files/.appcode, and the chooser removes it only after installing. A crash before that leaves the
# profile's app list and APK bytes on durable storage across power-off. The category must:
#   - remove .appcode when no session marker exists, and report how many packages it held;
#   - touch NOTHING while a .roamsession marker exists (the gate may still be installing from it);
#   - never follow or remove a symbolic link at .appcode (UNREACHABLE);
#   - say ABSENT only when the files directory LISTS and names no `.appcode`; a failing listing, or a denied
#     `[ -d ]` on a staging that exists, reads UNREACHABLE;
#   - report <n>/LEFT when the staging survives the remove;
#   - append to `_swept` exactly once on every path, and never print an entry name.
# The marker check is sound only while BOOT-SWEEP is not in main.go's concurrentSafeCmd (it then holds sessionMu, as
# ROAM-IN does); the last case pins that.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (its header line up to the next `  # ---` header or the
# `  # Report what was actually removed` line); if the anchors move, extraction fails loudly. The paths are
# substituted by a temp tree and run under every shell present among bash, sh, dash and mksh.
#
#   bash test-bootsweep-appcode.sh            # the behaviour cases
#   bash test-bootsweep-appcode.sh --mutate   # ... plus mutations that must each CONVICT the suite
# MAINGO=<main.go> overrides the daemon source the concurrentSafeCmd pin reads.
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(dirname "$0")
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
MAINGO="${MAINGO:-$HERE/../../agent/main.go}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ -f "$MAINGO" ] || { echo "no such file: $MAINGO" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done

# --- extraction -----------------------------------------------------------------------------------------
HDR="  # --- appcode0: the gate's app-code staging (NWP-20261024-02) ---"
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1) { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'appcode0=ABSENT'*'appcode0=UNREACHABLE'*) ;;
  *) echo "EXTRACTION FAILED: the appcode0 category" >&2; exit 2 ;; esac
printf '%s\n' "$BLOCK" > "$W/block.sh"
bash -n "$W/block.sh" 2>/dev/null || { echo "EXTRACTION FAILED: the appcode0 block does not parse" >&2; exit 2; }
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  $0 == h { blk = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && blk > op && res > blk) ? "in" : "out" }' "$SUT")

# --- harness --------------------------------------------------------------------------------------------
# The chooser's files dir -> $R/files, $STATE -> $R/state. `[ -d ` -> _tdir and ls/rm -> stubs, so a denial or a
# failed remove can be simulated per path (root ignores mode bits, so chmod proves nothing on a CI runner).
# The stubs are POSIX: they must run under dash and mksh too.
RUNBLK=$(printf '%s\n' "$BLOCK" | sed \
  -e 's@/data/user/0/com.nowhere.chooser/files@$R/files@g' -e 's@\$STATE@$R/state@g' -e 's@\[ -d @_tdir @g')
{
  cat <<'STUBS'
_tdir(){ case " ${DENY_D:-} " in *" $1 "*) return 1 ;; esac; [ -d "$1" ]; }
ls(){ for last; do :; done
  case " ${DENY_LS:-} " in *" $last "*) return 1 ;; esac
  command ls "$@"; }
rm(){ [ "${RMFAIL:-}" = 1 ] && return 1; command rm "$@"; }
LOG="$R/log"; _swept=""
STUBS
  printf '%s\n' "$RUNBLK"
  printf "printf '%%s' \"\$_swept\"\n"
} > "$W/driver.sh"

# runblk <shell> <root> [VAR=val ...] -> prints the resulting _swept
runblk(){ local sh="$1" r="$2"; shift 2
  env "$@" R="$r" "$sh" "$W/driver.sh" 2>>"$r/stderr"; }
once(){ [ "$(printf '%s\n' "$1" | grep -o 'appcode0=' | wc -l)" -eq 1 ]; }
mktree(){ local t; t=$(mktemp -d -p "$W"); mkdir -p "$t/state" "$t/files"; echo "$t"; }
mkstage(){   # mkstage <root>: manifest + two packages + a sibling of .appcode
  mkdir -p "$1/files/.appcode/com.example.bank" "$1/files/.appcode/com.example.chat" "$1/files/other"
  echo "com.example.bank	1	1	x	base.apk" > "$1/files/.appcode/manifest.tsv"
  echo apk1 > "$1/files/.appcode/com.example.bank/base.apk"
  echo apk2 > "$1/files/.appcode/com.example.chat/base.apk"
  echo keep > "$1/files/other/f"
}
snap(){ ( cd "$1" && find files state elsewhere -print 2>/dev/null | sort && find files state elsewhere -type f -exec cksum {} + 2>/dev/null | sort ); }

echo "== position =="
[ "$POS" = in ] && ok "the category sits inside the bootsweep op, before its result line" \
  || no "the category is not between the bootsweep op and its result line"

echo "== source pins =="
BAD=$(printf '%s\n' "$BLOCK" | awk '
  /^[ \t]*#/ { next }
  /(echo|printf|print )/ && /_l|_ac\// && !/\| grep/ { print }')
[ -z "$BAD" ] && ok "no echo/print in the block expands an entry name" || no "a line may print an entry: $BAD"
FN=$(awk '/^func concurrentSafeCmd/ { on = 1 } on { print } on && /^}/ { exit }' "$MAINGO")
case "$FN" in *'func concurrentSafeCmd'*) ;; *) echo "EXTRACTION FAILED: concurrentSafeCmd in $MAINGO" >&2; exit 2 ;; esac
case "$FN" in *'"BOOT-SWEEP"'*) no "BOOT-SWEEP is in concurrentSafeCmd: it would not hold sessionMu, so the marker check is unsound" ;;
  *) ok "concurrentSafeCmd does not list BOOT-SWEEP (the marker check holds under sessionMu)" ;; esac

for sh in "${SHELLS[@]}"; do
tag="[${sh##*/}]"
echo "== $tag no marker: the staging goes and its package count is reported =="
T=$(mktree); mkstage "$T"; S=$(runblk "$sh" "$T")
[ "$S" = " appcode0=2" ] && ok "$tag reports appcode0=2 (manifest.tsv is not a package)" || no "$tag reported '$S', want ' appcode0=2'"
[ ! -e "$T/files/.appcode" ] && ok "$tag .appcode is gone" || no "$tag .appcode survived"
[ -f "$T/files/other/f" ] && ok "$tag a sibling in the files dir is untouched" || no "$tag a sibling was removed"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
if grep -q -e com.example -e manifest -e base.apk "$T/log" "$T/stderr" 2>/dev/null \
   || case "$S" in *com.example*|*manifest*|*apk*) true ;; *) false ;; esac; then no "$tag an entry name was printed"
else ok "$tag no entry name in the result, the log or stderr"; fi

T=$(mktree); mkdir -p "$T/files/.appcode"; S=$(runblk "$sh" "$T")
[ "$S" = " appcode0=0" ] && [ ! -e "$T/files/.appcode" ] && ok "$tag an empty staging is removed and reads appcode0=0" || no "$tag reported '$S'"

echo "== $tag a live session's staging is untouched =="
T=$(mktree); mkstage "$T"; echo 1234 > "$T/state/.roamsession"; B=$(snap "$T"); S=$(runblk "$sh" "$T"); A=$(snap "$T")
[ "$S" = " appcode0=KEPT:session" ] && ok "$tag reports appcode0=KEPT:session" || no "$tag reported '$S'"
[ "$A" = "$B" ] && ok "$tag every entry is byte for byte as it was" || no "$tag the tree changed under a live session"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"

echo "== $tag a symbolic link at .appcode is never followed =="
T=$(mktree); mkdir -p "$T/elsewhere"; echo keep > "$T/elsewhere/sentinel"; ln -s "$T/elsewhere" "$T/files/.appcode"
S=$(runblk "$sh" "$T")
[ "$S" = " appcode0=UNREACHABLE" ] && ok "$tag reports appcode0=UNREACHABLE" || no "$tag reported '$S'"
[ -f "$T/elsewhere/sentinel" ] && ok "$tag the link target's content survives" || no "$tag the target was emptied through the link"
[ -L "$T/files/.appcode" ] && ok "$tag the link itself is left" || no "$tag the link was removed"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"

echo "== $tag absent, and a denial is never ABSENT =="
T=$(mktree); mkdir -p "$T/files/xappcode"; : > "$T/files/other"; S=$(runblk "$sh" "$T")
[ "$S" = " appcode0=ABSENT" ] && ok "$tag a listable files dir without .appcode: ABSENT (a sibling xappcode does not count)" || no "$tag reported '$S'"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
[ ! -e "$T/files/.appcode" ] && ok "$tag nothing is created" || no "$tag .appcode was created"
T=$(mktree); S=$(runblk "$sh" "$T" DENY_LS="$T/files")
[ "$S" = " appcode0=UNREACHABLE" ] && ok "$tag a files dir that cannot be listed: UNREACHABLE, not ABSENT" || no "$tag reported '$S'"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
T=$(mktree); mkstage "$T"; B=$(snap "$T"); S=$(runblk "$sh" "$T" DENY_D="$T/files/.appcode"); A=$(snap "$T")
[ "$S" = " appcode0=UNREACHABLE" ] && ok "$tag [ -d ] denied on an existing staging: UNREACHABLE, not ABSENT" || no "$tag reported '$S'"
[ "$A" = "$B" ] && ok "$tag and nothing was removed blind" || no "$tag the tree changed"
T=$(mktree); mkstage "$T"; B=$(snap "$T"); S=$(runblk "$sh" "$T" DENY_LS="$T/files/.appcode"); A=$(snap "$T")
[ "$S" = " appcode0=UNREACHABLE" ] && [ "$A" = "$B" ] && ok "$tag a staging that cannot be counted: UNREACHABLE, nothing removed" || no "$tag reported '$S'"

echo "== $tag what stays is reported as LEFT =="
T=$(mktree); mkstage "$T"; S=$(runblk "$sh" "$T" RMFAIL=1)
[ "$S" = " appcode0=2/LEFT" ] && ok "$tag a failing rm reports appcode0=2/LEFT" || no "$tag reported '$S'"
[ -f "$T/files/.appcode/manifest.tsv" ] && ok "$tag the staging is intact" || no "$tag the staging changed"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite) =="
  # mutate <label> <roamd|main> <sed>
  mutate(){ local m; m=$(mktemp -d -p "$W")
    case "$2" in roamd) src="$SUT" ;; *) src="$MAINGO" ;; esac
    if ! sed "$3" "$src" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN (sed): $1: $(cat "$m/err")"; return; fi
    if cmp -s "$src" "$m/m"; then no "MUTATION INERT: $1"; return; fi
    if [ "$2" = roamd ]; then bash "$0" "$m/m" >/dev/null 2>&1; else MAINGO="$m/m" bash "$0" "$SUT" >/dev/null 2>&1; fi
    if [ $? -eq 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"; else ok "convicted: $1"; fi
    rm -rf "$m"
  }
  mutate "A1: the marker check is removed" roamd 's@^  elif \[ -s "\$STATE/.roamsession" \]; then$@  elif false; then@'
  mutate "A2: the symlink check is removed" roamd 's@^  if \[ -L "\$_ac" \]; then$@  if false; then@'
  mutate "A3: the absent branch reports ABSENT without listing the parent" roamd 's@^  elif _l=\$(ls -1A "\$_acp" 2>/dev/null); then$@  elif true; then@'
  mutate "A4: the post-rm re-check is removed" roamd 's@^      if \[ -e "\$_ac" \]; then _swept=@      if false; then _swept=@'
  mutate "A5: BOOT-SWEEP joins concurrentSafeCmd" main 's@^\tcase "POLL-REAP", "ACK-REAP",$@\tcase "POLL-REAP", "ACK-REAP", "BOOT-SWEEP",@'
  mutate "A6: the .appcode membership check is dropped" roamd 's@^    case "\$(printf .%s\\n. "\$_l" | grep -cxF .appcode)" in$@    case 0 in@'
fi

echo
echo "shells: ${SHELLS[*]}"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
