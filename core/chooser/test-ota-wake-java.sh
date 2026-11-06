#!/usr/bin/env bash
# test-ota-wake-java.sh [<OtaWakeReceiver.java>] [--mutate] -- OtaWakeReceiver, the only thing that makes an idle phone at
# the gate check for updates, compiled UNCHANGED against android stubs and RUN (NWP-20261022-13).
#
# WHY THIS IS COMMITTED. Its contracts were stated and executed by nothing: onReceive re-arms FIRST and unconditionally
# (a `finally`; an alarm that fails to re-arm is a device that never updates again until reboot); the 2 h cadence is jittered
# +/-20 min (a REQUIREMENT -- a regular wake is a correlatable beacon); the 20 min fast lane runs when the DAEMON gives no
# reply to OTA-REFRESH, at most FAST_MAX = 3 in a row (a dead daemon must not become a 20-minute wake loop on battery); arm
# and onReceive do nothing in any user but 0; only a VALIDATED network is admitted. A tidy-up could break any of them with CI
# green. core/chooser/tests/ota-wake/ holds the stubs and OtaWakeCases.
#
# This suite pins SHIPPED behaviour: its cases pass on main. What must fail is every mutant below.
# What it does NOT prove: that Android delivers the alarm in Doze (docs/lock-model.md records that on hardware).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-ota-wake-java.sh            # the cases
#   bash test-ota-wake-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/OtaWakeReceiver.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/ota-wake/run.sh"
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
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export OTA_WAKE_TMP="$W"

# suite <OtaWakeReceiver.java> -> run.sh's code: 0 pass, 1 a case failed (only this may convict a mutant), 3 no compile.
suite() { bash "$RUN" "$1"; }

echo "== $SRC"
out=$(suite "$SRC" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr>
  local d m rc o changed; d=$(mktemp -d -p "$W"); m="$d/OtaWakeReceiver.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$m" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 re-arm moved from finally to the end of the try" 's/(\n {16}fast = r\.isEmpty\(\) && sConsecutiveFast < FAST_MAX;\n {12}\}\n)(.*?\} finally \{\n)( {12}sConsecutiveFast = fast \? sConsecutiveFast \+ 1 : 0;\n {12}arm\(app, nextDelayMs\(fast\)\);\n)/$1$3$2/s' || fails=$((fails+1))
mut "M2 sConsecutiveFast < FAST_MAX dropped" 's/ && sConsecutiveFast < FAST_MAX;/;/' || fails=$((fails+1))
mut "M3 the jitter removed" 's/return BASE_MS - JITTER_MS \+ \(long\) \(Math\.random\(\) \* \(2 \* JITTER_MS\)\);/return BASE_MS;/' || fails=$((fails+1))
mut "M4 the user-0 guard in onReceive removed" 's/(public void onReceive\(Context ctx, Intent intent\) \{\n)        if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;\n/$1/' || fails=$((fails+1))
mut "M5 the VALIDATED check removed from networkUsable" 's/return c != null && c\.hasCapability\(NetworkCapabilities\.NET_CAPABILITY_VALIDATED\);/return c != null;/' || fails=$((fails+1))
mut "M6 fast = r.isEmpty() inverted" 's/fast = r\.isEmpty\(\) &&/fast = !r.isEmpty() \&\&/' || fails=$((fails+1))
mut "M7 the user-0 guard in arm removed" 's/        if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return; \/\/ the gate/        \/\/ the gate/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
