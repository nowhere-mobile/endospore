#!/usr/bin/env bash
# run.sh <SignInTrace.java> -- NWP-20261203-04: compile SignInTrace directly (pure java.lang / java.util) with
# SignInTraceCases and run them. $JAVAC / $JAVA default to PATH; core/vendor-common/bin/test-signin-trace-java.sh is
# the CI entry point. Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/SignInTrace.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/SignInTrace.java"
cp "$here/SignInTraceCases.java" "$D/com/nowhere/chooser/SignInTraceCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/SignInTrace.java" \
  "$D/com/nowhere/chooser/SignInTraceCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.SignInTraceCases || exit 1
