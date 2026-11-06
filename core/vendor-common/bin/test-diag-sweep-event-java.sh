#!/usr/bin/env bash
# test-diag-sweep-event-java.sh [--mutate] -- NWP-20261126-12: the Auto sweep's counts reach the session's day summary.
# The agent's handleDiagEvent (core/agent/day_summary.go, NWP-20261124-12) takes DIAG-EVENT with the argument line
# "sweep <apps> <ok> <fail> <ms>" (daySummaryEventRe) from the live session's own user, and appends `ev=sweep` while
# the session has opted in. UnarchiveService.sweepAuto sends it once, at its end, with the work list's counts.
# Compiles the chooser's pure DiagSweepEvent (java.* only) with core/chooser/tests/diag-sweep-event ALONE and
# EXECUTES the cases (C1-C5), pins the cases' copy of the regex to the agent (R1), then checks the REAL
# UnarchiveService over its code with comments dropped (P1-P6):
#   C1  arg(3, 2, 1, 4500) is exactly "sweep 3 2 1 4500".
#   C2  the agent's regex takes every line arg makes, and ok (group 2) comes before fail (group 3).
#   C3  a negative apps, ok, fail or ms is null.
#   C4  ms is clamped to 999999999999 (12 digits, the regex's bound).
#   C5  no line holds a newline or a carriage return.
#   R1  the cases' AGENT_RE is byte for byte daySummaryEventRe in core/agent/day_summary.go.
#   P1  sweepAuto stamps sweepT0 once, before the remembered taps.
#   P2  sweepAuto calls DiagSweepEvent.arg once, as arg(work.size(), done, failed, elapsedRealtime() - sweepT0).
#   P3  the send is DaemonSocket.roundTrip("DIAG-EVENT\n" + ev + "\n", 5000), behind ev != null, in a try/catch.
#   P4  the send block is guarded by its own `if (!work.isEmpty())`: an empty work list sends nothing.
#   P5  the send comes after the done log, the done log after the AUTO-SWEEP 0 finally, and no MAT_LOCK follows.
#   P6  UnarchiveService holds exactly one "DIAG-EVENT\n" (no second site).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-diag-sweep-event-java.sh            # the cases and the source checks
#   bash test-diag-sweep-event-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-diag-sweep-event-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-diag-sweep-event-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
GO=core/agent/day_summary.go
CASES=$ROOT/core/chooser/tests/diag-sweep-event/DiagSweepEventCases.java

# cases <root>: compile <root>'s DiagSweepEvent with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/DiagSweepEvent.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.DiagSweepEventCases
}

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` inside a string literal is kept). An empty signature reads the whole file.
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = $sig eq "" ? 1 : 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $sig ne "" && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3" ; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# regex <root>: R1, the cases' AGENT_RE against <root>'s daySummaryEventRe.
regex() {
  local go java
  go=$(perl -ne 'print $1 if /^var daySummaryEventRe = regexp\.MustCompile\(`([^`]*)`\)$/' "$1/$GO")
  java=$(perl -ne 'print $1 if /^\s*static final String AGENT_RE = "([^"]*)";$/' "$CASES")
  if [ -n "$go" ] && [ "$go" = "$java" ]; then
    echo "ok R1 the cases' AGENT_RE is the agent's daySummaryEventRe"
  else
    echo "FAIL R1 the cases' AGENT_RE is the agent's daySummaryEventRe (go='$go' java='$java')"; return 1
  fi
}

# sources <root>: P1-P6 over <root>'s UnarchiveService.java.
sources() {
  local r=$1 sweep whole bad=0
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  whole=$(code "$r/$CH/UnarchiveService.java" "")
  [ -n "$sweep" ] || { echo "FAIL P0 sweepAuto not found"; return 1; }
  pin P1 "sweepAuto stamps sweepT0 once, before the remembered taps" '
      my $n = () = $c =~ /final long sweepT0 = android\.os\.SystemClock\.elapsedRealtime\(\);/g; exit 1 unless $n == 1;
      $c =~ /final long sweepT0 = android\.os\.SystemClock\.elapsedRealtime\(\);.*?long tapSerial = -1;/s or exit 1;
      exit 0;' <<<"$sweep" || bad=1
  pin P2 "sweepAuto calls DiagSweepEvent.arg once, with apps = work.size(), ok = done, fail = failed, ms since sweepT0" '
      my $n = () = $c =~ /DiagSweepEvent\.arg\(/g; exit 1 unless $n == 1;
      $n = () = $c =~ /"DIAG-EVENT\\n"/g; exit 1 unless $n == 1;
      $c =~ /DiagSweepEvent\.arg\(work\.size\(\), done, failed, android\.os\.SystemClock\.elapsedRealtime\(\) - sweepT0\)/
        or exit 1;
      exit 0;' <<<"$sweep" || bad=1
  pin P3 "the send is roundTrip(\"DIAG-EVENT\\n\" + ev + \"\\n\", 5000), behind ev != null, in a try/catch that only logs" '
      $c =~ /if \(ev != null\) \{\s*try \{\s*String r = DaemonSocket\.roundTrip\("DIAG-EVENT\\n" \+ ev \+ "\\n", 5000\);.*?\}\s*catch \(Throwable t\) \{ android\.util\.Log\.w\([^;]*\); \}\s*\}/s
        or exit 1;
      exit 0;' <<<"$sweep" || bad=1
  pin P4 "the send block is guarded by its own if (!work.isEmpty()): an empty work list sends nothing" '
      $c =~ /if \(!work\.isEmpty\(\)\) \{\s*String ev = DiagSweepEvent\.arg\(/ or exit 1;
      exit 0;' <<<"$sweep" || bad=1
  pin P5 "the send follows the done log, the done log follows the AUTO-SWEEP 0 finally, and no MAT_LOCK follows the done log" '
      $c =~ /finally \{\s*DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n", 30000\);\s*\}\s*android\.util\.Log\.i\("NowhereChooser", "#130 sweep done: "/s
        or exit 1;
      my $at = index($c, "\"#130 sweep done: \""); exit 1 if $at < 0;
      my $tail = substr($c, $at);
      index($tail, "\"DIAG-EVENT\\n\"") >= 0 or exit 1;
      exit 1 if $tail =~ /MAT_LOCK/;
      exit 0;' <<<"$sweep" || bad=1
  pin P6 "UnarchiveService holds exactly one DIAG-EVENT send" '
      my $n = () = $c =~ /"DIAG-EVENT\\n"/g; exit($n == 1 ? 0 : 1);' <<<"$whole" || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  regex "$1" || rc=1
  sources "$1" || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH" "$d/core/agent"
  for n in "$CH/DiagSweepEvent.java" "$CH/UnarchiveService.java" "$GO"; do cp "$ROOT/$n" "$d/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
D=$CH/DiagSweepEvent.java
U=$CH/UnarchiveService.java
fails=0
mut "D1 ok and fail swapped in the line" "$D" 's/ok \+ " " \+ fail \+/fail + " " + ok +/' C1 || fails=$((fails+1))
mut "D2 ok and fail swapped at the call site" "$U" 's/DiagSweepEvent\.arg\(work\.size\(\), done, failed,/DiagSweepEvent.arg(work.size(), failed, done,/' P2 || fails=$((fails+1))
mut "D3 the send drops its trailing newline" "$U" 's/\+ ev \+ "\\n", 5000\)/+ ev, 5000)/' P3 || fails=$((fails+1))
mut "D4 an empty work list sends too" "$U" 's/if \(!work\.isEmpty\(\)\) \{(\s*String ev = DiagSweepEvent\.arg)/if (true) {$1/' P4 || fails=$((fails+1))
mut "D5 the ms clamp dropped" "$D" 's/Math\.min\(ms, MAX_MS\)/ms/' C4 || fails=$((fails+1))
mut "D6 a negative ms is sent" "$D" 's/ \|\| ms < 0//' C3 || fails=$((fails+1))
mut "D7 the send moved before the done log" "$U" 's/(        android\.util\.Log\.i\("NowhereChooser", "#130 sweep done: "[^\n]*\n[^\n]*\n)(.*?\n)(    \}\n)/$2$1$3/s' P5 || fails=$((fails+1))
mut "D8 the agent's regex changes" "$GO" 's/\^sweep \(\[0-9\]\{1,12\}\)/^sweep ([0-9]{1,11})/' R1 || fails=$((fails+1))
mut "D9 the start stamp dropped" "$U" 's/^[ \t]*final long sweepT0 = android\.os\.SystemClock\.elapsedRealtime\(\);[^\n]*\n//m' P1 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
