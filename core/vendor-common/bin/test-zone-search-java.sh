#!/usr/bin/env bash
# test-zone-search-java.sh [--mutate] -- Profile's time zone search, run under javac (NWP-20261117-43).
#
# WHY THIS IS COMMITTED. The picker's rows show an Olson id with every '_' as a space ("America/New York"), but its
# search matched the raw id, so "new york" found nothing; it also folded case in the default locale, so under tr-TR
# "istanbul" never matched "Europe/Istanbul". The fold, the match, the "Automatic" match and the row label live in
# ZoneSearch (java.* only) and are compiled here with their cases; source checks on the real ProfileActivity.java
# (comments stripped) pin that showTimezonePicker matches through ZoneSearch and lower-cases nothing itself, and that
# zoneLabel builds its text with ZoneSearch.label.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-zone-search-java.sh            # the cases and the source checks
#   bash test-zone-search-java.sh --mutate  # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${ZONE_SEARCH_SRC:-$SRC/ZoneSearch.java}"
PROFILE="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/zone-search/ZoneSearchCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <ZoneSearch.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  ZoneSearch.java does not exist (the search is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/ZoneSearch.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ZoneSearchCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ZoneSearchCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip_comments <file> -> the Java source on stdout with // and /* */ comments removed (string and char literals kept).
strip_comments() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse' "$1"
}

# source_check <ProfileActivity.java> -> 0 when the wiring holds, 1 otherwise.
source_check() {
  local profile="$1" code picker label bad=0
  command -v perl >/dev/null 2>&1 || { echo "  FAIL  no perl: the comment-stripped source checks cannot run" >&2; return 1; }
  code=$(strip_comments "$profile") || { echo "  FAIL  could not strip comments from $profile" >&2; return 1; }
  picker=$(printf '%s\n' "$code" | awk '/private void showTimezonePicker\(\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  label=$(printf '%s\n' "$code" | awk '/private String zoneLabel\(String id\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  if [ -z "$picker" ]; then echo "  FAIL  showTimezonePicker not found in $profile" >&2; return 1; fi
  if [ -z "$label" ]; then echo "  FAIL  zoneLabel not found in $profile" >&2; return 1; fi
  # Controls: text each body must hold whatever this slice changes, so an empty or wrong extraction cannot pass.
  grep -qF 'list.addView(zoneRow(zoneLabel(id), id));' <<<"$picker" \
    || { echo "  FAIL  control: showTimezonePicker lost its zone row -- the extraction is broken" >&2; bad=1; }
  grep -qF 'if (shown >= 60) break;' <<<"$picker" \
    || { echo "  FAIL  control: showTimezonePicker lost its 60-row cap -- the extraction is broken" >&2; bad=1; }
  grep -qF 'getOffset(System.currentTimeMillis())' <<<"$label" \
    || { echo "  FAIL  control: zoneLabel no longer reads the current offset -- the extraction is broken" >&2; bad=1; }
  grep -qF 'ZoneSearch.matches(id, q)' <<<"$picker" \
    || { echo "  FAIL  S1 showTimezonePicker does not match a zone with ZoneSearch.matches(id, q)" >&2; bad=1; }
  grep -qF 'ZoneSearch.automaticMatches(q)' <<<"$picker" \
    || { echo "  FAIL  S2 showTimezonePicker does not match Automatic with ZoneSearch.automaticMatches(q)" >&2; bad=1; }
  if grep -qF '.toLowerCase(' <<<"$picker"; then
    echo "  FAIL  S3 showTimezonePicker still lower-cases text itself (.toLowerCase)" >&2; bad=1
  fi
  grep -qF 'ZoneSearch.label(' <<<"$label" \
    || { echo "  FAIL  S4 zoneLabel does not build its text with ZoneSearch.label" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
rc=0
suite "$SUT" || { echo "FAILED"; rc=1; }
echo "== $PROFILE"
if source_check "$PROFILE"; then echo "source: ok"; else echo "FAILED (source)"; rc=1; fi
[ "$rc" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates ZoneSearch.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ZoneSearch.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ProfileActivity.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ProfileActivity.java"
  cp "$PROFILE" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$PROFILE" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "Z1 fold leaves '_' alone" 's/return s\.replace\(\x27_\x27, \x27 \x27\)\.toLowerCase/return s.toLowerCase/' || fails=$((fails+1))
mut "Z2 fold lower-cases in the default locale" 's/toLowerCase\(Locale\.ROOT\)\.trim\(\)/toLowerCase().trim()/' || fails=$((fails+1))
mut "Z3 label drops the minutes of a half-hour offset" 's/off \/ 60, off % 60/off \/ 60, 0/' || fails=$((fails+1))
mutsrc "Z4 the rebuild's id.toLowerCase().contains(q) restored" 's/ZoneSearch\.matches\(id, q\)/q.isEmpty() || id.toLowerCase().contains(q)/' || fails=$((fails+1))
mutsrc "Z5 the match call only inside a line comment" 's/if \(ZoneSearch\.matches\(id, q\)\) \{/if (true) { \/\/ if (ZoneSearch.matches(id, q)) {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
