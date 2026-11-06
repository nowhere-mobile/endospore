#!/usr/bin/env bash
# run.sh <OtaNotes.java> -- NWP-20261012-03: compile the chooser's OtaNotes (pure Java, no Android types: it is
# compiled as it stands, nothing is lifted out of it) with OtaNotesCases and run them under plain javac/java. The
# compiler and VM come from $JAVAC / $JAVA (default: PATH); core/vendor-common/bin/test-ota-notes-java.sh is the CI
# entry point and finds them. Every temp file is under one directory, removed on exit, and java writes its own temp
# files there too (-Djava.io.tmpdir): the suite exports TMPDIR, so that directory is inside the suite's root.
#
# Exit codes: 1 = a case failed; 3 = the class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/OtaNotes.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp "$SRC" "$D/OtaNotes.java"
cp "$here/OtaNotesCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn -d "$D/out" "$D/OtaNotes.java" "$D/OtaNotesCases.java" 2>"$D/javac.err" \
  || { cat "$D/javac.err" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.OtaNotesCases
