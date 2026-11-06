#!/usr/bin/env bash
# run.sh <chooser source dir> [<work dir>] -- NWP-20261110-12 (Q029): run TelPartialCases against the chooser's real
# SmsDeliverReceiver.holdMs and .partialLoss and TelArrival.Reply under plain javac/java. <chooser source dir> holds
# SmsDeliverReceiver.java and TelArrival.java (core/chooser/src/com/nowhere/chooser, or a mutant's copy of them).
# core/vendor-common/bin/test-tel-partial-java.sh resolves the JDK, runs the source checks and is what CI runs.
#
# The members are LIFTED BY NAME into one class per file and EXECUTED; a name that is missing, or found twice, stops the
# run (exit 2, EXTRACTION FAILED) rather than a stale copy passing. None of them touches an Android class, so there are
# no stubs.
#
# JAVAC and JAVA name the tools (default: javac, java on PATH). Exit status: 0 every case passed; 1 a case failed;
# 2 cannot run (a tool, a file or a member missing); 3 the lifted classes do not compile.
#
# The work dir, when given, is a fresh directory INSIDE the caller's own trapped root: run.sh then makes no root of its
# own and leaves the cleanup to that caller. Without one it makes and traps its own, so a hand run leaves nothing behind.
set -uo pipefail
SRC="${1:?usage: run.sh <chooser source dir> [<work dir>]}"
WORK="${2:-}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
SD="$SRC/SmsDeliverReceiver.java"; TA="$SRC/TelArrival.java"
for f in "$SD" "$TA" "$here/TelPartialCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
if [ -n "$WORK" ]; then
  W=$WORK; mkdir -p "$W" || exit 2
else
  W=$(mktemp -d) || exit 2
  trap 'rm -rf "$W"' EXIT
fi
mkdir -p "$W/src" "$W/classes" || exit 2

# lift <file> <method>...: each from its declaration (optional modifier, then 'static' -- never a call site) to the brace
# closing it
lift(){
  local f="$1" m; shift
  for m in "$@"; do
    awk -v m="$m" '
      !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "\\(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) on=0 }
    ' "$f" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
  done
}
{
  echo "final class TelArrival {"
  awk '
    !on && /^[ \t]*static final class Reply / { on=1; depth=0 }
    on { print; depth+=gsub(/\{/,"{")-gsub(/\}/,"}"); if (depth==0) on=0 }
  ' "$TA"
  echo "}"
} > "$W/src/TelArrival.java"
{ echo "final class SmsDeliverReceiver {"; lift "$SD" holdMs partialLoss; echo "}"; } > "$W/src/SmsDeliverReceiver.java"

bad=0
for m in holdMs partialLoss; do
  n=$(grep -cE "^[ \t]*static [^=;]* $m\(" "$W/src/SmsDeliverReceiver.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: EXTRACTION FAILED: $m found $n time(s), want 1" >&2; bad=1; }
done
n=$(grep -cE '^[ \t]*static final class Reply ' "$W/src/TelArrival.java" || true)
[ "$n" = 1 ] || { echo "run.sh: EXTRACTION FAILED: Reply found $n time(s), want 1" >&2; bad=1; }
[ "$bad" = 0 ] || exit 2

cp "$here/TelPartialCases.java" "$W/src/" || exit 2
"$JAVAC" -encoding UTF-8 -d "$W/classes" "$W/src/TelArrival.java" "$W/src/SmsDeliverReceiver.java" "$W/src/TelPartialCases.java" \
  || { echo "run.sh: the lifted classes do not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$W/classes" TelPartialCases
