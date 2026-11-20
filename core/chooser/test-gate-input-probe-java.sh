#!/usr/bin/env bash
# test-gate-input-probe-java.sh [--mutate] -- GateInputProbe.Rule (when the gate records an input stall, and the fixed
# codes it records), compiled UNCHANGED under javac and RUN, plus the gateLogVerbs map check and source pins on the
# sampler and NowhereApp (NWP-20261208-08).
#
# WHY THIS IS COMMITTED. Backlog row "After a sign-out the gate can stop taking touches": the gate's main thread is idle
# and the input channel is responsive, yet touches stop. The probe writes to gate.log, on any stall over 5 s, where the
# event waits. The cases pin the cause order (the idle case: an IME-held event, or the system's not-responding flag),
# the code digits and caps, the per-process cap, and that an outstanding read never ends an episode; the map check pins that every verb lands as itself, not as
# trace-unknown; the pins hold the user-0 guard, the closed GateTrace shape, the pid match and the tick order.
# What it does NOT prove: a device stall, or that the full chooser compiles (the build host does that).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-gate-input-probe-java.sh            # the cases and the pins
#   bash test-gate-input-probe-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/src/com/nowhere/chooser"
SRC="$CH/GateInputProbe.java"
APP="$CH/NowhereApp.java"
GOL="$HERE/../agent/gate_log.go"
CASES="$HERE/tests/gate-input-probe/GateInputProbeCases.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$SRC" "$APP" "$GOL" "$CASES"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# One root for everything this suite creates (each compile dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

# suite <GateInputProbe.java> <NowhereApp.java> <gate_log.go> -> 0 pass, 1 a case or pin failed (only this may
# convict), 3 no compile. The outer class imports android, so only the nested Rule is lifted out (awk) and compiled
# into a stand-in GateInputProbe; the pins read the whole file as text.
suite() {
  local d rule rc
  d=$(mktemp -d -p "$W")
  rule=$(awk '/^    static final class Rule \{$/ {on=1} on {print} on && /^    }$/ {exit}' "$1")
  if [ -z "$rule" ]; then echo "--- FAIL: no 'static final class Rule {' block in $1"; rm -rf "$d"; return 1; fi
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  printf 'package com.nowhere.chooser;\n\nfinal class GateInputProbe {\n%s\n}\n' "$rule" > "$d/src/com/nowhere/chooser/GateInputProbe.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -nowarn -d "$d/out" \
      "$d/src/com/nowhere/chooser/GateInputProbe.java" "$CASES" 2>"$d/javac.err"; then
    head -20 "$d/javac.err" >&2; rm -rf "$d"; return 3
  fi
  rc=0
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GateInputProbeCases "$3" "$1" "$2" || rc=$?
  rm -rf "$d"
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || return 3
  return "$rc"
}

echo "== $SRC"
out=$(suite "$SRC" "$APP" "$GOL" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <file: probe|app|go> <perl-expr>
  local d m rc o orig s a g
  d=$(mktemp -d -p "$W")
  s="$SRC"; a="$APP"; g="$GOL"
  case "$2" in
    probe) orig="$SRC"; m="$d/GateInputProbe.java"; s="$m" ;;
    app)   orig="$APP"; m="$d/NowhereApp.java"; a="$m" ;;
    go)    orig="$GOL"; m="$d/gate_log.go"; g="$m" ;;
    *) echo "  ERROR     $1 -- unknown file kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$s" "$a" "$g" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a case failure"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 STALL_MS 50000 (convicted by: why pending 5001 -> 1)" probe 's/STALL_MS = 5000L;/STALL_MS = 50000L;/' || fails=$((fails+1))
mut "M2 first > STALL_MS becomes >= (convicted by: why pending 5000 -> 0)" probe \
  's/if \(pendingAgeMs > STALL_MS\)/if (pendingAgeMs >= STALL_MS)/' || fails=$((fails+1))
mut "M3 frame late counted when not interactive (convicted by: why frame late 60000, not interactive -> 0)" probe \
  's/if \(interactive && frameLateMs > STALL_MS\)/if (frameLateMs > STALL_MS)/' || fails=$((fails+1))
mut "M4 secMs cap removed (convicted by: secMs(10^9) -> 600000)" probe \
  's/long c = Math\.min\(ms, 600_000L\);/long c = ms;/' || fails=$((fails+1))
mut "M5 MAX_BLOCKS ignored (convicted by: shouldWrite(true,false,4))" probe \
  's/stalled && !inEpisode && written < MAX_BLOCKS;/stalled \&\& !inEpisode;/' || fails=$((fails+1))
mut "M6 a verb renamed in VERBS (convicted by: map: input-stall-imx is in gateLogVerbs)" probe \
  's/"input-stall-ime", "input-stall-stage"/"input-stall-imx", "input-stall-stage"/' || fails=$((fails+1))
mut "M7 a verb deleted from gateLogVerbs (convicted by: map: input-stall-vri is in gateLogVerbs)" go \
  's/ "input-stall-vri": true,//' || fails=$((fails+1))
mut "M8 NowhereApp no longer starts the probe (convicted by: P1)" app 's/\n\s*GateInputProbe\.start\(this\);//' || fails=$((fails+1))
mut "M9 the user-0 guard deleted (convicted by: P2)" probe \
  's/\n\s*if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;//' || fails=$((fails+1))
mut "M10 cause 6 dropped from why (convicted by: idle anrFlagged -> 6)" probe 's/\n\s*if \(anrFlagged\) return 6;//' || fails=$((fails+1))
mut "M11 cause 5 ignored (convicted by: idle stage 6000 -> 5)" probe 's/\n\s*if \(stageAgeMs > STALL_MS\) return 5;//' || fails=$((fails+1))
mut "M12 the pid comparison removed (convicted by: P5 matched on Process.myPid())" probe \
  's/e\.pid == android\.os\.Process\.myPid\(\) && //' || fails=$((fails+1))
mut "M13 a shortMsg read added (convicted by: P6 no shortMsg)" probe \
  's/(NOT_RESPONDING\) anr = true;)/$1\n                    String m = e.shortMsg;/' || fails=$((fails+1))
mut "M14 tickAge always unknown (convicted by: tickAge(false,6000) -> 6000; idle tick)" probe \
  's/return runOutstanding \? -1L : snapAgeMs;/return -1L;/' || fails=$((fails+1))
mut "M15 tickAge never unknown (convicted by: tickAge(true,6000) -> -1)" probe \
  's/return runOutstanding \? -1L : snapAgeMs;/return snapAgeMs;/' || fails=$((fails+1))
mut "M16 worstRoot counts pending only (convicted by: worstRoot IME-held event in a dialog -> 1)" probe \
  's/long ev = Math\.max\(pendingAge\[i\], at\(stageAge, i\)\);/long ev = pendingAge[i];/' || fails=$((fails+1))
mut "M17 maxAge returns ages[0] (convicted by: maxAge {-1,7000,3000} -> 7000; aggregate)" probe \
  's/for \(long a : ages\) if \(a > m\) m = a;\n(\s*)return m;/return ages[0];/' || fails=$((fails+1))
mut "M18 the tick posts first (convicted by: P7 tick has exactly one .post()" probe \
  's/(private static void tick\(Context app, Handler main, Runnable read\) \{)/$1\n        main.post(read);/' || fails=$((fails+1))
mut "M19 the stage age from the worst root only (convicted by: P7 tick has Rule.tickAge(out, Rule.maxAge(s.stageAge)))" probe \
  's/Rule\.tickAge\(out, Rule\.maxAge\(s\.stageAge\)\)/Rule.tickAge(out, s.stageAge[gw])/' || fails=$((fails+1))
mut "M20 shouldClear ignores observed (convicted by: sequence: delayed reads in one IME stall -> 0 clears)" probe \
  's/return inEpisode && cause == 0 && observed;/return inEpisode \&\& cause == 0;/' || fails=$((fails+1))
mut "M21 the tick clears on cause 0 alone (convicted by: P9 tick clears on Rule.shouldClear(inEpisode, cause, observed))" probe \
  's/else if \(Rule\.shouldClear\(inEpisode, cause, observed\)\)/else if (inEpisode \&\& cause == 0)/' || fails=$((fails+1))
mut "M22 observed true while the read is outstanding (convicted by: observed(true,true))" probe \
  's/return !runOutstanding && haveSnap;/return haveSnap;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
