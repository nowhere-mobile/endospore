#!/usr/bin/env bash
# test-esim-note-java.sh [--mutate] -- the SIM lines screen's eSIM detection, run under javac (NWP-20261019-07).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-08-18) decided that Nowhere never deletes an eUICC profile and the
# gate DETECTS a leftover one and says so. Whether an eSIM row is marked, whether a switched-off profile is counted, and
# whether the note keeps to decided wording are decided by pure static helpers in ChooserActivity.java; nothing else
# executes them off a device. core/chooser/tests/esim-note/run.sh lifts them into a plain class and runs EsimCases; the
# PINS below check the wiring that cases cannot see (the isEmbedded read, the off-UI-thread count, the arguments).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (a suite that quietly passes because its tool is missing reads
# exactly like one that ran). javac comes from PATH, else from the build host's JDK below; the version is printed first.
#
#   bash test-esim-note-java.sh            # the cases and the pins
#   bash test-esim-note-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
RUN="$root/core/chooser/tests/esim-note/run.sh"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its pins" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# suite <ChooserActivity.java> -> 0 pass, 1 a case or a pin failed, 2 a helper did not extract, 3 the lifted class did
# not compile. Only 1 may convict a mutant.
suite() {
  local f="$1" b
  # P1: activeSims reads isEmbedded
  b=$(body "$f" 'private java.util.List<SimInfo> activeSims()')
  [[ "$b" == *'s.embedded = si.isEmbedded();'* ]] || { echo "  PIN P1 activeSims no longer reads isEmbedded" >&2; return 1; }
  # P2: inactiveEmbeddedCount reads the available list inside a try and counts through the helper
  b=$(body "$f" 'private int inactiveEmbeddedCount(')
  [[ "$b" == *'try {'*'getAvailableSubscriptionInfoList()'* && "$b" == *'countInactiveEmbedded('* ]] || {
    echo "  PIN P2 inactiveEmbeddedCount does not read the available list in a try and count through the helper" >&2; return 1; }
  # P3: the sim-lines thread counts, and hands the count to fillSimRows
  b=$(awk '/new Thread\(\(\) -> \{/ { buf=""; on=1 } on { buf = buf $0 "\n" } on && /"nowhere-sim-lines"/ { print buf; exit }' "$f")
  [[ "$b" == *'inactiveEmbeddedCount('* && "$b" == *'fillSimRows(rows, sums, sims, inactiveEsims)'* ]] || {
    echo "  PIN P3 the nowhere-sim-lines thread does not count and pass inactiveEsims" >&2; return 1; }
  # P4: fillSimRows labels rows, notes with the passed count, and never reads the subscription service itself
  b=$(body "$f" 'private void fillSimRows(')
  [[ "$b" == *'simRowSummary(bound, s.embedded)'* ]] || { echo "  PIN P4 fillSimRows does not mark eSIM rows" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'exit(/esimNote\([^,()]*,\s*inactiveEsims\)/ ? 0 : 1)' || {
    echo "  PIN P4 fillSimRows' esimNote does not take inactiveEsims as its second argument" >&2; return 1; }
  [[ "$b" != *'inactiveEmbeddedCount('* && "$b" != *'getAvailableSubscriptionInfoList('* ]] || {
    echo "  PIN P4 fillSimRows reads the subscription service on the UI thread" >&2; return 1; }
  bash "$RUN" "$f"
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d m rc; d=$(mktemp -d); m="$d/ChooserActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the isEmbedded read removed"                  's/try \{ s\.embedded = si\.isEmbedded\(\); \} catch \(Throwable ig\) \{\}//' || fails=$((fails+1))
mut "M2 esimNote returns null always"                 's/(static String esimNote\(int activeEmbedded, int inactiveEmbedded\) \{\n)/$1        if (true) return null;\n/' || fails=$((fails+1))
mut "M3 the thread passes a literal 0"                's/fillSimRows\(rows, sums, sims, inactiveEsims\)/fillSimRows(rows, sums, sims, 0)/' || fails=$((fails+1))
mut "M4 fillSimRows passes 0 to esimNote"             's/esimNote\(activeEsims, inactiveEsims\)/esimNote(activeEsims, 0)/' || fails=$((fails+1))
mut "M5 the never-deletes sentence dropped"           's/ Nowhere never deletes one\.//' || fails=$((fails+1))
mut "M6 the count moves into fillSimRows (UI thread)" 's/esimNote\(activeEsims, inactiveEsims\)/esimNote(activeEsims, inactiveEmbeddedCount(new java.util.HashSet<Integer>()))/' || fails=$((fails+1))
mut "M7 simRowSummary called with false"              's/simRowSummary\(bound, s\.embedded\)/simRowSummary(bound, false)/' || fails=$((fails+1))
mut "M8 the embedded arm returns bound unchanged"     's/return embedded \? "eSIM · " \+ bound : bound;/return bound;/' || fails=$((fails+1))
mut "M9 countInactiveEmbedded ignores activeSubIds"   's/if \(embedded\[i\] && !activeSubIds\.contains\(subIds\[i\]\)\) n\+\+;/if (embedded[i]) n++;/' || fails=$((fails+1))
mut "M10 countInactiveEmbedded ignores embedded"      's/if \(embedded\[i\] && !activeSubIds\.contains\(subIds\[i\]\)\) n\+\+;/if (!activeSubIds.contains(subIds[i])) n++;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
