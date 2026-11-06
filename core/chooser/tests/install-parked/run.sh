#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261101-15: lift the pure members behind "Install over a parked session asks
# first" out of the chooser and run InstallParkedCases against them under plain javac/java. JAVAC and JAVA name the
# tools; core/vendor-common/bin/test-install-parked-java.sh resolves them and is what CI runs.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="parseColdLock parkedCreditLost installAsksFirst installOverParkedTitle installOverParkedText"
{
  echo "final class Lifted {"
  for m in $methods; do
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC" | sed 's/private static/static/'
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/InstallParkedCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/InstallParkedCases.java"
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" InstallParkedCases "$SRC"
