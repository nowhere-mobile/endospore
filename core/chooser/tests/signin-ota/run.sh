#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261101-12: lift the gate's update-hold helpers out of the chooser and run
# SigninOtaCases against them under plain javac/java. NWP-20261117-12 (#30) adds the ERR-NOTMPFS predicate and its text.
# The helpers are private static and use only java.lang.
# JAVAC and JAVA name the tools; core/vendor-common/bin/test-signin-ota-java.sh resolves them and is what CI runs.
#
# Exit codes: 1 = a case failed; 2 = a member the list names is missing from the source; 3 = did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="signInHeldForUpdate replyIsOtaRefusal replyIsNoTmpfs"
{
  echo "final class Lifted {"
  grep -E '^    private static final String UPDATE_INSTALLING_TEXT =' -A1 "$SRC" | sed 's/private static final/static final/'
  grep -E '^    private static final String NO_TMPFS_TEXT = ' "$SRC" | sed 's/private static final/static final/' || true
  for m in $methods; do
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC" | sed 's/private static/static/'
  done
  echo "}"
} > "$D/Lifted.java"
grep -q "UPDATE_INSTALLING_TEXT" "$D/Lifted.java" || { echo "extraction missed UPDATE_INSTALLING_TEXT" >&2; exit 2; }
grep -q "NO_TMPFS_TEXT" "$D/Lifted.java" || { echo "extraction missed NO_TMPFS_TEXT" >&2; exit 2; }
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/SigninOtaCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/SigninOtaCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" SigninOtaCases "$SRC"
