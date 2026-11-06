#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261012-07: lift MissedCallReceiver.plan and its constants, and
# ChooserActivity.roamedDialerComponents (pure, java.lang only), into a plain class and run MissedCallCases against them,
# against the manifest entry, and against the wiring around them, which is pinned byte for byte.
# JAVAC and JAVA name the tools (default: javac, java on PATH); core/vendor-common/bin/test-missed-call-java.sh resolves
# them and is what CI runs. Exit status: 0 every case passed; 1 a case failed; 2 cannot run (a tool, a file or a helper
# missing); 3 the lifted helpers do not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
SRC="$J/MissedCallReceiver.java"
CA="$J/ChooserActivity.java"
[ -d "$here/pins" ] || { echo "run.sh: no pins dir: $here/pins" >&2; exit 2; }
for f in "$SRC" "$CA" "$J/NowhereInCallService.java" "$J/TelScrub.java" "$CH/AndroidManifest.xml" "$here/MissedCallCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
consts="ACTION EXTRA_COUNT DROP SCRUB_RESET"
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
    grep -E "^[ \t]*(private )?static final [A-Za-z]+ $k = [^;]*;" "$SRC" | sed -E 's/^([ \t]*)(private )?static /\1static /'
  done
  lift plan "$SRC"
  lift roamedDialerComponents "$CA"
  echo "}"
} > "$D/Lifted.java"
for k in $consts; do
  n=$(grep -cE "^[ \t]*static final [A-Za-z]+ $k = " "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: constant $k found $n time(s), want 1" >&2; exit 2; }
done
for m in plan roamedDialerComponents; do
  n=$(grep -cE "^[ \t]*static [^=;]* $m[(]" "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: helper $m found $n time(s), want 1" >&2; exit 2; }
done
cp "$here/MissedCallCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/MissedCallCases.java" || { echo "run.sh: the lifted helpers do not compile" >&2; exit 3; }
"$JAVA" -cp "$D" MissedCallCases "$CH/AndroidManifest.xml" "$J" "$here/pins"
