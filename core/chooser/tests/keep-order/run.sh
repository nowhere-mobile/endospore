#!/usr/bin/env bash
# run.sh <KeepOrder.java> -- NWP-20261012-06: compile the chooser's KeepOrder (pure Java, no Android types: it is
# compiled as it stands, nothing is lifted out of it) with KeepOrderCases and run them under plain javac/java. The
# compiler and VM come from $JAVAC / $JAVA (default: PATH); core/vendor-common/bin/test-keep-order-java.sh is the CI
# entry point and finds them.
#
# Exit codes: 1 = a case failed; 2 = no temp dir; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/KeepOrder.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
# Every temp of this run, java.io.tmpdir included, lives inside $D.
D=$(mktemp -d) || exit 2
trap 'rm -rf "$D"' EXIT
cp "$SRC" "$D/KeepOrder.java"
cp "$here/KeepOrderCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn -d "$D/out" "$D/KeepOrder.java" "$D/KeepOrderCases.java" 2>"$D/javac.err" \
  || { cat "$D/javac.err" >&2; exit 3; }
# java.io.tmpdir is /tmp whatever TMPDIR says: point it at $D.
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.KeepOrderCases
