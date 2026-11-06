#!/usr/bin/env bash
# run.sh <KeepHeadroom.java> -- NWP-20261104-07: compile the pure KEEP-HEADROOM request/verdict codec directly with its
# cases and run them. $JAVAC / $JAVA default to PATH; core/vendor-common/bin/test-keep-headroom-java.sh is the CI entry.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh KeepHeadroom.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/KeepHeadroom.java"
# The cases live in the default package, so they reach the package-private class through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/KeepHeadroomCases.java" > "$D/com/nowhere/chooser/KeepHeadroomCases.java"
"$JAVAC" -J-Djava.io.tmpdir="$D" -d "$D/out" "$D"/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.KeepHeadroomCases || exit 1
