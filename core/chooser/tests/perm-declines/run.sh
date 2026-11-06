#!/usr/bin/env bash
# run.sh <PermDeclines.java> -- NWP-20261012-05: lift PermDeclines' PURE block (flagWord, wordBits, plainName, parse,
# softenedDecline, and NWP-20261012-08's smsRolePerm, exceptSmsRole, onlySmsRole, smsCandidates, oldDeclineWord,
# keptDecline: java.lang and java.util only) into a plain class and run Cases against it under
# javac/java, no Android SDK. The compiler and VM come from $JAVAC / $JAVA (default: PATH);
# core/vendor-common/bin/test-perm-declines-java.sh is the CI entry point and finds them.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = the PURE block or a
# method in it is missing (never a silent skip); 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/PermDeclines.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
{
  echo "final class Lifted {"
  awk '/^    \/\/ ---- PURE /{on=1; next} /^    \/\/ ---- END PURE ----$/{on=0} on' "$SRC"
  echo "}"
} > "$D/Lifted.java"
for m in "static String flagWord(" "static int wordBits(" "static boolean plainName(" "static java.util.List<String[]> parse(" "static String softenedDecline(" \
         "static boolean smsRolePerm(" "static java.util.List<String[]> exceptSmsRole(" \
         "static java.util.List<String[]> onlySmsRole(" "static java.util.List<String> smsCandidates(" \
         "static String oldDeclineWord(" "static String keptDecline("; do
  grep -qF "$m" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }
done
cp "$here/Cases.java" "$D/"
"$JAVAC" -J-Djava.io.tmpdir="$D" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/Cases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" Cases
