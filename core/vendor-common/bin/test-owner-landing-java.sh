#!/usr/bin/env bash
# test-owner-landing-java.sh [--mutate] -- NWP-20261129-12: an owner action answered after owner mode ended opens no
# owner screen, and a confirm dialog left open after it ended does nothing.
# Runs core/chooser/tests/owner-landing: OwnerLanding compiled and EXECUTED, its eight sites read from ChooserActivity's
# source (tests/owner-landing/run.sh says how).
#
# WHY THIS IS COMMITTED. Slice D's onPause rule ends owner mode on a screen-off. Six completions opened an owner screen
# whenever their answer arrived, and every one of those screens leads back to the owner menu, which asks no passphrase.
# Repair's and Unbind's confirm dialogs stay over the gate after a screen-off, and their buttons still acted. Each guard
# is one line a later edit can drop without breaking a build, and the start read works only on the UI thread at the tap.
#   P1  each of the six landing lambdas starts with the guard
#   P2  Repair's and Unbind's positive buttons start with the guard
#   P3  each owned is read once, before its worker, and before its dialog for Repair and Unbind
#   P4  OwnerLanding.lands( occurs exactly eight times in ChooserActivity
#   P5  (control) buildReportScreen and its answer, renderGateReportResult, keep their isAttachedToWindow guards
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies. Each copy must fail the case it names. A copy that does not apply, does not
# change the file or does not compile is a failure, never a pass.
#
#   bash test-owner-landing-java.sh            # the cases
#   bash test-owner-landing-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/owner-landing/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-owner-landing-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
TMPDIR="$W" bash "$RUN" "$CH"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by the case it names) =="
  mutate(){ # mutate <label> <the FAIL line it must draw> <file name> <perl script>
    local label="$1" want="$2" name="$3" script="$4" f r out
    rm -rf "$W/c"; mkdir -p "$W/c/src/com/nowhere/chooser"
    cp "$CH/src/com/nowhere/chooser/OwnerLanding.java" "$CH/src/com/nowhere/chooser/ChooserActivity.java" "$W/c/src/com/nowhere/chooser/"
    f="$W/c/src/com/nowhere/chooser/$name"
    if ! perl -0pi -e "$script" "$f" 2>"$W/err"; then no "MUTATION BROKEN (perl): $label"; return; fi
    if cmp -s "$f" "$CH/src/com/nowhere/chooser/$name"; then no "MUTATION INERT: $label"; return; fi
    out=$(TMPDIR="$W" bash "$RUN" "$W/c" 2>&1); r=$?
    case "$r" in
      1) case "$out" in
           *"FAIL  $want"*) ok "convicted: $label" ;;
           *) no "CONVICTED BY THE WRONG CASE: $label -- no FAIL line for: $want" ;;
         esac ;;
      0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $label" ;;
    esac
  }
  A=ChooserActivity.java
  G='if \(!OwnerLanding[^\n]*'
  O='final boolean owned = ownerSessionPass != null;'
  mutate "L1 lands is always true" "lands(true, false)" OwnerLanding.java \
    's/return !startedInOwnerMode \|\| ownerModeNow;/return true;/ or die'
  mutate "L2 Clear all's landing guard removed" "P1 Clear all" $A \
    's/(daemonCmd\("CLEAR-OWNER-INBOX"\);.*?runOnUiThread\(\(\) -> \{)\n[ ]*'"$G"'/$1/s or die'
  mutate "L3 Delete's landing guard removed" "P1 Delete" $A \
    's/(daemonCmd\("DELETE-OWNER-ITEM\\n" \+ id\);.*?runOnUiThread\(\(\) -> \{)\n[ ]*'"$G"'/$1/s or die'
  mutate "L4 Repair's landing guard removed" "P1 Repair" $A \
    's/\n[ ]*'"$G"'(\n[ ]*if \(BindingsRepair\.ok\(r\)\) \{)/$1/ or die'
  mutate "L5 Unbind's landing guard removed" "P1 Unbind" $A \
    's/\n[ ]*'"$G"'(\n[ ]*if \(ok\) \{ setContentView\(buildBindingScreen\(\)\); return; \})/$1/ or die'
  mutate "L6 mark-mine's landing guard removed" "P1 Mark-mine" $A \
    's/\n[ ]*'"$G"'(\n[ ]*if \(BindingMarks\.mineBack\(r\)\))/$1/ or die'
  mutate "L7 Save's landing guard removed" "P1 Save" $A \
    's/\n[ ]*'"$G"'(\n[ ]*if \(r\.startsWith\("OK"\)\) \{\n[ ]*\/\/ #27)/$1/ or die'
  mutate "L8 Unbind's owned read moved into the dialog's button" "P3 Unbind" $A \
    's/(ICCID first"\); return; \}\n)[ ]*final boolean owned[^\n]*\n([ ]*new android\.app\.AlertDialog\.Builder\(this\)\n[ ]*\.setTitle\("Unbind this line\?"\))/$1$2/ or die; s/(\.setPositiveButton\("Unbind", \(d, w\) -> \{\n)/$1'"$O"'\n/ or die'
  mutate "L9 Repair's owned read moved into the worker" "P3 Repair" $A \
    's/(private void confirmRepairBindings\(TextView status\) \{\n)[ ]*final boolean owned[^\n]*\n/$1/ or die; s/(\.setPositiveButton\("Repair".*?new Thread\(\(\) -> \{\n)/$1'"$O"'\n/s or die'
  mutate "L10 Repair's dialog guard removed" "P2 Repair" $A \
    's/(\.setPositiveButton\("Repair", \(d, w\) -> \{)\n[ ]*'"$G"'/$1/ or die'
  mutate "L11 Unbind's dialog guard removed" "P2 Unbind" $A \
    's/(\.setPositiveButton\("Unbind", \(d, w\) -> \{)\n[ ]*'"$G"'/$1/ or die'
  mutate "L12 Save's landing guard moved after the toast" "P1 Save" $A \
    's/\n([ ]*'"$G"')(\n[ ]*if \(r\.startsWith\("OK"\)\) \{\n[ ]*\/\/ #27.*?"Store saved",\s*android\.widget\.Toast\.LENGTH_SHORT\)\.show\(\);)/$2\n$1/s or die'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
