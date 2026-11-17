#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261204-12: lift GateNoticeEvidence's pure classifiers (countTags, grantName,
# receiverState, roleName, bucket; java.lang/java.util only) into a plain class, and run GateNoticeEvidenceCases against
# them and against the source of the reads that cannot run without Android.
# JAVAC and JAVA name the tools (default: javac, java on PATH); core/vendor-common/bin/test-gate-notice-evidence-java.sh
# resolves them and is what CI runs. Temps go under $W when the driver exports it, else under a root of this run's own.
# Exit status: 0 every case passed; 1 a case or pin failed; 2 cannot run (a tool, a file or a member missing);
# 3 the lifted members do not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
SRC="$J/GateNoticeEvidence.java"
for f in "$SRC" "$J/ChooserActivity.java" "$J/MissedCallReceiver.java" "$J/SmsDeliverReceiver.java" "$here/GateNoticeEvidenceCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
if [ -n "${W:-}" ] && [ -d "$W" ]; then
  D=$(mktemp -d -p "$W") || exit 2
else
  W=$(mktemp -d) || exit 2
  trap 'rm -rf "$W"' EXIT
  D=$(mktemp -d -p "$W") || exit 2
fi
members="countTags grantName receiverState roleName bucket"
# lift <method> <file>: from the method's declaration ('static', then its name and '(' -- never a call site) to the
# brace closing it, with any access modifier dropped.
lift() {
  awk -v m="$1" '
    !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "[(]") { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$2" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
}
{
  echo "final class Lifted {"
  for k in $members; do lift "$k" "$SRC"; done
  echo "}"
} > "$D/Lifted.java"
for k in $members; do
  n=$(grep -cE "^[ \t]*static [^=;]* $k[(]" "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: member $k found $n time(s), want 1" >&2; exit 2; }
done
cp "$here/GateNoticeEvidenceCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/GateNoticeEvidenceCases.java" || { echo "run.sh: the lifted members do not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$W" -cp "$D" GateNoticeEvidenceCases "$J"
