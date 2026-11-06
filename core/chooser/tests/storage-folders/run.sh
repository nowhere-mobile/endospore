#!/usr/bin/env bash
# run.sh <StorageFolders.java> -- NWP-20261125-09: compile StorageFolders directly (pure Java, no android.*)
# with StorageFoldersCases and run it. $JAVAC / $JAVA default to PATH; test-storage-folders-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 2 = no source file; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/StorageFolders.java}"
[ -f "$SRC" ] || { echo "FAIL c0: no StorageFolders.java at $SRC"; exit 2; }
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/StorageFolders.java"
# The cases live in the default package, so they reach the package-private class through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/StorageFoldersCases.java" > "$D/com/nowhere/chooser/StorageFoldersCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/StorageFolders.java" \
  "$D/com/nowhere/chooser/StorageFoldersCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.StorageFoldersCases || exit 1
