#!/usr/bin/env bash
# test-billing-copy-java.sh [--mutate] -- the Profile screen's plan summary (formatBilling, formatCoverage), run under
# javac (NWP-20261016-39).
#
# WHY THIS IS COMMITTED. formatBilling's comments carry five rules no test executed: -1 (not asked) is not 0 (the
# gateway holds no plan); a restored profile with no local wallet but entitled > 0 is told the plan is active on the
# servers; a funded-but-not-activated purchase is not "Not leased yet"; epochsec defaults to the old weekly 604800 on
# purpose; the "servers don't show this plan" arm fires only for `through >= now && entitled == 0`. A regression in
# any of them is wrong money copy on the one screen a paying customer reads. core/chooser/tests/billing-copy/run.sh
# lifts the methods by signature and runs BillingCases against them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites. If a slice edits
# formatBilling's copy it must update BillingCases' expected substrings in the same slice.
#
# NWP-20261028-04: a free profile whose occupied total (GET-USAGE, every scope together) is over 1 GB is told it is over
# the free allowance (freeTierLine), not that it "roams within the free allowance, at no cost"; the first paint (entitled
# -1) says size only. Mutants F1-F5: the threshold, the first paint accusing, the decimal GB, the old line when over,
# and the GET-USAGE repaint removed.
#
# NWP-20261103-10: a lapsed plan, or one the servers don't show, says "Read-only" only when the occupied total is over the
# free allowance (addAllowanceLine, Q082); under it, that the profile can keep adding up to 1 GB; unmeasured, nothing.
# Mutants Q1-Q4: the threshold inverted, unmeasured treated as over, the expired arm's fixed Read-only, the entitled-0
# arm's "but not add" under the allowance.
#
# NWP-20261103-11 (Q147): while a rebind is outstanding inside the cooldown (the agent's `moving=<unix>`), the
# entitled-0 arm says the plan is moving instead of "servers don't show"; absent/unparsable moving= changes nothing and
# the first paint never reaches the arm. Mutants G1-G3: moving ignored, moving on the first paint, moving on entitled > 0.
#
# NWP-20261117-22: before the gateway answers (entitled -1, which an unreachable gateway also keeps), a live wallet term
# is stated only as "N GB plan — bought through <date>": no days left, no "Expires", no wallet sentence (the rule of
# NWP-20260918-08/-09: a pending state never renders as a settled answer). Mutants P1-P3: the past-tense arm never
# taken, the wallet sentence back on the first paint, the past-tense arm also for a plan the gateway shows.
#
#   bash test-billing-copy-java.sh            # the cases
#   bash test-billing-copy-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# suite <ProfileActivity.java> -> run.sh's code: 0 pass, 1 a case failed (only this may convict a mutant), 2 a method
# did not extract, 3 the lifted class did not compile.
suite() { TMPDIR="$W" bash "$RUN" "$1"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> [<lines-that-must-change>]
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/ProfileActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
  if [ "$changed" -ne "${3:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${3:-1}"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 no-wallet arm fires on entitled >= 0 (0 and -1 collapse)" 's/if \(entitled > 0\) \{/if (entitled >= 0) {/' || fails=$((fails+1))
mut "M2 server-does-not-show fires on entitled <= 0"            's/else if \(through >= nowEp && entitled == 0\)/else if (through >= nowEp \&\& entitled <= 0)/' || fails=$((fails+1))
mut "M3 epochsec defaults to daily 86400"                       's/epochsec = 604800, deadline/epochsec = 86400, deadline/' || fails=$((fails+1))
mut "M4 the pending arm loses its pending > 0 (first occurrence only)" 's/if \(through <= 0 && pending > 0\) \{/if (through <= 0) {/' || fails=$((fails+1))
mut "M5 coverage names the free tier only on entitled < 0"      's/if \(entitled <= 0\) \{\n            s\.append\(" \(free tier\)"\)/if (entitled < 0) {\n            s.append(" (free tier)")/' || fails=$((fails+1))
mut "M6 the waiting guard is reduced to waiting"                's/if \(waiting && !\(through <= 0 && pending > 0\)\) \{/if (waiting) {/' || fails=$((fails+1))
mut "F1 exactly 1 GiB counts as over"                           's/if \(occupied <= FREE_ALLOWANCE_BYTES\) \{/if (occupied < FREE_ALLOWANCE_BYTES) {/' || fails=$((fails+1))
mut "F2 the first paint (entitled -1) accuses"                  's/if \(entitled != 0\) \{/if (false) {/' || fails=$((fails+1))
mut "F3 the allowance is decimal 1 GB"                          's/FREE_ALLOWANCE_BYTES = 1L << 30;/FREE_ALLOWANCE_BYTES = 1000000000L;/' || fails=$((fails+1))
mut "F4 the old line is returned when over"                     's/if \(occupied <= FREE_ALLOWANCE_BYTES\) \{/if (true) {/' || fails=$((fails+1))
mut "F5 the GET-USAGE thread no longer repaints"                's/if \(lastBill\[0\] != null\) body\.setText\(formatBilling\(lastBill\[0\], lastEnt\[0\]\)\);/if (lastBill[0] != null) { }/' || fails=$((fails+1))
mut "Q1 the add-allowance threshold inverted" 's/if \(occupied > FREE_ALLOWANCE_BYTES\) return/if (occupied <= FREE_ALLOWANCE_BYTES) return/' || fails=$((fails+1))
mut "Q2 an unmeasured total is treated as over" 's/if \(occupied < 0\) return "";/if (occupied < 0) occupied = FREE_ALLOWANCE_BYTES + 1;/' || fails=$((fails+1))
mut "Q3 the expired arm still says Read-only, whatever the size" 's/final String lapsedAdd = addAllowanceLine\(occupiedBytes\);/final String lapsedAdd = "Read-only - you can view and delete, but not add.";/' || fails=$((fails+1))
mut "Q4 the entitled-0 arm still says but not add under the allowance" 's/final String strangerAdd = addAllowanceLine\(occupiedBytes\);/final String strangerAdd = "You can view and delete, but not add.";/' || fails=$((fails+1))
mut "G1 moving= is ignored" 's/case "moving":   moving = v;   break;/case "moving":   break;/' || fails=$((fails+1))
mut "G2 moving shown on the first paint (entitled -1 reaches the arm)" 's/else if \(through >= nowEp && entitled == 0\)/else if (through >= nowEp \&\& (entitled == 0 || (entitled < 0 \&\& moving > 0)))/' || fails=$((fails+1))
mut "G3 the moving sentence also on a plan the gateway shows (entitled > 0)" 's/else if \(through >= nowEp && entitled == 0\)/else if (through >= nowEp \&\& (entitled == 0 || (entitled > 0 \&\& moving > 0)))/' || fails=$((fails+1))
mut "P1 the first-paint past-tense arm is never taken" 's/else if \(through >= nowEp && entitled < 0\)/else if (through >= nowEp \&\& entitled < -1)/' || fails=$((fails+1))
mut "P2 the wallet sentence is back on the first paint" 's/if \(!\(through >= nowEp && entitled <= 0\)\)/if (!(through >= nowEp \&\& entitled == 0))/' || fails=$((fails+1))
mut "P3 the past-tense arm also for a plan the gateway shows (entitled > 0)" 's/else if \(through >= nowEp && entitled < 0\)/else if (through >= nowEp \&\& entitled != 0)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
