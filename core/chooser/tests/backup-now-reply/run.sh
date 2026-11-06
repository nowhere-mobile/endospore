#!/usr/bin/env bash
# run.sh <BackupNowReply.java> <ReplyCopy.java> -- NWP-20261029-12: compile the pure reply decision directly with its
# cases and run them. $JAVAC / $JAVA default to PATH; test-backup-now-reply-java.sh is the CI entry point.
# Exit codes: 1 = a case failed; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh BackupNowReply.java ReplyCopy.java}"
RC="${2:?usage: run.sh BackupNowReply.java ReplyCopy.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/BackupNowReply.java"
cp "$RC" "$D/com/nowhere/chooser/ReplyCopy.java"
# The cases live in the default package, so they reach the package-private classes through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/BackupNowReplyCases.java" > "$D/com/nowhere/chooser/BackupNowReplyCases.java"
"$JAVAC" -J-Djava.io.tmpdir="$D" -d "$D/out" "$D"/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.BackupNowReplyCases || exit 1
