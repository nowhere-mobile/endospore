#!/usr/bin/env bash
# run.sh <AppFilter.java> -- NWP-20261016-48: compile the chooser's AppFilter (pure Java, no Android types: it is
# compiled as it stands, nothing is lifted out of it) with AppFilterCases and run them under plain javac/java. The
# compiler and VM come from $JAVAC / $JAVA (default: PATH); core/vendor-common/bin/test-app-filter-java.sh is the CI
# entry point and finds them.
#
# Exit codes: 1 = a case failed; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/AppFilter.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp "$SRC" "$D/AppFilter.java"
cp "$here/AppFilterCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn -d "$D/out" "$D/AppFilter.java" "$D/AppFilterCases.java" 2>"$D/javac.err" \
  || { cat "$D/javac.err" >&2; exit 3; }
"$JAVA" -cp "$D/out" com.nowhere.chooser.AppFilterCases
