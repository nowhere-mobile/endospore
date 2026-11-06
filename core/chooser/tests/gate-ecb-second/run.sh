#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261114-02 (Q044): lift NowhereInCallService.secondCall and its three constants
# (pure, java.lang only) into a plain class and run Cases against them: all eight (incoming, current, ringing)
# combinations give the decided action, and an emergency call on screen is never displaced.
# JAVAC and JAVA name the tools (default: javac, java on PATH); core/vendor-common/bin/test-gate-ecb-second-java.sh
# resolves them and is what CI runs. Exit status: 0 every case passed; 1 a case failed; 2 cannot run (a tool, a file
# or a member missing); 3 the lifted members do not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
SRC="$CH/src/com/nowhere/chooser/NowhereInCallService.java"
for f in "$SRC" "$here/Cases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
consts="REJECT_NEW TAKE_REJECT_CURRENT TAKE_END_ON_ANSWER"
# lift <method> <file>: from the method's declaration ('static', then its name and '(' -- never a call site) to the
# brace closing it, with any access modifier dropped.
lift() {
  awk -v m="$1" '
    !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "[(]") { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$2" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
{
  echo "final class Lifted {"
  for k in $consts; do
    grep -E "^[ \t]*(private )?static final int $k = [^;]*;" "$SRC" | sed -E 's/^([ \t]*)(private )?static /\1static /'
  done
  lift secondCall "$SRC"
  echo "}"
} > "$D/Lifted.java"
for k in $consts; do
  n=$(grep -cE "^[ \t]*static final int $k = " "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: constant $k found $n time(s), want 1" >&2; exit 2; }
done
n=$(grep -cE "^[ \t]*static int secondCall[(]" "$D/Lifted.java" || true)
[ "$n" = 1 ] || { echo "run.sh: secondCall found $n time(s), want 1" >&2; exit 2; }
cp "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/Cases.java" || { echo "run.sh: the lifted members do not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" Cases
