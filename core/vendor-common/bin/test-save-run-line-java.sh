#!/usr/bin/env bash
# test-save-run-line-java.sh [--mutate] [ProfileActivity.java] -- Your data's save line shows a running save's area,
# bytes and start time, run under javac (NWP-20261202-37).
#
# WHY THIS IS COMMITTED. While an automatic save ran, Your data said only "Saving automatically now…": no area, no
# progress, no start time, so the user could not tell a stuck save from a long one. The daemon already serves the
# save's frames ("SEALING <phase> <done> <total>[ <scope>]") on SEAL-STATUS for every run kind. Now loadSealDelta paints
# saveRunHead (the area, the bytes, "Started N min ago"), and startSaveLinesPoll repaints it from SEAL-STATUS every
# RUN_POLL_MS while the save runs, and loads the screen again once the save ends (DONE or FAILED). The poll reads
# with sealStatus(String[]), which writes no field: a tick can still run after the user left Your data and began a
# sign-out, and sealStatus() would overwrite the sealStatusReason that the sign-out loop copies after FAILED (RF-001).
#
# This lifts saveRunHead, startedAgo and the five frame readers they call (sealPhase, sealBytes, sealScope,
# sealScopeLabel, fmtBytes) out of ProfileActivity.java into one class, with the awk of test-seal-progress-java.sh,
# lifts sealStatus(), sealStatus(String[]), sealReasonOf and the sealStatusReason field into SealStatusLifted, compiles
# both with core/chooser/tests/save-run-line/SaveRunLineCases ALONE (it holds the scripted DaemonSocket and LocalSocket),
# and runs cases C1-C11. Source pins (comment lines stripped):
#   P1 loadSealDelta calls saveRunHead( once, reads runStart with the lastStart fallback and runProg, and sets
#      liveRun; "Saving automatically now…" occurs only inside saveRunHead.
#   P2 startSaveLinesPoll calls sealStatus(new String[1]) inside its thread, then saveRunHead(; it holds two
#      loadSealDelta(); and the second follows the sealStatus(new String[1]) line; it uses RUN_POLL_MS; it never calls
#      sealStatus(), the reader that writes sealStatusReason.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below; the
# version is printed first so the log proves which compiler ran. --mutate re-runs the suite against broken copies
# (S1-S11), each of which must FAIL; a mutant that does not apply (INERT) or does not build (BROKEN) is a failure.
#
#   bash test-save-run-line-java.sh                          # the cases and the pins
#   bash test-save-run-line-java.sh --mutate                 # ... plus the mutants
#   bash test-save-run-line-java.sh <ProfileActivity.java>   # against another copy
set -uo pipefail
MUTATE=no; args=()
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=yes ;;
    -*) echo "usage: $0 [--mutate] [ProfileActivity.java]" >&2; exit 2 ;;
    *) args+=("$a") ;;
  esac
done
[ "${#args[@]}" -le 1 ] || { echo "usage: $0 [--mutate] [ProfileActivity.java]" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PA=${args[0]:-$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java}
CASES=$ROOT/core/chooser/tests/save-run-line/SaveRunLineCases.java
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-save-run-line-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
for f in "$PA" "$CASES"; do [ -f "$f" ] || { echo "FAIL: $f does not exist"; exit 1; }; done
HELPERS="saveRunHead startedAgo sealPhase sealBytes sealScope sealScopeLabel fmtBytes"

# lift <ProfileActivity.java>: the helpers, signature line to closing brace, as one class (test-seal-progress-java.sh).
lift() {
  local src="$1" m
  echo "final class SaveRunLifted {"
  for m in $HELPERS; do
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$src" | sed 's/private static/static/'
  done
  echo "}"
}
# lift_status <ProfileActivity.java>: the SEAL-STATUS readers and the reason field, as one instance class.
lift_status() {
  local src="$1" sig
  echo "import java.io.BufferedReader;"
  echo "import java.io.InputStreamReader;"
  echo "final class SealStatusLifted {"
  grep -m1 -F '    private volatile String sealStatusReason;' "$src" | sed 's/^    private /    /'
  for sig in 'String sealStatus() {' 'String sealStatus(String[] reason) {' 'String sealReasonOf(String line) {'; do
    S="$sig" awk '
      !on && /^    [a-z]/ && index($0, ENVIRON["S"]) { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$src" | sed 's/^    private /    /'
  done
  echo "}"
}
# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces, comment lines dropped.
mbody() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print } on && /^    }$/ { exit }' "$1"
}
# fcount <body> <literal>: lines holding the fixed string.
fcount() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++ } END { print n + 0 }'; }
# fline <body> <literal> [from]: the first line number at or after <from> holding the fixed string, empty when none.
fline() { printf '%s\n' "$1" | S="$2" F="${3:-1}" awk 'NR >= ENVIRON["F"] + 0 && index($0, ENVIRON["S"]) { print NR; exit }'; }
# lline <body> <literal>: the last line number holding the fixed string, empty when none.
lline() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n = NR } END { if (n) print n }'; }

# pins <ProfileActivity.java> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local pa="$1" bad=0 lsd ssp srh all n l s r t
  lsd=$(mbody "$pa" 'private void loadSealDelta\(\) \{')
  ssp=$(mbody "$pa" 'private void startSaveLinesPoll\(final TextView mine\) \{')
  srh=$(mbody "$pa" 'private static String saveRunHead\(')
  for n in lsd ssp srh; do [ -n "${!n}" ] || { echo "  FAIL  pins: $n body not found"; bad=1; }; done

  # P1: loadSealDelta paints saveRunHead from runStart (lastStart when the daemon sends none) and runProg, and records
  # the run for the poll; the old fixed text lives only in saveRunHead.
  [ "$(fcount "$lsd" 'saveRunHead(')" -eq 1 ] \
    || { echo "  FAIL  P1 loadSealDelta does not call saveRunHead( exactly once"; bad=1; }
  l=$(fline "$lsd" 'o.has("runStart")')
  if [ -z "$l" ]; then echo "  FAIL  P1 loadSealDelta does not read o.has(\"runStart\")"; bad=1
  else
    case "$(printf '%s\n' "$lsd" | sed -n "${l}p")" in
      *'runStart = o.has("runStart") ? o.optLong("runStart", 0) : lastStart;'*) ;;
      *) echo "  FAIL  P1 loadSealDelta's runStart does not fall back to lastStart"; bad=1 ;;
    esac
  fi
  [ "$(fcount "$lsd" 'optString("runProg"')" -ge 1 ] || { echo "  FAIL  P1 loadSealDelta does not read runProg"; bad=1; }
  [ "$(fcount "$lsd" 'liveRun = ')" -ge 1 ] || { echo "  FAIL  P1 loadSealDelta does not set liveRun"; bad=1; }
  all=$(awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/' "$pa")
  n=$(fcount "$srh" 'Saving automatically now…'); t=$(fcount "$all" 'Saving automatically now…')
  [ "$n" -ge 1 ] && [ "$n" -eq "$t" ] \
    || { echo "  FAIL  P1 \"Saving automatically now…\" occurs outside saveRunHead ($t in the file, $n inside)"; bad=1; }

  # P2: the poll reads SEAL-STATUS inside its thread, repaints with saveRunHead after it, loads again once the run
  # ends, and ticks every RUN_POLL_MS while it runs.
  l=$(fline "$ssp" 'new Thread('); s=$(fline "$ssp" 'sealStatus(new String[1])')
  if [ -z "$s" ] || [ -z "$l" ] || [ "$s" -le "$l" ]; then
    echo "  FAIL  P2 startSaveLinesPoll does not call sealStatus(new String[1]) inside its thread"; bad=1
  else
    r=$(fline "$ssp" 'saveRunHead(' "$s")
    [ -n "$r" ] || { echo "  FAIL  P2 startSaveLinesPoll does not call saveRunHead( after sealStatus()"; bad=1; }
    n=$(lline "$ssp" 'loadSealDelta();')
    if [ "$(fcount "$ssp" 'loadSealDelta();')" -ne 2 ] || [ -z "$n" ] || [ "$n" -le "$s" ]; then
      echo "  FAIL  P2 startSaveLinesPoll does not load again (loadSealDelta();) after sealStatus(new String[1]) when the run ends"; bad=1
    fi
  fi
  [ "$(fcount "$ssp" 'sealStatus()')" -eq 0 ] \
    || { echo "  FAIL  P2 startSaveLinesPoll calls sealStatus(), which overwrites the sign-out loop's sealStatusReason"; bad=1; }
  [ "$(fcount "$ssp" 'RUN_POLL_MS')" -ge 1 ] || { echo "  FAIL  P2 startSaveLinesPoll does not use RUN_POLL_MS"; bad=1; }
  [ "$bad" -eq 0 ]
}

# suite <ProfileActivity.java>: 0 pass, 1 a case or pin failed, 2 an extraction missed, 3 did not compile.
suite() {
  local pa="$1" d m out rc
  d=$(mktemp -d -p "$W") || return 2
  lift "$pa" > "$d/SaveRunLifted.java"
  for m in $HELPERS; do
    grep -q " $m(" "$d/SaveRunLifted.java" || { echo "  MISS  $m not extracted from ProfileActivity.java"; return 2; }
  done
  lift_status "$pa" > "$d/SealStatusLifted.java"
  for m in 'String sealReasonOf(' 'String sealStatus() {' 'String sealStatus(String[] reason) {' 'String sealStatusReason;'; do
    grep -qF "$m" "$d/SealStatusLifted.java" || { echo "  MISS  $m not extracted from ProfileActivity.java"; return 2; }
  done
  cp "$CASES" "$d/"
  out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d/SaveRunLifted.java" "$d/SealStatusLifted.java" "$d/SaveRunLineCases.java" 2>&1) \
    || { echo "  BUILD javac failed"; printf '%s\n' "$out" | head -20; return 3; }
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" SaveRunLineCases 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'
  [ "$rc" -eq 0 ] || return 1
  pins "$pa" || return 1
  echo "  pins: ok"
}

echo "== $PA"
suite "$PA"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc=$rc)"; [ "$rc" = 2 ] && exit 2; exit 1; }
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report"; exit 1; }
FAILS=0
# mut <label> <perl-expr>: a broken copy of ProfileActivity.java; the suite must convict it (rc 1).
mut() {
  local label="$1" d m out rc
  d=$(mktemp -d -p "$W") || { FAILS=$((FAILS + 1)); return; }
  m="$d/ProfileActivity.java"
  cp "$PA" "$m"
  if ! perl -0pi -e "$2" "$m"; then echo "  ERROR     $label -- perl failed"; FAILS=$((FAILS + 1)); return; fi
  if cmp -s "$PA" "$m"; then echo "  INERT     $label -- the mutation changed nothing"; FAILS=$((FAILS + 1)); return; fi
  out=$(suite "$m"); rc=$?
  case "$rc" in
    1) echo "  CONVICTED $label --$(printf '%s\n' "$out" | grep -m1 'FAIL' | sed 's/^ *FAIL//')" ;;
    0) echo "  SURVIVED  $label"; FAILS=$((FAILS + 1)) ;;
    *) echo "  BROKEN    $label (rc=$rc)"; printf '%s\n' "$out" | head -20; FAILS=$((FAILS + 1)) ;;
  esac
}
echo "== mutants (each must be CONVICTED)"
mut "S1 the Started line is dropped (C3)" 's/\n *if \(runStart > 0\) head \+= "\\nStarted " \+ startedAgo\(runStart, nowSec\) \+ "\.";//'
mut "S2 the sizes phase shows bytes (C4)" 's/head = "sizes"\.equals\(sealPhase\(line\)\) \? lead : lead \+/head = lead +/'
mut "S3 the dt[1] > 0 guard is removed (C5)" 's/(private static String saveRunHead\(.*?)if \(dt != null && dt\[1\] > 0\) \{/${1}if (dt != null) {/s'
mut "S4 the manual and automatic arms are swapped (C6)" 's/boolean manual = "manual"\.equals\(run\);/boolean manual = !"manual".equals(run);/'
mut "S5 startedAgo says just now under 60 s, not 90 s (C7)" 's/(private static String startedAgo\(.*?)if \(d < 90\)/${1}if (d < 60)/s'
mut "S6 startedAgo counts hours as minutes (C8)" 's/(private static String startedAgo\(.*?)return \(d \/ 3600\)/${1}return (d \/ 60)/s'
mut "S7 the lastStart fallback is removed (P1)" 's/o\.optLong\("runStart", 0\) : lastStart;/o.optLong("runStart", 0) : 0;/'
mut "S8 the poll never reads SEAL-STATUS (P2)" 's/String s = sealStatus\(new String\[1\]\);/String s = null;/'
mut "S9 the poll does not load again when the run ends (P2)" 's/(liveRun = "";)\n *loadSealDelta\(\);/$1/'
mut "S10 the poll reads with sealStatus(), which writes sealStatusReason (P2)" 's/String s = sealStatus\(new String\[1\]\);/String s = sealStatus();/'
mut "S11 the poll's reader clears sealStatusReason (C11)" 's/private static String sealStatus\(String\[\] reason\) \{\n        reason\[0\] = null;/private String sealStatus(String[] reason) {\n        sealStatusReason = null;\n        reason[0] = null;/'
[ "$FAILS" = 0 ] || { echo "FAILED: $FAILS mutant(s) not convicted"; exit 1; }
echo "PASS: 11 of 11 mutants convicted"
