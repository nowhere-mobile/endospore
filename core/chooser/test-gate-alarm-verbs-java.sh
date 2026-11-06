#!/usr/bin/env bash
# test-gate-alarm-verbs-java.sh [--mutate] -- GateAlarmVerbs (which gate.log verb a gate-alarm reply or event means),
# compiled UNCHANGED under javac and RUN, plus pins on the chooser call sites and on core/agent/gate_log.go (NWP-20261028-13).
#
# WHY THIS IS COMMITTED. GateAlarmActivity recorded ui-silence-ok for ANY non-empty daemon reply (ERR-LIVE and NONE included),
# and the chooser sent none of the armed / consume / cancel / ui-vibrate-err / ui-guard-err verbs gate.log declares. G1 below IS
# the pre-change ternary. What it does NOT prove: a device ring, or that the full chooser compiles (the build host does that).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-gate-alarm-verbs-java.sh            # the cases and the pins
#   bash test-gate-alarm-verbs-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/src/com/nowhere/chooser"
SRC="$CH/GateAlarmVerbs.java"
ACT="$CH/ChooserActivity.java"
GAT="$CH/GateAlarmActivity.java"
GOL="$HERE/../agent/gate_log.go"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/gate-alarm-verbs/run.sh"
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
for f in "$SRC" "$ACT" "$GAT" "$GOL" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export GATE_ALARM_VERBS_TMP="$W"

# suite <GateAlarmVerbs.java> <ChooserActivity.java> <gate_log.go> -> run.sh's code: 0 pass, 1 a case failed (only this may convict), 3 no compile.
suite() { bash "$RUN" "$1" "$2" "$3" "$4"; }

echo "== $SRC"
out=$(suite "$SRC" "$ACT" "$GAT" "$GOL" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <file: verbs|act|gat|go> <perl-expr>
  local d m rc o orig v a g t GATM; d=$(mktemp -d -p "$W")
  v="$SRC"; a="$ACT"; g="$GOL"; GATM="$GAT"
  case "$2" in
    verbs) orig="$SRC"; m="$d/GateAlarmVerbs.java"; v="$m" ;;
    act)   orig="$ACT"; m="$d/ChooserActivity.java"; a="$m" ;;
    gat)   orig="$GAT"; m="$d/GateAlarmActivity.java"; GATM="$m" ;;
    go)    orig="$GOL"; m="$d/gate_log.go"; g="$m" ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$v" "$a" "$GATM" "$g" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "G1 silence back to isEmpty ? empty : ok (the pre-change ternary)" verbs \
  's/(static String silence\(String reply\) \{\n).*?(\n    \}\n)/$1        return (reply == null || reply.isEmpty()) ? "ui-silence-empty" : "ui-silence-ok";$2/s' || fails=$((fails+1))
mut "G2 equals(\"OK\") became startsWith(\"OK\")" verbs 's/first\.equals\("OK"\)/first.startsWith("OK")/' || fails=$((fails+1))
mut "G3 consume says consume for a past time" verbs 's/return when > nowMs \? "consume" : "consume-past";/return "consume";/' || fails=$((fails+1))
mut "G4 consume returns a verb for 0 (the onResume flood)" verbs 's/if \(when == 0\) return null;//' || fails=$((fails+1))
mut "G5 ui-silence-refused removed from gateLogVerbs" go 's/\t"ui-silence-refused": true,\n//' || fails=$((fails+1))
mut "G6 the sign-in caller passes cancel-dismiss" act 's/cancelGateAlarm\(getApplicationContext\(\), "cancel-login"\)/cancelGateAlarm(getApplicationContext(), "cancel-dismiss")/' || fails=$((fails+1))
mut "G7 consume trace moved in front of the arm" act 's/(if \(when > now\) scheduleGateAlarmAt\(appCtx, when\);[^\n]*\n)(\s*)(if \(v != null\) GateTrace\.ev\(v, "in"[^\n]*\n)/$2$3$2$1/' || fails=$((fails+1))
mut "G8 ui-guard-err traced in currentUser, in front of the ring" gat 's/guardErr = true;/GateTrace.ev("ui-guard-err");/' || fails=$((fails+1))
mut "G9 ui-guard-err traced before the ring thread starts" gat 's/(\n\s*)(new Thread\(this::startRing[^\n]*)/$1GateTrace.ev("ui-guard-err");$1$2/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
