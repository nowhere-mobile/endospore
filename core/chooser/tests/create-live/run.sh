#!/usr/bin/env bash
# run.sh <ChooserActivity.java> [<repo root>] -- NWP-20261116-09 (h46 #5): lift the gate's pure ERR-LIVE helpers (and,
# since NWP-20261117-11, the ERR-NAME one, createReplyBadName) out of the chooser and run CreateLiveCases against them under plain javac/java. Both helpers are private static and use only
# java.lang, so the lifted class compiles with no Android SDK. The repo root (default: four levels above this script)
# is where CreateLiveCases reads docs/product-decisions.md. JAVAC and JAVA name the tools (default: javac, java on
# PATH); core/vendor-common/bin/test-create-live-java.sh resolves them and is what CI runs.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java [repo root]}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
ROOTDIR="${2:-$(cd "$here/../../../.." && pwd)}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="createReplyLive createLiveText createReplyBadName"
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
cp "$here/CreateLiveCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/CreateLiveCases.java"
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" CreateLiveCases "$SRC" "$ROOTDIR"
