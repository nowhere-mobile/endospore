#!/usr/bin/env bash
# test-sweep-snapshot-java.sh [--mutate] -- NWP-20261203-07 (backlog: "P1: An Auto sweep stalls after its first fetch
# and no app installs for the rest of the session ..."): every in-session and scheduled report carries sweep_state,
# sweep_stack, lane_stack and chooser_up_s, so the next stalled sweep's report names the frame it is blocked in.
# Compiles the chooser's pure SweepSnapshot (java.lang only) with core/chooser/tests/sweep-snapshot ALONE and EXECUTES
# the cases (C1-C10), lifts sweepAutoJoined's sweep-thread publication and clear into a harness and EXECUTES the race
# cases (R1-R3), then checks the REAL UnarchiveService and ProfileActivity over their code with comments dropped
# (S1-S4):
#   C1  no sweep thread reads exactly `idle`.          C2  running with a free lane is the whole line (age_s in s).
#   C3  the sweep holding the lane is lane=sweep.      C4  a tap holding the lane is lane=tap, and tapHolder is it.
#   C5  com.example.app.Main.run and a lambda in an unknown package are `?`.
#   C6  a chooser frame and an android.os.BinderProxy frame keep class, method and line, joined by ` < `.
#   C7  13 frames are cut to 12.                       C8  a 2000-char frame is cut to 1500 chars.
#   C9  no output carries a thread's name.
#   C10 the agent's reIssueKV pattern (read from core/agent/report_issue.go) leaves the state line and frames whole.
#   R0  the publication (the statements between `while (true) {` and `LANDING.set(`) and the clear (between the outer
#       `finally {` and `SweepWake.end(`) are found, and the clear's ownership check is rewritten to SweepSlotRace.seen.
#   R1  the reviewed order: sweep A passes its ownership check after SweepJoin.exit, sweep B publishes, A clears. B's
#       publication waits for A's clear (it is BLOCKED), and B is still the sweep thread afterwards.
#   R2  one sweep that publishes and clears leaves no sweep thread.
#   R3  a sweep's clear after another sweep published leaves the other sweep's thread.
#   S1  reportStatus puts sweep_state, sweep_stack, lane_stack and chooser_up_s inside ONE try / catch (Throwable),
#       each once in the method, and every call that can throw runs before the first of those puts.
#   S2  MAT_LOCK is an OwnedLock, a fair ReentrantLock (`super(true)`) whose owner() returns getOwner().
#   S3  sweepAutoJoined: `while (true) {` starts with sweepPassBegin() and the outer finally is `sweepPassEnd();
#       SweepWake.end(...)` (NWP-20261203-03's pass helpers); sweepPassBegin's SweepStall-monitor block starts with one
#       `synchronized (SWEEP_SLOT)` block setting SWEEP_SINCE and SWEEP_THREAD, and sweepPassEnd's clears SWEEP_THREAD
#       (when it is this thread) in one `synchronized (SWEEP_SLOT)` block; snapshot() reads both fields under
#       SWEEP_SLOT.
#   S4  SweepSnapshot.java has no import and no getName(.
#
# It needs a JDK and perl, and it FAILS when there is none. javac/java come from PATH, then the build VM's JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-sweep-snapshot-java.sh            # the cases and the source checks
#   bash test-sweep-snapshot-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-snapshot-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-snapshot-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-snapshot/SweepSnapshotCases.java
RACE=$ROOT/core/chooser/tests/sweep-snapshot/SweepSlotRace.java
STUB=$ROOT/core/chooser/tests/sweep-snapshot/stubs/android/os/SystemClock.java
# The agent's KEY=VALUE scrub, the one statusValue applies to every chooser status value.
KV=$(perl -ne 'print "$1\n" if /^\s*reIssueKV\s*=\s*regexp\.MustCompile\(`([^`]+)`\)/' "$ROOT/core/agent/report_issue.go")

# cases <root>: compile <root>'s SweepSnapshot with the cases into a fresh dir and run them.
cases() {
  local d
  [ -n "$KV" ] || { echo "FAIL C0 no reIssueKV pattern in core/agent/report_issue.go"; return 1; }
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepSnapshot.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepSnapshotCases "$KV"
}

# race <root>: lift <root>'s sweep-thread publication (sweepPassBegin's SweepStall-monitor block, up to its
# Thread.interrupted()) and clear (sweepPassEnd's monitor block) into SweepSlotHarness, compile it with SweepSlotRace
# and the SystemClock stub, and run R1-R3. 1 when the lift fails (R0), 3 when it does not compile.
race() {
  local d h
  d=$(mktemp -d -p "$W")
  h="$d/SweepSlotHarness.java"
  { code "$1/$CH/UnarchiveService.java" "    private static void sweepPassBegin() {"; echo "<<<SPLIT>>>"
    code "$1/$CH/UnarchiveService.java" "    private static void sweepPassEnd() {"; } | perl -0e '
    my $c = do { local $/; <STDIN> };
    my ($b, $e) = split /\n<<<SPLIT>>>\n/, $c, 2;
    $b =~ /synchronized \(SweepStall\.class\) \{\s*(.*?)\s*Thread\.interrupted\(\);/s or exit 1;
    my $pub = $1;
    $e =~ /synchronized \(SweepStall\.class\) \{\s*(.*?)\s*\}\s*\z/s or exit 1;
    my $clr = $1;
    $clr =~ s/\(SWEEP_THREAD == Thread\.currentThread\(\)\)/(SweepSlotRace.seen(SWEEP_THREAD == Thread.currentThread()))/ == 1 or exit 1;
    print "package com.nowhere.chooser;\n",
          "final class SweepSlotHarness {\n",
          "    private static final Object SWEEP_SLOT = new Object();\n",
          "    static volatile Thread SWEEP_THREAD;\n",
          "    static volatile long SWEEP_SINCE;\n",
          "    static void publish() {\n$pub\n    }\n",
          "    static void clear() {\n$clr\n    }\n",
          "}\n";' >"$h" || { echo "FAIL R0 the sweep-thread publication or its clear was not found in sweepPassBegin / sweepPassEnd"; return 1; }
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$h" "$RACE" "$STUB" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepSlotRace
}

# code <file> [<signature line>]: the method from its signature to its closing `    }` (with no signature, the whole
# file), with whole-line comments dropped and trailing `//` comments stripped (a `//` inside a string literal is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = defined($sig) ? 0 : 1;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if defined($sig) && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$@"
}

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3" ; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# sources <root>: S1-S4 over <root>'s ProfileActivity.java, UnarchiveService.java and SweepSnapshot.java.
sources() {
  local r=$1 rs joined pb pe whole snap bad=0
  rs=$(code "$r/$CH/ProfileActivity.java" "    static org.json.JSONObject reportStatus(android.content.Context ctx) throws org.json.JSONException {")
  joined=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAutoJoined(boolean byHand) {")
  pb=$(code "$r/$CH/UnarchiveService.java" "    private static void sweepPassBegin() {")
  pe=$(code "$r/$CH/UnarchiveService.java" "    private static void sweepPassEnd() {")
  whole=$(code "$r/$CH/UnarchiveService.java")
  snap=$(code "$r/$CH/SweepSnapshot.java")
  [ -n "$rs" ] || { echo "FAIL S0 reportStatus not found"; return 1; }
  [ -n "$joined" ] || { echo "FAIL S0 sweepAutoJoined not found"; return 1; }
  [ -n "$pb" ] && [ -n "$pe" ] || { echo "FAIL S0 sweepPassBegin or sweepPassEnd not found"; return 1; }
  pin S1 "reportStatus puts sweep_state, sweep_stack, lane_stack and chooser_up_s in one try / catch (Throwable), after every call that can throw" '
      my @k = qw(sweep_state sweep_stack lane_stack chooser_up_s);
      for my $k (@k) { my $n = () = $c =~ /\bst\.put\("\Q$k\E"/g; exit 1 unless $n == 1; }
      my $found = 0;
      while ($c =~ /\btry (\{(?:[^{}]++|(?1))*\})\s*catch \(Throwable \w+\) \{\s*\}/g) {
        my $b = $1;
        next unless index($b, "st.put(\"sweep_state\"") >= 0;
        for my $k (@k) { exit 1 if index($b, "st.put(\"$k\"") < 0; }
        my $first = length($b);
        for my $k (@k) { my $i = index($b, "st.put(\"$k\""); $first = $i if $i < $first; }
        my $last = -1;
        for my $p ("SweepSnapshot.", "snapshot()", "getStackTrace()", "getStartElapsedRealtime()", "elapsedRealtime()") {
          my $i = rindex($b, $p); $last = $i if $i > $last;
        }
        exit 1 if $last < 0 || $last > $first;
        $found = 1;
      }
      exit($found ? 0 : 1);' <<<"$rs" || bad=1
  pin S2 "MAT_LOCK is an OwnedLock: a fair ReentrantLock (super(true)) whose owner() returns getOwner()" '
      $c =~ /private static final OwnedLock MAT_LOCK\s*=\s*new OwnedLock\(\);/ or exit 1;
      $c =~ /static final class OwnedLock extends java\.util\.concurrent\.locks\.ReentrantLock \{\s*OwnedLock\(\) \{ super\(true\); \}\s*Thread owner\(\) \{ return getOwner\(\); \}\s*\}/ or exit 1;
      exit 0;' <<<"$whole" || bad=1
  pin S3 "sweepAutoJoined begins each pass with sweepPassBegin, which sets SWEEP_SINCE and SWEEP_THREAD under SWEEP_SLOT first, and its outer finally calls sweepPassEnd, which clears SWEEP_THREAD under SWEEP_SLOT, before SweepWake.end" '
      my ($j, $b, $e) = split /\n<<<SPLIT>>>\n/, $c, 3;
      $j =~ /while \(true\) \{\s*sweepPassBegin\(\);/ or exit 1;
      $j =~ /\}\s*finally \{\s*sweepPassEnd\(\);\s*SweepWake\.end\(\w+\);\s*\}\s*\z/s or exit 1;
      $b =~ /\{\s*synchronized \(SweepStall\.class\) \{\s*synchronized \(SWEEP_SLOT\) \{\s*SWEEP_SINCE = android\.os\.SystemClock\.elapsedRealtime\(\);\s*SWEEP_THREAD = Thread\.currentThread\(\);\s*\}/ or exit 1;
      $e =~ /\{\s*synchronized \(SweepStall\.class\) \{\s*synchronized \(SWEEP_SLOT\) \{ if \(SWEEP_THREAD == Thread\.currentThread\(\)\) SWEEP_THREAD = null; \}\s*\}\s*\z/s or exit 1;
      exit 0;' <<<"$joined
<<<SPLIT>>>
$pb
<<<SPLIT>>>
$pe" || bad=1
  pin S3 "snapshot() reads SWEEP_THREAD and SWEEP_SINCE together under SWEEP_SLOT, and SWEEP_SLOT is one private final Object" '
      $c =~ /private static final Object SWEEP_SLOT = new Object\(\);/ or exit 1;
      $c =~ /static SweepSnapshot\.Input snapshot\(\) \{[^}]*?synchronized \(SWEEP_SLOT\) \{ sweep = SWEEP_THREAD; since = SWEEP_SINCE; \}/s or exit 1;
      exit 0;' <<<"$whole" || bad=1
  pin S4 "SweepSnapshot.java imports nothing and never reads a thread name" '
      exit 1 unless $c =~ /final class SweepSnapshot\b/;
      exit 1 if $c =~ /^\s*import\s/m;
      exit 1 if index($c, "getName(") >= 0;
      exit 0;' <<<"$snap" || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  race "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  return "$rc"
}

if check "$ROOT"; then echo "test-sweep-snapshot-java: cases and source checks pass"; else echo "test-sweep-snapshot-java: FAILED"; exit 1; fi
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in "$CH/SweepSnapshot.java" "$CH/UnarchiveService.java" "$CH/ProfileActivity.java"; do cp "$ROOT/$n" "$d/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4 " <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  CONVICTED $1 (fails '$4')"
}
S=$CH/SweepSnapshot.java
U=$CH/UnarchiveService.java
P=$CH/ProfileActivity.java
fails=0
mut "M1 the prefix filter removed" "$S" 's/if \(e != null && shared\(e\.getClassName\(\)\)\) \{/if (e != null) {/' C5 || fails=$((fails+1))
mut "M2 the 12-frame cap removed" "$S" 's/static final int MAX_FRAMES = 12;/static final int MAX_FRAMES = 1000;/' C7 || fails=$((fails+1))
mut "M3 lane=tap reported as sweep" "$S" 's/tapHolder\(in\) != null \? "tap" : "sweep"/tapHolder(in) != null ? "sweep" : "sweep"/' C4 || fails=$((fails+1))
mut "M4 the thread name added" "$S" 's/(\+ " workers=" \+ in\.workers)/$1 + " name=" + in.sweep.getName()/' C9 || fails=$((fails+1))
mut "M5 the fair flag dropped" "$U" 's/OwnedLock\(\) \{ super\(true\); \}/OwnedLock() { super(false); }/' S2 || fails=$((fails+1))
mut "M6 the clear in the finally removed" "$U" 's/\n[ \t]*synchronized \(SWEEP_SLOT\) \{ if \(SWEEP_THREAD == Thread\.currentThread\(\)\) SWEEP_THREAD = null; \}//' S3 || fails=$((fails+1))
mut "M7 the 1500-char cap removed" "$S" 's/static final int MAX_CHARS = 1500;/static final int MAX_CHARS = 100000;/' C8 || fails=$((fails+1))
mut "M8 age_s renamed pass_s" "$S" 's/"running age_s="/"running pass_s="/' C10 || fails=$((fails+1))
mut "M9 chooser_up_s put moved outside the try" "$P" 's/\n([ \t]*)st\.put\("chooser_up_s", up\);(\n[ \t]*\} catch \(Throwable ignore\) \{\})/$2\n$1st.put("chooser_up_s", "0");/' S1 || fails=$((fails+1))
mut "M10 the clear outside SWEEP_SLOT" "$U" 's/synchronized \(SWEEP_SLOT\) \{ (if \(SWEEP_THREAD == Thread\.currentThread\(\)\) SWEEP_THREAD = null;) \}/$1/' R1 || fails=$((fails+1))
mut "M11 the publication outside SWEEP_SLOT" "$U" 's/synchronized \(SWEEP_SLOT\) \{(\s*SWEEP_SINCE = android\.os\.SystemClock\.elapsedRealtime\(\);\s*SWEEP_THREAD = Thread\.currentThread\(\);\s*)\}/{$1}/' R1 || fails=$((fails+1))
mut "M12 the ownership check dropped from the clear" "$U" 's/if \(SWEEP_THREAD == Thread\.currentThread\(\)\) SWEEP_THREAD = null;/if ((SWEEP_THREAD == Thread.currentThread()) \|\| true) SWEEP_THREAD = null;/' R3 || fails=$((fails+1))
mut "M13 snapshot() reads outside SWEEP_SLOT" "$U" 's/synchronized \(SWEEP_SLOT\) \{ sweep = SWEEP_THREAD; since = SWEEP_SINCE; \}/{ sweep = SWEEP_THREAD; since = SWEEP_SINCE; }/' S3 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
