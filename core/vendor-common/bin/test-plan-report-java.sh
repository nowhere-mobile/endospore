#!/usr/bin/env bash
# test-plan-report-java.sh [--mutate] -- NWP-20261118-17: when the Storage screen offers "Report this" under its plan
# text. Runs core/chooser/tests/plan-report: the chooser's pure PlanReport, compiled against its cases ALONE and
# EXECUTED, plus source checks that the Storage thread calls it and that formatBilling still reads moving=.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of PlanReport.java, each of which must FAIL a named case, and against
# one broken copy of ProfileActivity.java, which the source check s1 must refuse. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-plan-report-java.sh            # the cases and the source checks
#   bash test-plan-report-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-plan-report-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/plan-report/run.sh" "$1" "$(mktemp -d -p "$W")"; }
run "$ROOT" || { echo "FAILED"; exit 1; }

# src_checks <root>: the Storage thread decides through PlanReport.offer alone, planIsLive is gone, and formatBilling
# still reads moving= -- the field the button's rule and the moving notice must both read.
src_checks() {
  local pa bad guard nbtn hit fb
  pa="$1/$CH/ProfileActivity.java"
  bad=0
  nbtn=$(grep -cF 'reportPlan[0] = secondaryButton("Report this"' "$pa" || true)
  guard=$(grep -B1 -F 'reportPlan[0] = secondaryButton("Report this"' "$pa" | head -1 || true)
  if [ "$nbtn" = 1 ] && [[ $guard == *"PlanReport.offer("* && $guard != *"ent == 0"* ]]; then
    echo "ok   s1 the Report this button is guarded by PlanReport.offer alone"
  else echo "FAIL s1 the Report this button (found $nbtn) must be guarded by PlanReport.offer( and no ent == 0: $guard"; bad=1; fi
  hit=$(grep -n 'planIsLive' "$pa" || true)
  if [ -z "$hit" ]; then echo "ok   s2 ProfileActivity holds no planIsLive"
  else echo "FAIL s2 ProfileActivity still holds planIsLive: $hit"; bad=1; fi
  fb=$(awk '/private CharSequence formatBilling\(/{f=1} f{print} f&&/^    }$/{exit}' "$pa")
  if [ -n "$fb" ] && [[ $fb == *'case "moving":'* && $fb == *'if (moving > 0)'* ]]; then
    echo "ok   s3 formatBilling still reads moving="
  else echo "FAIL s3 formatBilling no longer reads moving= -- PlanReport.offer and the moving notice must read the same field"; bad=1; fi
  return "$bad"
}
src_checks "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr over PlanReport.java> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  f="$d/$CH/PlanReport.java"
  cp "$ROOT/$CH/PlanReport.java" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/PlanReport.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
smut() { # smut <label> <perl-expr over ProfileActivity.java> <source check the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  f="$d/$CH/ProfileActivity.java"
  cp "$ROOT/$CH/ProfileActivity.java" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/ProfileActivity.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(src_checks "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the check '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "P1 the moving check removed" 's/\s*if \(moving > 0\) return false;//' \
  "moving=1700000000 is not reportable" || fails=$((fails+1))
mut "P2 through >= becomes through >" 's/through >= nowSec/through > nowSec/' \
  "through == the current epoch is reportable" || fails=$((fails+1))
mut "P3 entitled == 0 becomes entitled <= 0" 's/entitled == 0 &&/entitled <= 0 &&/' \
  "entitled -1 is not reportable" || fails=$((fails+1))
mut "P4 the weekly default becomes daily" 's/epochsec = 604800/epochsec = 86400/' \
  "no epochsec uses the weekly default" || fails=$((fails+1))
mut "P5 the OK prefix check removed" 's/ \|\| !billReply\.startsWith\("OK"\)//' \
  "a non-OK reply with a live through is not reportable" || fails=$((fails+1))
smut "A1 the guard back to ent == 0 alone" \
  's/PlanReport\.offer\(billReply, ent, System\.currentTimeMillis\(\) \/ 1000L\)/ent == 0/' \
  "s1" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
