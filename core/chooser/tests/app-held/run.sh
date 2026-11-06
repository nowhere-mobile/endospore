#!/usr/bin/env bash
# run.sh <AppHeld.java> -- NWP-20261015-28: compile AppHeld's Context-free rules with AppHeldCases under plain javac/java.
# AppHeld names android types outside the region between "BEGIN pure rules" and "END pure rules", so only that region
# is lifted, byte for byte, into a class of the same name; the cases run against it. $JAVAC / $JAVA select the tools.
#
# Its temp dir nests under the suite's $W, and java.io.tmpdir is pinned to it, so the cases' temp files go there too
# (NWP-20261111-19).
#
# Exit codes: 1 = a case failed; 3 = it did not compile; 4 = the region markers are missing.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/AppHeld.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/src"
{
  echo "package com.nowhere.chooser;"
  echo "final class AppHeld {"
  awk '/\(BEGIN pure rules\)/ { on = 1 } on { print } /\(END pure rules\)/ { on = 0 }' "$SRC"
  echo "}"
} > "$D/src/AppHeld.java"
n=$(grep -c 'pure rules' "$D/src/AppHeld.java" || true)
[ "$n" = 2 ] || { echo "FAIL: the BEGIN/END pure rules markers are not both in $SRC" >&2; exit 4; }
cp "$here/AppHeldCases.java" "$D/src/"
"$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn -d "$D/out" "$D/src/AppHeld.java" "$D/src/AppHeldCases.java" 2>"$D/javac.err" \
  || { cat "$D/javac.err" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/out" com.nowhere.chooser.AppHeldCases
