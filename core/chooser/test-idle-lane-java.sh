#!/usr/bin/env bash
# test-idle-lane-java.sh [<IdleLane.java>] [--mutate] -- the idle watcher's binder calls run on ONE serial lane, and
# each arm gets its own idle-alarm PendingIntent (NWP-20261114-04). IdleLane is compiled UNCHANGED under javac and RUN.
#
# WHY THIS IS COMMITTED. cancelIdleWatcher started a new thread for its binder calls (NWP-20260826-10) while
# armIdleWatcher set the maximum time to lock on the caller's thread, microseconds later. Nothing ordered the two
# DevicePolicyManager calls: when the teardown's clear landed second, the session ran with no maximum time to lock, so
# a keep-screen-on app kept it unlocked and decrypted (the DIA-20260630-39 backstop gone). And every arm got back the
# SAME PendingIntent (extras are not part of Intent.filterEquals), so a late teardown cancel could cancel the alarm the
# next screen-off had just set, while sIdleArmed stayed true and no later screen-off re-armed it. The cases prove the
# lane (order, a throwing task, the daemon thread, two posters); the pins in tests/idle-lane/run.sh hold both methods.
# What it does NOT prove: the device run (dumpsys device_policy shows the session's maximum time to lock), and the
# chooser itself, which cannot be compiled off the build host.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-idle-lane-java.sh            # the cases and the pins
#   bash test-idle-lane-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/IdleLane.java"
ACT="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/idle-lane/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite did NOT run and does not skip: install a JDK or" \
       "run it on the build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$SRC" "$ACT" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export IDLE_LANE_TMP="$W"

# suite <IdleLane> <ChooserActivity> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may convict), 3 no
# compile or the JVM died.
suite() { bash "$RUN" "$1" "$2"; }

echo "== $SRC"
out=$(suite "$SRC" "$ACT" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <kind: lane|act> <perl-expr>
  local d m rc o orig l a f; d=$(mktemp -d -p "$W")
  l="$SRC"; a="$ACT"
  case "$2" in
    lane) orig="$SRC"; f=IdleLane.java; m="$d/$f"; l="$m" ;;
    act) orig="$ACT"; f=ChooserActivity.java; m="$d/$f"; a="$m" ;;
    *) echo "  ERROR     $1 -- unknown mutant kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$l" "$a" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; grep -F -- '--- FAIL' <<<"$o" | sed 's/^/              /'; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 IdleLane on a cached thread pool" lane 's/Executors\.newSingleThreadExecutor\(/Executors.newCachedThreadPool(/' \
  || fails=$((fails+1))
mut "M2 the per-task catch removed, the task run bare on the executor" lane \
  's/exec\.execute\(\(\) -> \{\s*try \{ r\.run\(\); \}\s*catch \(Throwable t\) \{[^\n]*\}\s*\}\);/exec.execute(r);/' \
  || fails=$((fails+1))
mut "M3 the lane thread is not a daemon" lane 's/t\.setDaemon\(true\);/t.setDaemon(false);/' || fails=$((fails+1))
mut "M4 cancelIdleWatcher back to new Thread(" act \
  's/IdleLane\.post\(\(\) -> \{(\n\s*setMaxTimeToLock\(appCtx, 0\);.*?unregisterReceiver\(present\);[^\n]*\n\s*)\}\);/new Thread(() -> {$1}, "nowhere-idle-teardown").start();/s' \
  || fails=$((fails+1))
mut "M5 the direct pre-change set restored" act \
  's/final long maxLockMs = Math\.max\(sIdleTimeoutMs, WAKELOCK_LOCK_FLOOR_MS\);\n\s*IdleLane\.post\(\(\) -> setMaxTimeToLock\(appCtx, maxLockMs\)\);/setMaxTimeToLock(appCtx, Math.max(sIdleTimeoutMs, WAKELOCK_LOCK_FLOOR_MS));/' \
  || fails=$((fails+1))
mut "M6 the two new lines moved above cancelIdleWatcher(appCtx);" act \
  's/(\n\s*cancelIdleWatcher\(appCtx\);)(.*?)\n(\s*final long maxLockMs = [^\n]*\n\s*IdleLane\.post\(\(\) -> setMaxTimeToLock\(appCtx, maxLockMs\)\);)/\n$3$1$2/s' \
  || fails=$((fails+1))
mut "M7 the per-arm setAction dropped" act 's/\.setAction\("com\.nowhere\.chooser\.IDLE_LOGOFF\." \+ sIdleArmSeq\)//' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
