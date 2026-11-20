#!/usr/bin/env bash
# test-gate-stray-crashes-java.sh [--mutate] -- NWP-20261210-24, backlog row "Stray broadcasts wake providers INTO a
# user whose CE storage is already gone, and they crash on the gate (NWP-20260826-10 tail)". Runs
# core/chooser/tests/gate-stray-crashes: GateStrayCrashes's pure members, compiled and EXECUTED, and source pins on the
# DropBox and user reads a gate issue report makes (tests/gate-stray-crashes/run.sh says how).
#
# WHY THIS IS COMMITTED. The row's next step is a measurement: the same two platform providers crashed in a user whose
# storage was gone, after a sign-out and during a sign-in, and nothing says whether that is routine or rare. A gate
# report now carries gate_crash_access and five bucketed counts of those two providers' crash records since boot, in
# users that are gone or stopped. Q121 keeps a gate report crash-free, so the pins hold that line: no record, no text,
# no process or app name and no user id leaves put(), nothing is logged or written, and "denied" answers only DropBox.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL with its named case or pin: a mutant that does not
# apply (INERT) or fails some other way (BROKEN) counts as a failure, never a pass. One control mutant (a comment's
# wording) must SURVIVE.
#
#   bash test-gate-stray-crashes-java.sh            # the cases
#   bash test-gate-stray-crashes-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/gate-stray-crashes/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-gate-stray-crashes-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

echo "== $CH"
bash "$RUN" "$CH" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named case or pin)"
# mut <label> <file under the chooser dir> <perl-expr> <text the failure must contain | SURVIVE>
mut() {
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$CH"/src/com/nowhere/chooser/*.java "$d/src/com/nowhere/chooser/"
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$f" "$CH/$2"; then echo "  INERT     $1"; rm -rf "$d"; return 1; fi
  out=$(bash "$RUN" "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$4" = SURVIVE ]; then
    [ "$rc" -eq 0 ] && { echo "  survived  $1 (control)"; return 0; }
    echo "  KILLED    $1 -- the control must survive (rc=$rc)"; printf '%s\n' "$out" | grep FAIL; return 1
  fi
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; printf '%s\n' "$out" | tail -n 5; return 1 ;;
  esac
  case "$out" in *"FAIL  $4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4'"; printf '%s\n' "$out" | grep FAIL; return 1 ;; esac
  echo "  convicted $1 (by $4)"
}
G=src/com/nowhere/chooser/GateStrayCrashes.java
C=src/com/nowhere/chooser/ChooserActivity.java
fails=0
mut "M1 the exact match turned into startsWith"  $G 's/if \(CAL\.equals\(process\)\)/if (process != null && process.startsWith(CAL))/; s/if \(MEDIA\.equals\(process\)\)/if (process != null && process.startsWith(MEDIA))/' "C5" || fails=$((fails+1))
mut "M2 the running-user exclusion dropped"      $G 's/\n[ \t]*if \(running\.contains\(user\)\) return null;//' "C3" || fails=$((fails+1))
mut "M3 the bootMs filter dropped"               $G 's/\n[ \t]*if \(times\[i\] < bootMs\) continue;//' "C4" || fails=$((fails+1))
mut "M4 stopped and gone swapped"                $G 's/return "stopped";/return "GONE_X";/; s/return "gone";/return "stopped";/; s/return "GONE_X";/return "gone";/' "C2" || fails=$((fails+1))
mut "M5 the bucket cap removed"                  $G 's/return n >= 10 \? "10\+" : String\.valueOf\(n\);/return String.valueOf(n);/' "C7" || fails=$((fails+1))
mut "M6 a sixth key added"                       $G 's/(\n([ \t]*)m\.put\("stray_crash_nouid", bucket\(nouid\)\);)/$1\n$2m.put("stray_crash_total", bucket(cal + media));/' "C8" || fails=$((fails+1))
mut "M7 the process string put into st"          $G 's/(\n([ \t]*)uid = CrashRecords\.headerUid\(text\);)/$1\n$2st.put("stray_crash_process", p);/' "P3" || fails=$((fails+1))
mut "M8 SecurityException mapped to error"       $G 's/write\(st, "denied", null\);/write(st, "error", null);/' "P2" || fails=$((fails+1))
mut "M9 the gateReportJson call removed"         $C 's/\n[ \t]*GateStrayCrashes\.put\(this, st\);[^\n]*//' "P1" || fails=$((fails+1))
mut "K1 control: a comment's wording changed"    $G 's/keep no other process.s name, not even here/no other process name is kept/' SURVIVE || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted, the control survived" || { echo "== $fails mutation(s) not as required"; exit 1; }
