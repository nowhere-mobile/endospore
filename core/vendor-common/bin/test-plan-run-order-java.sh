#!/usr/bin/env bash
# test-plan-run-order-java.sh [--mutate] -- Storage shows the plans in run order (NWP-20261120-10, #90).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-10-30, harvest 48 #9: the gateway sends the plans in run order
# with size and end date, and Storage shows them ("50 GB to Jan 21, then 10 GB to Jul 20"). The agent ships the live
# steps as GET-BILLING's plans=; PlanRunOrder (pure, java.lang / java.util / java.text) writes the line, and
# ProfileActivity.formatBilling appends it in its live arm only, where the gateway has answered and holds the plan
# (entitled > 0). This compiles PlanRunOrder with its cases and the three other GET-BILLING parsers (PlanChoice,
# PlanReport, PlanExpiry), which must answer the same with and without the token, then runs the billing-copy cases
# (core/chooser/tests/billing-copy/run.sh) against the lifted formatBilling: the line on entitled > 0, never on the
# first paint (entitled -1) or entitled 0.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-plan-run-order-java.sh            # the cases
#   bash test-plan-run-order-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CASES="$root/core/chooser/tests/plan-run-order/PlanRunOrderCases.java"
RUN="$root/core/chooser/tests/billing-copy/run.sh"
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
[ -f "$CASES" ] && [ -f "$RUN" ] || { echo "FAIL: missing $CASES or $RUN" >&2; exit 2; }

# suite <dir holding PlanRunOrder.java and ProfileActivity.java> -> 0 pass, 1 a case failed, 3 did not compile/extract.
suite() {
  local dir="$1" d out rc f
  [ -f "$dir/PlanRunOrder.java" ] || { echo "  FAIL  PlanRunOrder.java does not exist (Storage's run-order line is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$dir/PlanRunOrder.java" "$d/src/com/nowhere/chooser/PlanRunOrder.java"
  for f in PlanChoice PlanReport PlanExpiry; do cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/$f.java"; done
  cp "$CASES" "$d/src/com/nowhere/chooser/PlanRunOrderCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PlanRunOrderCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] || return 1
  # run.sh passes -Djava.io.tmpdir to its own java, inside its own mktemp under TMPDIR=$W.
  out=$(TMPDIR="$W" JAVAC="$JAVAC" JAVA="$JAVA" bash "$RUN" "$dir/ProfileActivity.java" "$dir/PlanRunOrder.java" 2>&1); rc=$?
  echo "$out"
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 3 ;;
  esac
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that is inert or does not compile proves nothing)"
# mutate <label> <file name> <perl-expr>
mutate() {
  local label="$1" file="$2" expr="$3" d rc
  d=$(mktemp -d -p "$W") || return 1
  cp "$SRC"/PlanRunOrder.java "$SRC"/ProfileActivity.java "$d/"
  if ! perl -0pi -e "$expr" "$d/$file"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC/$file" "$d/$file"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$d" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  convicted $label"; return 0 ;;
    0) echo "  SURVIVED  $label"; return 1 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
R=PlanRunOrder.java; P=ProfileActivity.java
mutate "C1 the line with one step" $R 's/if \(steps\.length < 2\) return null;/if (steps.length < 1) return null;/' || fails=$((fails+1))
mutate "C2 shown on the first paint" $P 's/(\/\/ NWP-20261117-22: NOT ASKED YET.*?sb\.append\(" — bought through "\)[^\n]*\n)/$1            final String runOrder = PlanRunOrder.line(r, df);\n            if (runOrder != null) sb.append("\\n").append(runOrder);\n/s' || fails=$((fails+1))
mutate "C3 through instead of through + 1" $R 's/\(through \+ 1\) \* epochsec \* 1000L/through * epochsec * 1000L/' || fails=$((fails+1))
mutate "C4 steps reversed" $R 's/for \(int i = 0; i < steps\.length; i\+\+\) \{/for (int i = steps.length - 1; i >= 0; i--) {/; s/if \(i > 0\) sb\.append\(", then "\);/if (i < steps.length - 1) sb.append(", then ");/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
