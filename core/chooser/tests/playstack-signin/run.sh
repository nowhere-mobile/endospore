#!/usr/bin/env bash
# run.sh <repo-root> [<outdir>] -- NWP-20261201-06: compile the chooser's pure PlayStackSignIn (java.* only, no Android
# SDK) with PlayStackSignInCases ALONE, and run them. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-playstack-signin-java.sh resolves them and is what CI runs. <outdir> receives the class
# files; without it a private directory is made and removed on exit.
set -euo pipefail
ROOT="${1:?usage: run.sh path/to/repo [outdir]}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${2:-}" ]; then
  D=$2
else
  D=$(mktemp -d)
  trap 'rm -rf "$D"' EXIT
fi
"$JAVAC" -encoding UTF-8 -d "$D" "$ROOT/core/chooser/src/com/nowhere/chooser/PlayStackSignIn.java" "$here/PlayStackSignInCases.java"
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" com.nowhere.chooser.PlayStackSignInCases
