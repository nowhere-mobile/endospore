#!/usr/bin/env bash
# run.sh <IdleLane.java> <ChooserActivity.java> -- NWP-20261114-04: compile the REAL IdleLane (unchanged) with
# IdleLaneCases and run it, then pin armIdleWatcher and cancelIdleWatcher in ChooserActivity. The pins read a copy with
# the comments dropped and the line count kept, so prose cannot satisfy a pin and line numbers match the source.
# $JAVAC / $JAVA come from core/chooser/test-idle-lane-java.sh.
# Exit codes: 1 = a case or a pin failed; 3 = the sources did not compile, or the JVM died with anything but 0/1.
set -euo pipefail
U="usage: run.sh IdleLane.java ChooserActivity.java"
SRC="${1:?$U}"
ACT="${2:?$U}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${IDLE_LANE_TMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT

mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$SRC" "$D/src/com/nowhere/chooser/IdleLane.java"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" "$D/src/com/nowhere/chooser/IdleLane.java" "$here/IdleLaneCases.java" \
    2>"$D/javac.err" || { head -20 "$D/javac.err" >&2; exit 3; }
rc=0
timeout 60 "$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.IdleLaneCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

pass() { echo "--- PASS: pin: $1"; }
fail() { echo "--- FAIL: pin: $1"; rc=1; }

# A comment-free copy that keeps every line: a block comment becomes its own newlines, a line comment becomes nothing.
perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|(/\*.*?\*/)|//[^\n]*}{defined $1 ? $1 : defined $2 ? ("\n" x ($2 =~ tr/\n//)) : ""}gse' \
    "$ACT" > "$D/act.java"
[ "$(wc -l < "$D/act.java")" = "$(wc -l < "$ACT")" ] || { fail "the comment-free copy lost lines"; exit 1; }

# body <signature> <out>: "NR<TAB>line" from the signature line to the brace that closes it. The signature must occur
# exactly once; otherwise SIGBAD is set, and both bodies are emptied so every pin below fails.
SIGBAD=no
body() {
  local sig="$1" out="$2" n
  n=$(grep -cF "$sig" "$D/act.java" || true)
  if [ "$n" != 1 ]; then echo "--- FAIL: pin: '$sig' occurs $n times, not once -- every pin fails"; rc=1; SIGBAD=yes; : > "$out"; return; fi
  awk -v sig="$sig" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print NR "\t" $0; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$D/act.java" > "$out"
}
ARM="$D/arm.txt"; CAN="$D/cancel.txt"
body 'private static void armIdleWatcher(' "$ARM"
body 'private static void cancelIdleWatcher(' "$CAN"
[ "$SIGBAD" = no ] || { : > "$ARM"; : > "$CAN"; }
# cnt <fixed string> <file>: how many lines hold it (0 when none; grep reads the whole file).
cnt() { grep -cF -- "$1" "$2" || true; }
# nr_of <fixed string> <file>: the NR of every line that holds it, space-separated.
nr_of() { awk -F'\t' -v s="$1" 'index($0, s) { printf "%s%s", (k++ ? " " : ""), $1 }' "$2"; }

# P4 (control first): the extraction found armIdleWatcher's real body.
if [ -s "$ARM" ] && [ "$(cnt 'IdleLogoffReceiver.class' "$ARM")" -ge 1 ]; then pass "P4 armIdleWatcher holds IdleLogoffReceiver.class"
else fail "P4 armIdleWatcher holds IdleLogoffReceiver.class"; fi

# P1: the teardown's binder calls are posted on the lane, not on a new thread.
if [ -s "$CAN" ] && [ "$(cnt 'IdleLane.post(' "$CAN")" -ge 1 ]; then pass "P1 cancelIdleWatcher posts on IdleLane.post("
else fail "P1 cancelIdleWatcher posts on IdleLane.post("; fi
if [ -s "$CAN" ] && [ "$(cnt 'new Thread(' "$CAN")" = 0 ]; then pass "P1 cancelIdleWatcher starts no new Thread("
else fail "P1 cancelIdleWatcher starts no new Thread("; fi

# P2: the arm's max-time-to-lock set is posted on the lane, it is the only such call, and it follows the teardown.
SET='IdleLane.post(() -> setMaxTimeToLock(appCtx, maxLockMs));'
l_set=$(awk -F'\t' -v s="$SET" '{ t=$2; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) } t == s { printf "%s%s", (k++ ? " " : ""), $1 }' "$ARM")
l_any=$(nr_of 'setMaxTimeToLock(' "$ARM")
l_can=$(nr_of 'cancelIdleWatcher(appCtx);' "$ARM")
if [ -s "$ARM" ] && [ -n "$l_set" ] && [ "$l_set" = "${l_set% *}" ]; then pass "P2 armIdleWatcher holds the line $SET"
else fail "P2 armIdleWatcher holds the line $SET (found at: '${l_set}')"; fi
if [ -s "$ARM" ] && [ -n "$l_set" ] && [ "$l_any" = "$l_set" ]; then pass "P2 no other armIdleWatcher line holds setMaxTimeToLock("
else fail "P2 no other armIdleWatcher line holds setMaxTimeToLock( (lines: '${l_any}')"; fi
if [ -s "$ARM" ] && [ -n "$l_set" ] && [ -n "$l_can" ] && [ "$l_can" = "${l_can% *}" ] && [ "$l_set" = "${l_set% *}" ] \
   && [ "$l_set" -gt "$l_can" ]; then pass "P2 the set is posted after cancelIdleWatcher(appCtx);"
else fail "P2 the set is posted after cancelIdleWatcher(appCtx); (set: '${l_set}', cancel: '${l_can}')"; fi

# P3: each arm's alarm Intent carries its own action, from a sequence armIdleWatcher increments.
intent=$(awk -F'\t' 'index($0, "new android.content.Intent(appCtx, IdleLogoffReceiver.class)") { print $2 }' "$ARM")
case "$intent" in
  *".setAction("*sIdleArmSeq*) pass "P3 the IdleLogoffReceiver Intent line holds .setAction( and sIdleArmSeq" ;;
  *) fail "P3 the IdleLogoffReceiver Intent line holds .setAction( and sIdleArmSeq" ;;
esac
if [ -s "$ARM" ] && [ $(( $(cnt 'sIdleArmSeq++' "$ARM") + $(cnt '++sIdleArmSeq' "$ARM") )) -ge 1 ]; then
  pass "P3 armIdleWatcher increments sIdleArmSeq"
else fail "P3 armIdleWatcher increments sIdleArmSeq"; fi
exit "$rc"
