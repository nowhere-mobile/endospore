#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261101-10: lift the gate's pure staged-claim helpers out of the chooser and
# run StagedClaimCases against them under plain javac/java. Both helpers are private static and use only java.lang,
# so the lifted class compiles with no Android SDK. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-staged-claim-java.sh resolves them and is what CI runs.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="createReplyStaged createHeldCreditText"
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
cp "$here/StagedClaimCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/StagedClaimCases.java"
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" StagedClaimCases "$SRC"
