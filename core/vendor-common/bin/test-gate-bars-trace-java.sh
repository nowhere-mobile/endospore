#!/usr/bin/env bash
# test-gate-bars-trace-java.sh [--mutate] -- in light mode the gate traces its window's dark-icon bits once per gate
# start (NWP-20261128-35).
#
# WHY THIS IS COMMITTED. On 2026-10-29 on lynx the light gate drew light status-bar icons, though applyGateBars asks
# for dark ones, and nothing read the appearance back. GateBarsTrace.java is the pure decision (whether to trace) and
# the value (the two light-bar bits); it is compiled UNCHANGED under javac and run with the cases below. The PINS read
# ChooserActivity.java (comments stripped) as data: onWindowFocusChanged traces `bars-light` through GateBarsTrace,
# once per instance, after its LockTask re-arm. The chooser cannot be compiled off the build host, so the call site is
# pinned by source. What it does NOT prove: what lynx reports, which needs a light-mode gate report from a device.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-gate-bars-trace-java.sh            # the cases and the pins
#   bash test-gate-bars-trace-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
GBT="$DIR/GateBarsTrace.java"
CA="$DIR/ChooserActivity.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
export TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CA" ] || { echo "FAIL: missing $CA" >&2; exit 2; }

# The cases, compiled beside the GateBarsTrace copy under test. Exit 1 on any failed case.
CASES="$W/GateBarsTraceCases.java"
cat > "$CASES" <<'JAVA'
package com.nowhere.chooser;

public class GateBarsTraceCases {
    static int fails;
    static void check(String name, boolean ok) {
        System.out.println((ok ? "--- PASS: " : "--- FAIL: ") + name);
        if (!ok) fails++;
    }
    public static void main(String[] a) {
        check("G1 a dark palette never traces (sdk 34)", !GateBarsTrace.shouldTrace(false, false, 34));
        check("G1 a dark palette never traces (sdk 30)", !GateBarsTrace.shouldTrace(false, false, 30));
        check("G2 a light palette traces the first time", GateBarsTrace.shouldTrace(true, false, 34));
        check("G2 a light palette traces once per instance", !GateBarsTrace.shouldTrace(true, true, 34));
        check("G3 sdk 29 never traces (no getSystemBarsAppearance)", !GateBarsTrace.shouldTrace(true, false, 29));
        check("G3 sdk 30 traces", GateBarsTrace.shouldTrace(true, false, 30));
        check("G4 value(8|16|1024) == 24", GateBarsTrace.value(8 | 16 | 1024) == 24);
        check("G4 value(1024) == 0", GateBarsTrace.value(1024) == 0);
        check("G4 value(8) == 8", GateBarsTrace.value(8) == 8);
        check("G4 value(16) == 16", GateBarsTrace.value(16) == 16);
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA

# strip <in> <out>: drop // and /* */ comments outside string and char literals.
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1" > "$2"
}

# has <file> <label> <fixed text>: a --- FAIL line when the file lacks the text.
has() {
  if grep -qF -- "$3" "$1"; then echo "--- PASS: pin: $2"; return 0; fi
  echo "--- FAIL: pin: $2"; return 1
}

# suite <GateBarsTrace.java> <ChooserActivity.java> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local gbt="$1" ca="$2" d s body rc=0 pos_lock pos_trace
  [ -f "$gbt" ] || { echo "--- FAIL: GateBarsTrace.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$gbt" "$d/src/com/nowhere/chooser/GateBarsTrace.java"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -nowarn -d "$d/out" \
    "$d/src/com/nowhere/chooser/GateBarsTrace.java" "$CASES" 2>"$d/javac.err" || { head -20 "$d/javac.err"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GateBarsTraceCases || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || return 3

  s=$(mktemp -p "$W") || return 3
  strip "$ca" "$s"
  body=$(mktemp -p "$W") || return 3
  perl -0ne 'print $1 if /public void onWindowFocusChanged\(boolean hasFocus\) \{(.*?)\n    \}\n/s' "$s" > "$body"
  if [ ! -s "$body" ]; then echo "--- FAIL: pin: cannot cut onWindowFocusChanged"; return 1; fi
  # CONTROL: the anchors see the method's existing LockTask work.
  has "$body" "control: onWindowFocusChanged re-arms LockTask" 'lockGate(true);' || rc=1
  has "$body" "onWindowFocusChanged asks GateBarsTrace.shouldTrace with the palette and the once-only flag" \
    'GateBarsTrace.shouldTrace(GatePalette.active().lightBars, barsTraced,' || rc=1
  has "$body" "onWindowFocusChanged sends GateTrace.ev(\"bars-light\", \"fields\", GateBarsTrace.value(...))" \
    'GateTrace.ev("bars-light", "fields", GateBarsTrace.value(' || rc=1
  has "$body" "onWindowFocusChanged sets barsTraced = true" 'barsTraced = true;' || rc=1
  pos_lock=$(grep -bo -F 'lockGate(true);' "$body" | head -1 | cut -d: -f1)
  pos_trace=$(grep -bo -F 'GateBarsTrace' "$body" | head -1 | cut -d: -f1)
  if [ -n "$pos_lock" ] && [ -n "$pos_trace" ] && [ "$pos_lock" -lt "$pos_trace" ]; then
    echo "--- PASS: pin: the trace comes after the LockTask re-arm"
  else
    echo "--- FAIL: pin: the trace is missing or comes before the LockTask re-arm"; rc=1
  fi
  return "$rc"
}

echo "== $GBT"
out=$(suite "$GBT" "$CA" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
echo "PASS"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
# mut <label> <which: gbt|ca> <perl-expr>
mut() {
  local d src m gf cf rc o
  d=$(mktemp -d -p "$W")
  gf="$GBT"; cf="$CA"
  case "$2" in gbt) src="$GBT" ;; ca) src="$CA" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in gbt) gf="$m" ;; ca) cf="$m" ;; esac
  o=$(suite "$gf" "$cf" 2>&1); rc=$?
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a --- FAIL"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 (G1) the dark-palette check removed"     gbt 's/return lightBars && !alreadyTraced/return !alreadyTraced/' || fails=$((fails+1))
mut "M2 (G2) the once-only flag removed"         gbt 's/lightBars && !alreadyTraced && /lightBars \&\& /' || fails=$((fails+1))
mut "M3 (G3) the sdk floor lowered to 29"        gbt 's/sdk >= 30/sdk >= 29/' || fails=$((fails+1))
mut "M4 (G4) the mask removed"                   gbt 's/return appearance & \(LIGHT_STATUS \| LIGHT_NAV\);/return appearance;/' || fails=$((fails+1))
mut "M5 (pin) the bars-light call removed"       ca  's/\n[^\n]*GateTrace\.ev\("bars-light"[^\n]*//' || fails=$((fails+1))
mut "M6 (pin) the shouldTrace guard is true"     ca  's/GateBarsTrace\.shouldTrace\(GatePalette\.active\(\)\.lightBars, barsTraced, android\.os\.Build\.VERSION\.SDK_INT\)/true/' || fails=$((fails+1))
mut "M7 (pin) the trace moved before LockTask"   ca  's/(public void onWindowFocusChanged\(boolean hasFocus\) \{\n\s*super\.onWindowFocusChanged\(hasFocus\);\n)/$1        GateBarsTrace.value(0);\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
