#!/usr/bin/env bash
# run.sh <DaemonSocket.java> -- NWP-20261011-63: lift the pure one-line-reply helpers (verbOf, moreBuffered) out of the
# chooser's DaemonSocket and run Cases against them under plain javac/java. Both helpers use only java.lang and
# java.io, so the class compiles with no Android SDK. The compiler and VM come from $JAVAC / $JAVA (default: PATH);
# core/vendor-common/bin/test-daemon-reply-java.sh is the CI entry point and finds them.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = a helper the list
# names is missing from the source (never a silent skip: the cases would run against a class missing the very method
# they exist for); 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/DaemonSocket.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="verbOf moreBuffered"
{
  echo "import java.io.BufferedReader;"
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
cp "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/Cases.java" || exit 3
"$JAVA" -cp "$D" Cases
