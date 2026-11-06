#!/usr/bin/env bash
# run.sh <UnarchiveService.java> -- NWP-20261012-04: lift the pure "what does this Auto app need" decision out of the
# chooser and run PendingCases against it under plain javac/java. autoAction and splitAuto use only java.lang and
# java.util, so the class compiles with no Android SDK. The compiler and VM come from $JAVAC / $JAVA (default: PATH);
# core/vendor-common/bin/test-install-heal.sh is the CI entry point and finds them.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = something the list
# names is missing from the source (never a silent skip: the cases would run against a class missing the very method
# they exist for); 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/UnarchiveService.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
consts="AUTO_WHOLE AUTO_INSTALL AUTO_RESTORE_ONLY AUTO_GROUP_DEP"
methods="autoAction splitAuto"
{
  echo "final class Lifted {"
  for c in $consts; do grep -E "^    static final int $c = [0-9]+;" "$SRC" || true; done
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC"
  done
  echo "}"
} > "$D/Lifted.java"
for c in $consts; do grep -q "static final int $c = " "$D/Lifted.java" || { echo "extraction missed $c" >&2; exit 2; }; done
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/PendingCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/PendingCases.java" || exit 3
"$JAVA" -cp "$D" PendingCases
