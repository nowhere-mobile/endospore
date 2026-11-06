#!/usr/bin/env bash
# test-plan-choice-java.sh [--mutate] -- the Add credit screen's convert-or-keep question, run under javac (NWP-20261031-11).
#
# WHY THIS IS COMMITTED. A paid plan that is live must be offered the choice, convert preselected, and the answer must
# reach the daemon as CLAIM2; otherwise the agent and gateway keep a plan no screen ever lets a customer ask for.
# PlanChoice (pure, java.lang only) holds when to ask and the request text and is compiled here with its cases; source
# checks over ProfileActivity pin that the Redeem handler builds its request with it, that the options are shown only
# under shouldAsk, that CONVERT is the preselected one, and (NWP-20261125-12, h51 #5) that each option's grey line sits
# inside the option group directly after it, in the grey note style.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-plan-choice-java.sh            # the cases and the source checks
#   bash test-plan-choice-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/PlanChoice.java"
SCREEN="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/plan-choice/PlanChoiceCases.java"
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

# suite <PlanChoice.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  PlanChoice.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/PlanChoice.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/PlanChoiceCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PlanChoiceCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# source <ProfileActivity.java> -> 0 when the screen is wired as shipped, 1 otherwise. Every grep result is captured.
source_checks() {
  local f="$1" body bad=0 n note
  body=$(awk '/private void addCreditsScreen\(/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  [ -n "$body" ] || { echo "  FAIL  addCreditsScreen not found in $f" >&2; return 1; }

  n=$(printf '%s\n' "$f" | xargs grep -c 'PlanChoice\.claimRequest(code, planAsked\[0\], keepRb\.isChecked())')
  [ "$n" -eq 1 ] || { echo "  FAIL  the Redeem handler's request does not come from PlanChoice.claimRequest (asked, keep)" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/sendDaemon\(claimReq\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  the Redeem handler does not send the claimReq it built" >&2; bad=1; }
  n=$(awk '$0 !~ /^[ \t]*\/\// && /"CLAIM\\n" \+ code/ { n++ } END { print n + 0 }' "$f")
  [ "$n" -eq 0 ] || { echo "  FAIL  a literal \"CLAIM\\n\" + code remains in ProfileActivity" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/planGroup\.setVisibility\(View\.VISIBLE\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  the options are not made visible exactly once" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/if \(ask\) planGroup\.setVisibility\(View\.VISIBLE\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  the options are not shown only under shouldAsk's answer" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/final boolean ask = PlanChoice\.shouldAsk\(sendDaemon\("GET-BILLING\\n"\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  shouldAsk is not fed the GET-BILLING reply" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/convertRb\.setChecked\(true\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  CONVERT is not the preselected option" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/keepRb\.setChecked\(true\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 0 ] || { echo "  FAIL  KEEP is preselected" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/planChoiceRadio\(PlanChoice\.CONVERT\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  the convert option does not carry PlanChoice.CONVERT" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk '/planChoiceRadio\(PlanChoice\.KEEP\)/ { n++ } END { print n + 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  the keep option does not carry PlanChoice.KEEP" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | awk 'match($0, /planGroup\.addView\([^;]*\);/) { s = s substr($0, RSTART + 18, RLENGTH - 20) "|" } END { print s }')
  [ "$n" = "convertRb|planChoiceNote(PlanChoice.CONVERT_NOTE)|keepRb|planChoiceNote(PlanChoice.KEEP_NOTE)|" ] \
    || { echo "  FAIL  planGroup does not hold convert, its note, keep, its note, in that order (got $n)" >&2; bad=1; }
  note=$(awk '/private TextView planChoiceNote\(/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  n=$(printf '%s\n' "$note" | awk '/setTextColor\(MUTED\)/ { a++ } /setTextSize\(TypedValue\.COMPLEX_UNIT_SP, 12\)/ { b++ } END { print (a == 1 && b == 1) ? 1 : 0 }')
  [ "$n" -eq 1 ] || { echo "  FAIL  planChoiceNote is not a MUTED 12sp line" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_checks "$SCREEN" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates PlanChoice.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/PlanChoice.java"
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
muts() { # muts <label> <perl-expr>   (mutates ProfileActivity.java; the source checks must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ProfileActivity.java"
  cp "$SCREEN" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SCREEN" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_checks "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "T1 shouldAsk true for an expired term" 's/return nowSec < \(through \+ 1\) \* epochsec;/return nowSec < (through + 1) * epochsec || true;/' || fails=$((fails+1))
mut "T2 keep and convert swapped in claimRequest" 's/\(keep \? "keep" : "convert"\)/(keep ? "convert" : "keep")/' || fails=$((fails+1))
mut "T5 the last paid epoch is not live (through + 1 back to through)" 's/\(through \+ 1\) \* epochsec/through * epochsec/g' || fails=$((fails+1))
mut "T6 the first second after the term is still live" 's/nowSec < \(through/nowSec <= (through/' || fails=$((fails+1))
mut "T7 the convert note reworded" 's/the other.s time is added to it at its value\./the other time is added./' || fails=$((fails+1))
muts "T8 the keep note dropped from the group" 's/\n[ \t]*planGroup\.addView\(planChoiceNote\(PlanChoice\.KEEP_NOTE\)\);//' || fails=$((fails+1))
muts "T9 the convert note dropped from the group" 's/\n[ \t]*planGroup\.addView\(planChoiceNote\(PlanChoice\.CONVERT_NOTE\)\);//' || fails=$((fails+1))
muts "T10 the note is not grey" 's/tv\.setTextColor\(MUTED\);/tv.setTextColor(FIELD_TX);/' || fails=$((fails+1))
muts "T3 KEEP preselected" 's/convertRb\.setChecked\(true\)/keepRb.setChecked(true)/' || fails=$((fails+1))
muts "T4 the handler sends CLAIM even when asked" 's/PlanChoice\.claimRequest\(code, planAsked\[0\],/PlanChoice.claimRequest(code, false,/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
