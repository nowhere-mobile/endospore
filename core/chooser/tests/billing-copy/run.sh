#!/usr/bin/env bash
# run.sh <ProfileActivity.java> -- NWP-20261016-39: lift formatBilling, formatCoverage and humanBytes verbatim out of
# the chooser (by signature) into a class with a `sessionType` field, and run BillingCases against it under plain
# javac/java. NWP-20261028-04 adds freeTierLine, the FREE_ALLOWANCE_BYTES declaration (lifted from the source by pattern,
# never redeclared here, so a mutant of the constant reaches the lifted code) and an `occupiedBytes` field, and pins that
# the GET-USAGE thread sets occupiedBytes and repaints through formatBilling. NWP-20261103-10 adds addAllowanceLine (what the
# profile may still add, from occupiedBytes: "Read-only" only over the free allowance, Q082). They use only java.text/java.util. $JAVAC / $JAVA come from the caller
# (core/vendor-common/bin/test-billing-copy-java.sh). NWP-20261120-10: formatBilling calls PlanRunOrder, so the optional
# second argument (default: the chooser's own PlanRunOrder.java) is compiled beside Lifted with its package line removed.
#
# Exit codes: 1 = a case failed; 2 = a method did not extract; 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ProfileActivity.java [path/to/PlanRunOrder.java]}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)  # the suite calls this with TMPDIR inside its own root
trap 'rm -rf "$D"' EXIT
PRO="${2:-$here/../../src/com/nowhere/chooser/PlanRunOrder.java}"
[ -f "$PRO" ] || { echo "EXTRACTION FAILED: $PRO is missing" >&2; exit 2; }
c=$(grep -c '^package com\.nowhere\.chooser;$' "$PRO" || true)
[ "$c" = 1 ] || { echo "EXTRACTION FAILED: PlanRunOrder.java has $c package lines, expected 1" >&2; exit 2; }
# Lifted is in the default package, which cannot see a package-private class of a named package.
grep -v '^package com\.nowhere\.chooser;$' "$PRO" > "$D/PlanRunOrder.java"
{
  echo "final class Lifted {"
  echo "    volatile String sessionType = \"\";"
  echo "    volatile long occupiedBytes = -1;"
  fre='^    private static final long FREE_ALLOWANCE_BYTES = [^;]+;$'
  c=$(grep -cE "$fre" "$SRC" || true)
  [ "$c" = 1 ] || { echo "EXTRACTION FAILED: FREE_ALLOWANCE_BYTES declared $c times, expected 1" >&2; exit 2; }
  grep -E "$fre" "$SRC" | sed 's/^    private static/    static/'
  for sig in "CharSequence formatCoverage(String e)" "static String humanBytes(long b)" \
             "static String freeTierLine(long occupied, long entitled)" \
             "static String addAllowanceLine(long occupied)" \
             "CharSequence formatBilling(String r, long entitled)"; do
    # from the method's signature line to the brace that closes it
    awk -v sig="$sig" '
      !on && index($0, sig) && index($0, "private ") && index($0, "{") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC" | sed 's/^    private static/    static/; s/^    private/    /'
  done
  echo "}"
} > "$D/Lifted.java"
for m in formatCoverage humanBytes freeTierLine addAllowanceLine formatBilling; do
  grep -q " $m(" "$D/Lifted.java" || { echo "EXTRACTION FAILED: $m is missing from the source" >&2; exit 2; }
done
grep -q " FREE_ALLOWANCE_BYTES = " "$D/Lifted.java" || { echo "EXTRACTION FAILED: FREE_ALLOWANCE_BYTES" >&2; exit 2; }
# the wiring the lifted methods cannot see: the GET-USAGE thread records the total and repaints the plan summary
blk=$(awk '!on && index($0, "loadUsage[0] = () -> new Thread(") {on=1} on {print} on && index($0, "}).start();") {exit}' "$SRC")
[ -n "$blk" ] || { echo "EXTRACTION FAILED: the GET-USAGE thread is missing" >&2; exit 2; }
case "$blk" in *"occupiedBytes = "*) ;; *) echo "  FAIL  pin: the GET-USAGE thread does not set occupiedBytes"; exit 1 ;; esac
case "$blk" in *"body.setText(formatBilling("*) ;; *) echo "  FAIL  pin: the GET-USAGE thread does not repaint through formatBilling"; exit 1 ;; esac
# a method that ran off the end of the file would not compile; one cut short would leave an unbalanced class
cp "$here/BillingCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/PlanRunOrder.java" "$D/BillingCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" BillingCases
