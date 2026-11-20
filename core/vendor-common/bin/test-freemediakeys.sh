#!/usr/bin/env bash
# test-freemediakeys.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `freemediakeys)` arm, "Free on this phone" for one
# folder row (NWP-20261207-14, h51 #4). The login daemon lists the cache keys of that folder's on-demand files in
# $STATE/freemedia.keys; the arm deletes exactly those complete entries in both fetch caches and nothing else: not an
# unlisted entry, not `.deleted`, a `.fetch-*` temp, a `.part`/`.have` pair, `.under/` (the user's real files), a
# symlink named by a key or the parked app data in `.nowhere-odhold`. A line that is not exactly 64 lowercase hex is
# skipped, so a list can not name a path outside the caches. No list frees nothing.
#
#   bash test-freemediakeys.sh            # the cases, under bash, sh, dash and mksh (those present)
#   bash test-freemediakeys.sh --mutate   # ... plus mutants that must each CONVICT the suite under every shell
#
# The arm is extracted by anchor to its closing `    ;;` (as test-freemedia.sh extracts freemedia) and run with
# USERDIR/STATE/LOG/RES in a temp tree.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "  skip  shell $s not installed"; fi
done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

arm=$(sed -n '/^  freemediakeys)$/,/^    ;;$/p' "$SUT")
case "$arm" in
  "  freemediakeys)"*"    ;;") ;;
  *) echo "EXTRACTION FAILED -- freemediakeys) arm not found in $SUT" >&2; exit 2 ;;
esac
ARM=$(printf '%s\n' "$arm" | sed '1d;$d')
case "$ARM" in *'KEYS="$STATE/freemedia.keys"'*) ;; *) echo "EXTRACTION FAILED -- key list path missing from arm" >&2; exit 2 ;; esac

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

H1=$(printf 'a%.0s' $(seq 64)); H2=$(printf '0123456789abcdef%.0s' 1 2 3 4)
H3=$(printf 'b%.0s' $(seq 64)); H4=$(printf 'fedcba9876543210%.0s' 1 2 3 4)
H5=$(printf 'c%.0s' $(seq 64)); H6=$(printf 'd%.0s' $(seq 64)); H7=$(printf 'e%.0s' $(seq 64))
UP=$(printf 'A%.0s' $(seq 64)); SHORT=$(printf 'f%.0s' $(seq 63))

# run_case <shell> <arm-text> <list yes|no|nonl> -- plants both caches and every kept name, writes the list, runs the
# arm; sets T (root), C, X, F (the chooser files dir), REPLY_TXT.
#   CE   (.nowhere-media):     H1 listed (1000 B), H2 unlisted, the in-flight and .under names, an odhold-shaped dir
#   -ext (.nowhere-media-ext): H3 listed (4000 B), H4 unlisted, a symlink named by listed H5, an uppercase entry
#   files/: the target of a `../<hex>` line, H6 (also listed through that line)
#   com.nowhere.chooser/.nowhere-odhold/<pkg>/: parked data named by listed H1
run_case(){
  local sh=$1 body=$2 list=$3
  T=$(mktemp -d -p "$W")
  mkdir -p "$T/user" "$T/cwd" "$T/state"
  : > "$T/log"
  F="$T/user/com.nowhere.chooser/files"
  C="$F/.nowhere-media"; X="$F/.nowhere-media-ext"
  mkdir -p "$C/.under/DCIM" "$X/.under" "$C/.nowhere-odhold/pkg" "$T/user/com.nowhere.chooser/.nowhere-odhold/com.x"
  head -c 1000 /dev/zero > "$C/$H1"; head -c 2345 /dev/zero > "$C/$H2"
  head -c 4000 /dev/zero > "$X/$H3"; head -c 600 /dev/zero > "$X/$H4"
  printf 'one\n' > "$C/.deleted"; printf 'Download/x\n' > "$X/.deleted"
  printf t > "$C/.fetch-x"; printf p > "$C/$H1.part"; printf h > "$C/$H1.have"
  printf t > "$X/.fetch-x"; printf p > "$X/$H3.part"
  printf real > "$C/.under/$H1"; printf real > "$X/.under/$H3"
  printf held > "$C/.nowhere-odhold/pkg/$H1"
  printf parked > "$T/user/com.nowhere.chooser/.nowhere-odhold/com.x/$H1"
  printf linked > "$T/linktarget"; ln -s "$T/linktarget" "$X/$H5"
  printf up > "$X/$UP"; printf short > "$X/$SHORT"
  printf outside > "$F/$H6"
  case "$list" in
    yes)  printf '%s\n' "$H1" "$H3" "$H5" "$UP" "$SHORT" "../$H6" "$H7 " "$H7" > "$T/state/freemedia.keys" ;;
    nonl) printf '%s\n%s' "$H1" "$H3" > "$T/state/freemedia.keys" ;;
  esac
  printf 'USERDIR="%s"; STATE="%s"; LOG="%s"; RES="%s"; uid=10\n%s\n' \
    "$T/user" "$T/state" "$T/log" "$T/res" "$body" > "$T/arm.sh"
  (cd "$T/cwd" && "$sh" "$T/arm.sh" >/dev/null 2>&1)
  REPLY_TXT=$(cat "$T/res" 2>/dev/null)
}

# kept_all <label> -- every entry the arm must never delete, whatever the list says
kept_all(){
  local l=$1
  [ -e "$C/$H2" ] && [ -e "$X/$H4" ] && ok "$l unlisted entries kept" || no "$l unlisted entries kept"
  [ "$(cat "$C/.deleted" 2>/dev/null)" = one ] && [ "$(cat "$X/.deleted" 2>/dev/null)" = Download/x ] \
    && ok "$l .deleted kept" || no "$l .deleted kept"
  [ -e "$C/.fetch-x" ] && [ -e "$C/$H1.part" ] && [ -e "$C/$H1.have" ] && [ -e "$X/.fetch-x" ] && [ -e "$X/$H3.part" ] \
    && ok "$l in-flight files kept" || no "$l in-flight files kept"
  [ -e "$C/.under/$H1" ] && [ -e "$X/.under/$H3" ] && ok "$l .under/<key> kept" || no "$l .under/<key> kept"
  [ -L "$X/$H5" ] && [ -e "$T/linktarget" ] && ok "$l symlink named by a listed key kept" || no "$l symlink named by a listed key kept"
  [ -e "$C/.nowhere-odhold/pkg/$H1" ] && [ -e "$T/user/com.nowhere.chooser/.nowhere-odhold/com.x/$H1" ] \
    && ok "$l .nowhere-odhold/<pkg>/<key> kept" || no "$l .nowhere-odhold/<pkg>/<key> kept"
  [ -e "$X/$UP" ] && [ -e "$X/$SHORT" ] && [ -e "$F/$H6" ] \
    && ok "$l uppercase, 63-hex and ../<hex> lines skipped" || no "$l uppercase, 63-hex and ../<hex> lines skipped"
}

check_arm(){ # <shell> <arm>
  local sh=$1 body=$2 l="[$1]"
  run_case "$sh" "$body" yes
  [ ! -e "$C/$H1" ] && [ ! -e "$X/$H3" ] && ok "$l listed entries deleted in both caches" || no "$l listed entries deleted in both caches"
  [ "$REPLY_TXT" = "OK 5000" ] && ok "$l reply OK <summed size>" || no "$l reply OK <summed size> (got '$REPLY_TXT')"
  kept_all "$l"
  [ ! -e "$T/state/freemedia.keys" ] && ok "$l list removed after the run" || no "$l list removed after the run"
  rm -rf "$T"
  run_case "$sh" "$body" no
  [ "$REPLY_TXT" = "ERR-NOKEYS" ] && ok "$l no list: ERR-NOKEYS" || no "$l no list: ERR-NOKEYS (got '$REPLY_TXT')"
  [ -e "$C/$H1" ] && [ -e "$X/$H3" ] && ok "$l no list: nothing deleted" || no "$l no list: nothing deleted"
  kept_all "$l no list:"
  rm -rf "$T"
  run_case "$sh" "$body" nonl
  [ ! -e "$X/$H3" ] && [ "$REPLY_TXT" = "OK 5000" ] && ok "$l last line without a newline read" || no "$l last line without a newline read (got '$REPLY_TXT')"
  rm -rf "$T"
}

suite(){ # <arm>
  local s
  for s in $SHELLS; do
    check_arm "$s" "$1"
  done
}

echo "== freemediakeys =="
suite "$ARM"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

echo "== mutants =="
SURV=0
# A mutant is convicted only when every shell found prints its own FAIL line (mksh's included). The suite runs in a
# subshell, so its PASS/FAIL counts never reach the baseline's.
mutant(){ # <name> <arm-text>
  local res bad="" t
  res=$(suite "$2")
  for t in $SHELLS; do
    case "$res" in *"  FAIL  [$t]"*) ;; *) bad="$bad $t" ;; esac
  done
  if [ -z "$bad" ]; then printf '  convicted  %s by:%s\n' "$1" "$(printf '%s\n' "$res" | sed -n 's/^  FAIL  \[[a-z]*\] //p' | sort -u | tr '\n' ';')"
  else printf '  SURVIVED   %s (no FAIL line under:%s)\n' "$1" "$bad"; SURV=$((SURV+1)); fi
}
# K1: the 64-hex check dropped (a ../<hex> line reaches files/, an uppercase line its entry)
K1=$(printf '%s\n' "$ARM" | grep -v -e '\${#key}' -e '\[!0-9a-f\]')
# K2: the symlink check dropped
K2=$(printf '%s\n' "$ARM" | sed 's#\[ -f "\$f" \] && \[ ! -L "\$f" \] || continue#[ -f "$f" ] || continue#')
# K3: an absent list answers OK 0
K3=$(printf '%s\n' "$ARM" | sed 's#echo "ERR-NOKEYS" > "\$RES"#echo "OK 0" > "$RES"#')
# K4: the bytes not summed
K4=$(printf '%s\n' "$ARM" | sed 's#freed=\$((freed + sz))#freed=$freed#')
# K5: only the -ext cache visited
K5=$(printf '%s\n' "$ARM" | sed 's#for CACHE in "\$USERDIR/com\.nowhere\.chooser/files/\.nowhere-media" \\$#for CACHE in \\#')
# K6: every 64-hex entry deleted, freemedia's loop in place of the listed keys
K6=$(printf '%s\n' "$ARM" | sed -e 's#^\( *\)f="\$CACHE/\$key"$#\1for f in "$CACHE"/*; do name=${f\#\#*/}; [ "${\#name}" -eq 64 ] || continue#' \
  -e 's#rm -f "\$f" 2>> "\$LOG" && freed=\$((freed + sz))$#& ; done#')
for m in K1 K2 K3 K4 K5 K6; do
  [ "${!m}" != "$ARM" ] || { echo "MUTANT $m failed to apply" >&2; SURV=$((SURV+1)); }
done
mutant "K1 64-hex check dropped" "$K1"
mutant "K2 symlink check dropped" "$K2"
mutant "K3 absent list answers OK 0" "$K3"
mutant "K4 bytes not summed" "$K4"
mutant "K5 only the -ext cache visited" "$K5"
mutant "K6 every 64-hex entry deleted" "$K6"
[ "$SURV" = 0 ] || { echo "$SURV mutant(s) not convicted" >&2; exit 1; }
