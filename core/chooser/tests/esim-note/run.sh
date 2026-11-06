#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261019-07: lift the pure eSIM helpers out of the chooser and run EsimCases
# against them under plain javac/java. Every helper listed is static and uses only java.lang / java.util, so the class
# compiles with no Android SDK. The compiler and VM come from $JAVAC / $JAVA (default: PATH);
# core/vendor-common/bin/test-esim-note-java.sh is the CI entry point and finds them.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = a helper the list
# names is missing from the source (never a silent skip); 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="simRowSummary esimNote countInactiveEmbedded"
{
  echo "final class Lifted {"
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "static ") && index($0, " " m "(") && !index($0, "=") && !index($0, "return") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC" | sed 's/private static/static/'
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/EsimCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/EsimCases.java" || exit 3
"$JAVA" -Dfile.encoding=UTF-8 -cp "$D" EsimCases
