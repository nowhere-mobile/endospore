#!/usr/bin/env bash
# test-plan-expiry-java.sh [--mutate] -- the plan-expiry notices on the phone (NWP-20261118-08, #53).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-10-30, harvest 48 #8: the phone warns 30 and 7 days before a
# plan ends, on the end date, and through grace with the ledger's deletion date; the storefront email is dropped for
# good. PlanExpiry (pure, java.lang / java.util / java.text) decides the stage from GET-BILLING and GET-ENTITLEMENT and
# writes the wording; it is compiled here with its cases. No notice is decided while the gateway has not answered
# (entitled -1, a store-refused footprint included), a purchase is pending or a plan is moving; grace needs
# entitled 0 and the ledger's deadline. SOURCE checks over ChooserActivity (S1-S8) pin the wiring a javac run cannot
# reach: the watcher starts the check (startPlanCheck) only behind planBusy, and the check asks PlanExpiry.stage once;
# GET-BILLING and GET-ENTITLEMENT are literal roundTrip calls on the "nowhere-plan-check" thread, GET-ENTITLEMENT with
# a bound of at least 30 s and never through pollDaemon (it is serialized in the daemon and goes to the gateway); the
# watcher itself sends neither (core/agent TestGatePollersNeverWaitOnTheSession lets the gate's pollers send only
# lock-free verbs); the notice is not ongoing; the gate's no-session block cancels it; the first check waits
# PLAN_FIRST_DELAY_MS after a sign-in; it posts only into the same live uid; and nothing in the watcher but its own
# Thread is named t (NWP-20261029-22).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-plan-expiry-java.sh            # the cases and the source checks
#   bash test-plan-expiry-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CASES="$root/core/chooser/tests/plan-expiry/PlanExpiryCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# body <file> <signature> -> from the line holding the signature to the first line that is exactly "    }".
body() { awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# count <text> <fixed string> -> the number of non-comment lines holding it.
count() { printf '%s\n' "$1" | S="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && index($0, ENVIRON["S"]) { n++ } END { print n + 0 }'; }
# span <text> <from> <to> -> the lines from the first holding <from> to the next holding <to>.
span() { printf '%s\n' "$1" | A="$2" B="$3" awk 'index($0, ENVIRON["A"]) { on = 1 } on { print } on && index($0, ENVIRON["B"]) { exit }'; }

# source_checks <dir with ChooserActivity.java> -> 0 when every check holds.
source_checks() {
  local f="$1/ChooserActivity.java" bad=0 w plan nos post bound arm
  w=$(body "$f" 'private void startSyncStatusWatcher() {')
  [ -n "$w" ] || { echo "  FAIL  startSyncStatusWatcher not found" >&2; return 1; }
  plan=$(body "$f" 'private static void startPlanCheck(final Context app, final int pu) {')
  nos=$(span "$w" 'if (uid < 0) {' 'continue;')
  post=$(body "$f" 'private static void postPlanNotice(')
  [ -n "$plan" ] && [ "$(count "$plan" '}, "nowhere-plan-check").start();')" -eq 1 ] \
    || { echo "  FAIL  S2: startPlanCheck, or its \"nowhere-plan-check\" thread, not found" >&2; bad=1; }
  arm=$(printf '%s\n' "$w" | grep -A1 -F 'planBusy.compareAndSet(false, true)) {' | tail -1)
  [ "$(count "$w" 'startPlanCheck(')" -eq 1 ] && [ "$(count "$arm" 'startPlanCheck(app, uid);')" -eq 1 ] \
    || { echo "  FAIL  S1: the watcher does not start the plan check exactly once, behind planBusy.compareAndSet" >&2; bad=1; }
  [ -n "$nos" ]  || { echo "  FAIL  S5: the watcher's no-session block not found" >&2; bad=1; }

  [ "$(count "$plan" 'PlanExpiry.stage(')" -eq 1 ] && [ "$(count "$(cat "$f")" 'PlanExpiry.stage(')" -eq 1 ] \
    || { echo "  FAIL  S1: the plan check does not call PlanExpiry.stage exactly once" >&2; bad=1; }
  [ "$(count "$plan" 'DaemonSocket.roundTrip("GET-ENTITLEMENT\n", ')" -eq 1 ] \
    || { echo "  FAIL  S2: GET-ENTITLEMENT is not sent once by a literal DaemonSocket.roundTrip on the plan thread" >&2; bad=1; }
  bound=$(printf '%s\n' "$plan" | grep -oE 'roundTrip\("GET-ENTITLEMENT\\n", [0-9]+\)' | grep -oE '[0-9]+\)$' | tr -d ')')
  [ -n "$bound" ] && [ "$bound" -ge 30000 ] \
    || { echo "  FAIL  S2: GET-ENTITLEMENT's bound on the plan thread is not at least 30000 ms (got '${bound}')" >&2; bad=1; }
  [ "$(count "$w" 'GET-ENTITLEMENT')" -eq 0 ] && [ "$(count "$w" 'GET-BILLING')" -eq 0 ] \
    || { echo "  FAIL  S2: the watcher itself sends GET-ENTITLEMENT or GET-BILLING (a gate poller may send only lock-free verbs)" >&2; bad=1; }
  [ "$(count "$(cat "$f")" 'pollDaemon("GET-ENTITLEMENT')" -eq 0 ] \
    || { echo "  FAIL  S2: GET-ENTITLEMENT goes through pollDaemon" >&2; bad=1; }
  [ "$(count "$plan" 'DaemonSocket.roundTrip("GET-BILLING\n", 5000)')" -eq 1 ] \
    || { echo "  FAIL  S3: GET-BILLING is not one literal DaemonSocket.roundTrip(\"GET-BILLING\\n\", 5000) on the plan thread" >&2; bad=1; }
  [ -n "$post" ] && [ "$(count "$post" 'setOngoing(')" -eq 0 ] \
    || { echo "  FAIL  S4: postPlanNotice is missing or sets setOngoing" >&2; bad=1; }
  [ "$(count "$nos" 'cancelPlanNotice(')" -eq 1 ] \
    || { echo "  FAIL  S5: the no-session block does not call cancelPlanNotice" >&2; bad=1; }
  arm=$(printf '%s\n' "$w" | grep -A2 -F 'if (uid != planSchedUid.get()) {' | tail -1)
  [ "$(count "$w" 'planDueMs.set(android.os.SystemClock.elapsedRealtime() + PlanExpiry.PLAN_FIRST_DELAY_MS);')" -eq 1 ] \
    && [ "$(count "$arm" 'planDueMs.set(android.os.SystemClock.elapsedRealtime() + PlanExpiry.PLAN_FIRST_DELAY_MS);')" -eq 1 ] \
    || { echo "  FAIL  S6: a sign-in (a new live uid) does not set the first check PLAN_FIRST_DELAY_MS ahead" >&2; bad=1; }
  [ "$(count "$w" 'planDueMs.set(')" -eq 1 ] && [ "$(count "$plan" 'planDueMs.set(')" -eq 1 ] \
    && [ "$(count "$(cat "$f")" 'planDueMs.set(')" -eq 2 ] \
    || { echo "  FAIL  S6: planDueMs is set somewhere other than the sign-in arm and the check's finally" >&2; bad=1; }
  [ "$(count "$plan" 'android.app.ActivityManager.getCurrentUser() != pu) return;')" -eq 1 ] \
    || { echo "  FAIL  S7: the plan thread does not re-read the current user before it posts" >&2; bad=1; }
  [ "$(count "$w" 'Thread t =')" -eq 1 ] && [ "$(count "$w" 'Throwable t)')" -eq 0 ] \
    || { echo "  FAIL  S8: something in the watcher besides its Thread is named t (NWP-20261029-22)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# suite <dir holding PlanExpiry.java and ChooserActivity.java> -> 0 pass, 1 a case or check failed, 3 did not compile.
suite() {
  local dir="$1" d out rc
  [ -f "$dir/PlanExpiry.java" ] || { echo "  FAIL  PlanExpiry.java does not exist (the plan-expiry decision is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$dir/PlanExpiry.java" "$d/src/com/nowhere/chooser/PlanExpiry.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/PlanExpiryCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PlanExpiryCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] || return 1
  [ -f "$dir/ChooserActivity.java" ] || { echo "  FAIL  ChooserActivity.java missing" >&2; return 1; }
  source_checks "$dir" || return 1
  return 0
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that is inert or does not compile proves nothing)"
# mutate <label> <file name> <sed script>
mutate() {
  local label="$1" file="$2" script="$3" d rc
  d=$(mktemp -d -p "$W") || return 1
  cp "$SRC"/PlanExpiry.java "$SRC"/ChooserActivity.java "$d/"
  sed -i "$script" "$d/$file"
  if cmp -s "$SRC/$file" "$d/$file"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$d" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  convicted $label"; return 0 ;;
    0) echo "  SURVIVED  $label"; return 1 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
P=PlanExpiry.java; C=ChooserActivity.java
mutate "M1 the window is 31 days" $P 's/if (left > 30) return NONE;/if (left > 31) return NONE;/' || fails=$((fails+1))
mutate "M2 an unanswered entitlement reads as answered (0)" $P 's/if (reply == null || !reply.startsWith("OK")) return -1;/if (reply == null || !reply.startsWith("OK")) return 0;/' || fails=$((fails+1))
mutate "M3 GRACE without entitled == 0" $P 's/return entitled == 0 \&\& p.deadline > 0/return p.deadline > 0/' || fails=$((fails+1))
mutate "M4 GRACE without a deadline" $P 's/return entitled == 0 \&\& p.deadline > 0 \&\& p.deadline >= nowEp ? GRACE : NONE;/return entitled == 0 ? GRACE : NONE;/' || fails=$((fails+1))
mutate "M5 pending ignored" $P '/if (p.pending > 0) return NONE;/d' || fails=$((fails+1))
mutate "M6 N days off by one" $P 's/final long n = p.through - nowSec \/ p.epochsec;/final long n = p.through - nowSec \/ p.epochsec + 1;/' || fails=$((fails+1))
mutate "M7 GET-ENTITLEMENT through pollDaemon" $C 's/DaemonSocket.roundTrip("GET-ENTITLEMENT\\n", 60000)/pollDaemon("GET-ENTITLEMENT\\n")/' || fails=$((fails+1))
mutate "M8 the plan notice is ongoing" $C '/private static void postPlanNotice(/,/^    }$/s/\.setSmallIcon(R.drawable.ic_backup_warn)/.setSmallIcon(R.drawable.ic_backup_warn).setOngoing(true)/' || fails=$((fails+1))
mutate "M9 the first check runs at the switch" $C 's/elapsedRealtime() + PlanExpiry.PLAN_FIRST_DELAY_MS);/elapsedRealtime());/' || fails=$((fails+1))
mutate "M10 the gate leaves the plan notice up" $C 's/if (planShownUid.get() >= 0) cancelPlanNotice(app, planShownUid.get()); //' || fails=$((fails+1))
mutate "M11 moving ignored" $P '/if (p.moving > 0) return NONE;/d' || fails=$((fails+1))
mutate "M12 the plan thread posts into whatever user is current" $C 's/if (!sessionLive || android.app.ActivityManager.getCurrentUser() != pu) return;/if (!sessionLive) return;/' || fails=$((fails+1))
mutate "M13 the watcher starts a check with one already in flight" $C 's/ \&\& planBusy.compareAndSet(false, true)) {/) {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
