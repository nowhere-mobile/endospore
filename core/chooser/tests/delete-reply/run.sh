#!/usr/bin/env bash
# run.sh <ProfileActivity.java> -- NWP-20261014-30 / NWP-20261028-03: lift the pure DELETE-reply helpers out of the chooser and run
# DeleteReplyCases against them under plain javac/java (java.lang only, no Android SDK). The compiler and VM come from
# $JAVAC / $JAVA; core/vendor-common/bin/test-delete-reply-java.sh is the CI entry point and finds them.
#
# Exit codes: 1 = a case failed; 2 = a helper is missing from the source; 3 = the lifted class did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ProfileActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
methods="deleteSucceeded deleteFailCopy deleteSkipsStore"
{
  echo "final class Lifted {"
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC"
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/DeleteReplyCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/DeleteReplyCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" DeleteReplyCases
