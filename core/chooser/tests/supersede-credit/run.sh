#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261016-47: lift the gate's pure supersede-warning helpers out of the chooser and
# run SupersedeCreditCases against them under plain javac/java. Every helper listed is private static and uses only
# java.lang, so the lifted class compiles with no Android SDK. The same file supplies the wiring the cases check.
# JAVAC and JAVA name the tools (default: javac, java on PATH); core/vendor-common/bin/test-supersede-credit-java.sh
# resolves them and is what CI runs. SC_TMP names the directory to make its own temp dir in (the caller's one temp root,
# so nothing is left in $TMPDIR); javac and java both get -Djava.io.tmpdir inside it.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = a helper the list
# names is missing from the source (never a silent skip); 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${SC_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
methods="parkedCreditProbeDue parkedCreditLost supersedeLossTitle supersedeLossText supersedeWarnExpired parseColdLock parkedSessionStill"
{
  echo "final class Lifted {"
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC" | sed 's/private static/static/'
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/SupersedeCreditCases.java" "$D/"
"$JAVAC" -J-Djava.io.tmpdir="$D" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/SupersedeCreditCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" SupersedeCreditCases "$SRC"
