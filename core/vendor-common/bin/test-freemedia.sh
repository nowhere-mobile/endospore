#!/usr/bin/env bash
# test-freemedia.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `freemedia)` arm, Profile -> Storage "Free up space".
#
# WHY THIS IS COMMITTED. The arm used to delete every top-level regular file of the media cache dir. That set
# includes `.deleted`, the CE scope's tombstone list (the ONE positive-deletion signal the next seal reads), so a
# Free up space brought every on-demand file the user had deleted that session back at the next sign-in; it also
# deleted `.fetch-*` temps and `.part`/`.have` pairs mid-fill, which mediad's evictCache refuses to touch. The rule
# now: only a regular file named exactly 64 lowercase hex (mediad's cacheKey) goes. NWP-20261015-20.
# NWP-20261016-49: the arm purged only `.nowhere-media`, the CE vault's cache, while on-demand media streams through
# the `#media` scope's `.nowhere-media-ext`; the same rule now runs over both, and `-ext` keeps its own `.deleted`
# (the `#media` tombstones), in-flight files and `.under/` (the binds of the overlaid dirs: the user's real files).
#
#   bash test-freemedia.sh            # the cases, under bash, sh, dash and mksh (those present)
#   bash test-freemedia.sh --mutate   # ... plus mutants that must each CONVICT the suite
#
# The arm is extracted by anchor to its closing `    ;;` and run with USERDIR/STATE/LOG/RES in a temp tree.
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

arm=$(sed -n '/^  freemedia)$/,/^    ;;$/p' "$SUT")
case "$arm" in
  "  freemedia)"*"    ;;") ;;
  *) echo "EXTRACTION FAILED -- freemedia) arm not found in $SUT" >&2; exit 2 ;;
esac
ARM=$(printf '%s\n' "$arm" | sed '1d;$d')
case "$ARM" in *'$USERDIR/com.nowhere.chooser/files/.nowhere-media'*) ;; *) echo "EXTRACTION FAILED -- cache path missing from arm" >&2; exit 2 ;; esac

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

H1=$(printf 'a%.0s' $(seq 64)); H2=$(printf '0123456789abcdef%.0s' 1 2 3 4)
H3=$(printf 'b%.0s' $(seq 64)); H4=$(printf 'fedcba9876543210%.0s' 1 2 3 4)

# plant_cache <dir> <hexA> <sizeA> <hexB> <sizeB> <tombstones> -- two complete entries plus every name the arm keeps:
# the tombstone list, a `.fetch-*` temp, a `.part`/`.have` pair, a spaced name, and an `.under/` bind holding the
# user's real files -- one of them NAMED like a cache entry, so a recursive purge is caught deleting it.
plant_cache(){
  mkdir -p "$1/.under/DCIM"
  head -c "$3" /dev/zero > "$1/$2"
  head -c "$5" /dev/zero > "$1/$4"
  printf '%s' "$6" > "$1/.deleted"
  printf 'tmp' > "$1/.fetch-abc"
  printf 'p' > "$1/$2.part"; printf 'h' > "$1/$2.have"
  printf 'u' > "$1/.under/f"
  printf 'real' > "$1/.under/DCIM/$4"
  printf sp > "$1/a $4"
}

# run_case <shell> <arm-text> <layout both|ext|none> -- sets T (root), REPLY_TXT, CASE_RC
run_case(){
  local sh=$1 body=$2 layout=$3
  T=$(mktemp -d -p "$W")
  mkdir -p "$T/user" "$T/cwd" "$T/state"
  : > "$T/log"
  printf sentinel > "$T/cwd/b"; printf sentinel > "$T/cwd/$H2"
  C="$T/user/com.nowhere.chooser/files/.nowhere-media"
  X="$T/user/com.nowhere.chooser/files/.nowhere-media-ext"
  case "$layout" in
    both) plant_cache "$C" "$H1" 1000 "$H2" 2345 "$(printf 'one\ntwo\n')"
          plant_cache "$X" "$H3" 4000 "$H4" 600 "$(printf 'Download/x\nDCIM/y\n')" ;;
    ext)  plant_cache "$X" "$H3" 4000 "$H4" 600 "$(printf 'Download/x\nDCIM/y\n')" ;;
  esac
  printf 'USERDIR="%s"; STATE="%s"; LOG="%s"; RES="%s"; uid=10\n%s\n' \
    "$T/user" "$T/state" "$T/log" "$T/res" "$body" > "$T/arm.sh"
  (cd "$T/cwd" && "$sh" "$T/arm.sh" >/dev/null 2>&1); CASE_RC=$?
  REPLY_TXT=$(cat "$T/res" 2>/dev/null)
}

# kept_cache <label> <dir> <hexA> <hexB> <tombstones> -- every assertion about one cache dir after a purge
kept_cache(){
  local l=$1 d=$2
  [ ! -e "$d/$3" ] && [ ! -e "$d/$4" ] && ok "$l complete entries removed" || no "$l complete entries removed"
  [ "$(cat "$d/.deleted" 2>/dev/null)" = "$5" ] && ok "$l .deleted byte-identical" || no "$l .deleted byte-identical"
  [ -e "$d/.fetch-abc" ] && [ -e "$d/$3.part" ] && [ -e "$d/$3.have" ] && ok "$l in-flight files kept" || no "$l in-flight files kept"
  [ -e "$d/.under/f" ] && [ "$(cat "$d/.under/DCIM/$4" 2>/dev/null)" = real ] && ok "$l .under/ real files kept" || no "$l .under/ real files kept"
  [ -e "$d/a $4" ] && ok "$l spaced name kept" || no "$l spaced name kept"
}

check_arm(){ # <shell> <arm> -- runs every assertion; returns nothing, counts PASS/FAIL
  local sh=$1 body=$2 label=$1
  run_case "$sh" "$body" both
  kept_cache "[$label] CE" "$C" "$H1" "$H2" "$(printf 'one\ntwo')"
  kept_cache "[$label] -ext" "$X" "$H3" "$H4" "$(printf 'Download/x\nDCIM/y')"
  [ -e "$T/cwd/b" ] && [ -e "$T/cwd/$H2" ] && ok "[$label] cwd sentinel survives" || no "[$label] cwd sentinel survives"
  [ "$REPLY_TXT" = "OK 7945" ] && ok "[$label] reply OK <sum of both caches>" || no "[$label] reply OK <sum of both caches> (got '$REPLY_TXT')"
  rm -rf "$T"
  run_case "$sh" "$body" ext
  kept_cache "[$label] -ext alone" "$X" "$H3" "$H4" "$(printf 'Download/x\nDCIM/y')"
  [ "$REPLY_TXT" = "OK 4600" ] && ok "[$label] no CE cache dir: -ext still purged, OK 4600" || no "[$label] no CE cache dir: -ext still purged, OK 4600 (got '$REPLY_TXT')"
  rm -rf "$T"
  run_case "$sh" "$body" none
  [ "$REPLY_TXT" = "OK 0" ] && ok "[$label] absent cache dirs reply OK 0" || no "[$label] absent cache dirs reply OK 0 (got '$REPLY_TXT')"
  rm -rf "$T"
}

suite(){ # <arm>
  local s
  for s in $SHELLS; do
    check_arm "$s" "$1"
  done
}

echo "== freemedia =="
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
  if [ -z "$bad" ]; then printf '  convicted  %s\n' "$1"
  else printf '  SURVIVED   %s (no FAIL line under:%s)\n' "$1" "$bad"; SURV=$((SURV+1)); fi
}
# 1: the old `-type f` word-split loop, every filter gone
M1=$(printf '%s\n' "$ARM" | sed -e 's#for f in "\$CACHE"/\*; do#for f in $(find "$CACHE" -maxdepth 1 -type f 2>/dev/null); do#' \
  -e '/\[ -f "\$f" \]/d' -e '/name=\${f##/d' -e '/\${#name}/d' -e '/\[!0-9a-f\]/d')
# 2: hex name tests removed
M2=$(printf '%s\n' "$ARM" | grep -v -e '\${#name}' -e '\[!0-9a-f\]')
# 3: .deleted added to the delete set (the glob also walks dotfiles, and the name tests let it through)
M3=$(printf '%s\n' "$ARM" | sed -e 's#for f in "\$CACHE"/\*; do#for f in "$CACHE"/* "$CACHE"/.[!.]*; do#' -e 's#\[ "\${\#name}" -eq 64 \] || continue#[ "${\#name}" -eq 64 ] || [ "$name" = .deleted ] || continue#' \
  -e 's#case "\$name" in \*\[!0-9a-f\]\*) continue;; esac#case "$name" in .deleted) ;; *[!0-9a-f]*) continue;; esac#')
# 4: word-splitting loop over the glob-less find, hex rule kept
M4=$(printf '%s\n' "$ARM" | sed 's#for f in "\$CACHE"/\*; do#for f in $(find "$CACHE" -maxdepth 1 -type f 2>/dev/null); do#')
# 5: the -ext cache dropped from the loop (the arm before NWP-20261016-49)
M5=$(printf '%s\n' "$ARM" | sed -e '/nowhere-media-ext"; do$/d' -e 's#/\.nowhere-media" \\$#/.nowhere-media"; do#')
# 6: an absent CE cache dir ends the loop, so the -ext cache is never reached
M6=$(printf '%s\n' "$ARM" | sed 's#\[ -d "\$CACHE" \] || continue#[ -d "$CACHE" ] || break#')
# 7: the -ext cache wiped wholesale (its tombstones, in-flight files and .under binds with it)
M7=$(printf '%s\n' "$ARM" | sed 's#^\( *\)\[ -d "\$CACHE" \] || continue$#&\n\1case "$CACHE" in *-ext) rm -rf "$CACHE"/* "$CACHE"/.[!.]* 2>/dev/null; continue;; esac#')
# 8: a recursive walk (hex rule kept) that reaches through .under into the user's real files
M8=$(printf '%s\n' "$ARM" | sed 's#for f in "\$CACHE"/\*; do#for f in $(find "$CACHE" -type f 2>/dev/null); do#')
for m in M1 M2 M3 M4 M5 M6 M7 M8; do
  [ "${!m}" != "$ARM" ] || { echo "MUTANT $m failed to apply" >&2; SURV=$((SURV+1)); }
done
mutant "old -type f loop restored" "$M1"
mutant "hex name test removed" "$M2"
mutant ".deleted added to the delete set" "$M3"
mutant "word-splitting loop restored" "$M4"
mutant "-ext cache dropped from the loop" "$M5"
mutant "absent CE dir stops the -ext purge" "$M6"
mutant "-ext cache wiped wholesale" "$M7"
mutant "recursive walk reaches .under" "$M8"
[ "$SURV" = 0 ] || { echo "$SURV mutant(s) not convicted" >&2; exit 1; }
