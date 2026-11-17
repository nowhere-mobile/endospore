#!/usr/bin/env bash
# test-sweep-stall-java.sh [--mutate] -- NWP-20261203-03, the backlog row "P1: An Auto sweep stalls after its first fetch
# and no app installs for the rest of the session ...": the Auto sweep names a step with no progress in login.log
# (AUTO-SWEEP-STEP, fixed tokens, never a package) and abandons the pass after 25 minutes without progress.
# Compiles the chooser's pure SweepStall (java.lang only) with core/chooser/tests/sweep-stall ALONE and EXECUTES the
# cases (S1-S7); builds SweepPass from the REAL UnarchiveService sweepPassBegin, sweepPassEnd, sweepSockOwn and
# sweepSockRelease and EXECUTES core/chooser/tests/sweep-stall/SweepPassCases.java over it (R1-R4); then checks the
# sources (T1-T4) and the REAL UnarchiveService over its code with comments dropped (P1-P5):
#   S1  no line before STALL_MS (5 min) without progress.   S2  a stall at 5 min, again at 15, not at 10.
#   S3  progress moves the next stall and the abandon.      S4  a step that ends after a reported stall gets ONE
#       `ended` at the next tick, before a due stall; a step change with no stall sends none; reset() and close() of
#       the current pass end a stalled step too, and close() of an earlier pass changes nothing.
#   S5  `abandoned` and abandon() once at HARD_MS (25 min); abandoned() true until reset(); the stall lines go on.
#   S6  request() is exactly "AUTO-SWEEP-STEP\n<kind>\n<step>\n<i>\n<n>\n<secs>\n" at 0/0/0 and 9999/9999/86400, and
#       null for i < 0, i > n, n > 9999, secs < 0, secs > 86400, an unknown or null kind or step.
#   S7  an idle tick sends nothing; enter() with an unknown token changes nothing.
#   R1  C begins a pass, D begins one (a new start after C's SweepJoin.exit), C's outer finally ends: SWEEP_THREAD
#       stays D, so the new sweep keeps its watch and its bound; an owner's own end clears it.
#   R2  an old socket's release after a newer pass owns a socket leaves that socket; a tap's socket is not owned.
#   R3  a begin clears the thread's interrupt and starts a new, not abandoned pass; after an abandon the sweep
#       thread's next socket is closed and refused.
#   R4  tick's abandon runs under the SweepStall monitor, and not at all when a send of that tick starts a new pass:
#       an earlier pass's cancellation never reaches a fresh pass.
#   T1  SweepStall.STEPS equals core/agent/auto_sweep.go autoSweepStepTokens, literal for literal, in order.
#   T2  SweepStall.KINDS equals autoSweepStepKinds.
#   T3  HARD_MS > UnarchiveService.READ_CAP_MS + DaemonSocket.CONNECT_CAP_MS, read from the sources: a daemon call
#       that hits its own caps returns before the pass is abandoned.
#   T4  SweepStall.java imports nothing.
#   P1  each of the three sweepAuto loops tests SweepStall.abandoned(): the remembered-tap loop first in its body, the
#       restore-only chunk loop before its MAT_LOCK.lock(), and the work loop before `String pkg = work.get(i);` in a
#       block that qDrops the rest, sends ONE `stopped` SweepOutcome.request for app i + 1 behind a null check, breaks.
#   P2  both step( helpers return unless Thread.currentThread() is SWEEP_THREAD, and stepProgress( unless it is, or
#       the sweep's step is SweepStall.LOCK.
#   P3  sweepAutoJoined's `while (true)` body starts sweepPassBegin(); startSweepWatch(); sweepPassBegin is ONE
#       synchronized (SweepStall.class) block of NWP-20261203-07's synchronized (SWEEP_SLOT) { SWEEP_SINCE = ...;
#       SWEEP_THREAD = Thread.currentThread(); }, Thread.interrupted(); SweepStall.reset(); the outer finally is
#       `sweepPassEnd(); SweepWake.end(wake);`; sweepPassEnd clears SWEEP_THREAD only while it is the current thread,
#       under the same monitor (and SWEEP_SLOT), and holds the file's only `SWEEP_THREAD = null;`; SWEEP_THREAD is
#       declared once.
#   P4  daemon( and daemonMaterialize( own the socket through sweepSockOwn (refused: an IOException) and release it in
#       their finally through sweepSockRelease; both are synchronized (SweepStall.class), and the file's only
#       `SWEEP_SOCK = ` writes are theirs; the watch's abandon interrupts SWEEP_THREAD and closes SWEEP_SOCK; the
#       watch sends through sweepStallSend, which is DaemonSocket.roundTrip(<its argument>, 5000) behind a null check.
#   P5  no SweepStall.request( or sweepStallSend( argument names pkg, label, dep or work.get.
#
# It needs a JDK and perl, and it FAILS when there is none. javac/java come from PATH, then the build VM's JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass:
#   M1 the STALL_MS compare flipped (S1)        M2 the repeat removed (S2)          M3 progress ignored (S3)
#   M4 the abandon fires twice (S5)             M5 HARD_MS 20 min (T3)              M6 the work loop's abandon block removed (P1)
#   M7 the SWEEP_THREAD guard in step( removed (P2)                                 M8 the SWEEP_THREAD clear removed (P3)
#   M9 sweepPassEnd clears whoever owns the sweep (R1)                             M10 tick abandons a newer pass (R4)
#   M11 sweepSockRelease clears whichever socket is SWEEP_SOCK (R2)                M12 reset() out of sweepPassBegin's lock (P3)
#
#   bash test-sweep-stall-java.sh            # the cases and the source checks
#   bash test-sweep-stall-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-stall-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-stall-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
GO=core/agent/auto_sweep.go
CASES=$ROOT/core/chooser/tests/sweep-stall/SweepStallCases.java
PCASES=$ROOT/core/chooser/tests/sweep-stall/SweepPassCases.java

# cases <root>: compile <root>'s SweepStall with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepStall.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepStallCases
}

# passcases <root>: SweepPass from <root>'s UnarchiveService pass and socket helpers (LocalSocket read as
# AutoCloseable, android.os.SystemClock.elapsedRealtime() as the JVM's monotonic clock; SWEEP_SLOT and SWEEP_SINCE are
# NWP-20261203-07's), compiled with <root>'s SweepStall and SweepPassCases into a fresh dir, and run.
passcases() {
  local d m body
  d=$(mktemp -d -p "$W")
  {
    printf 'package com.nowhere.chooser;\nfinal class SweepPass {\n'
    printf '    static volatile Thread SWEEP_THREAD;\n    static volatile AutoCloseable SWEEP_SOCK;\n'
    printf '    private static final Object SWEEP_SLOT = new Object();\n    static volatile long SWEEP_SINCE;\n'
    for m in "private static void sweepPassBegin() {" "private static void sweepPassEnd() {" \
             "private static boolean sweepSockOwn(LocalSocket s) {" "private static void sweepSockRelease(LocalSocket s) {"; do
      body=$(code "$1/$CH/UnarchiveService.java" "    $m")
      [ -n "$body" ] || { echo "FAIL R0 $m not found"; return 3; }
      printf '%s\n    }\n' "$body" | sed 's/LocalSocket/AutoCloseable/g; s/private static/static/; s/android\.os\.SystemClock\.elapsedRealtime()/(System.nanoTime() \/ 1000000L)/g'
    done
    printf '}\n'
  } > "$d/SweepPass.java" || return 3
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$d/SweepPass.java" "$1/$CH/SweepStall.java" "$PCASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepPassCases
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

# sources <root>: T1-T4 and P1-P5 over <root>'s sources.
sources() {
  local r=$1 st go us ds sweep joined s3 s1 sp watch dm dmat pb pe so sr v bad=0
  st=$(code "$r/$CH/SweepStall.java")
  go=$(cat "$r/$GO" 2>/dev/null)
  us=$(code "$r/$CH/UnarchiveService.java")
  ds=$(code "$r/$CH/DaemonSocket.java")
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  joined=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAutoJoined(boolean byHand) {")
  s3=$(code "$r/$CH/UnarchiveService.java" "    private static void step(String token, int i, int n) {")
  s1=$(code "$r/$CH/UnarchiveService.java" "    private static void step(String token) {")
  sp=$(code "$r/$CH/UnarchiveService.java" "    private static void stepProgress() {")
  watch=$(code "$r/$CH/UnarchiveService.java" "    private static void startSweepWatch() {")
  dm=$(code "$r/$CH/UnarchiveService.java" "    private String daemon(String msg) {")
  dmat=$(code "$r/$CH/UnarchiveService.java" "    private String daemonMaterialize(String pkg) {")
  pb=$(code "$r/$CH/UnarchiveService.java" "    private static void sweepPassBegin() {")
  pe=$(code "$r/$CH/UnarchiveService.java" "    private static void sweepPassEnd() {")
  so=$(code "$r/$CH/UnarchiveService.java" "    private static boolean sweepSockOwn(LocalSocket s) {")
  sr=$(code "$r/$CH/UnarchiveService.java" "    private static void sweepSockRelease(LocalSocket s) {")
  for v in st go us ds sweep joined s3 s1 sp watch dm dmat pb pe so sr; do
    [ -n "${!v}" ] || { echo "FAIL P0 $v not found"; bad=1; }
  done
  [ "$bad" -eq 0 ] || return 1
  # T1/T2: the Java array literal and the Go array literal, string for string.
  local t
  for t in "T1 STEPS autoSweepStepTokens" "T2 KINDS autoSweepStepKinds"; do
    set -- $t
    pin "$1" "SweepStall.$2 equals core/agent/auto_sweep.go $3, literal for literal, in order" '
        my ($j, $g) = split /\n<<<SPLIT>>>\n/, $c, 2;
        $j =~ /static final String\[\] '"$2"' = \{([^}]*)\};/s or exit 1; my $ja = $1;
        my %k; while ($j =~ /static final String (\w+) = "([^"]*)";/g) { $k{$1} = $2; }
        my @jv = map { s/^\s+|\s+$//gr } split /,/, $ja; @jv = map { exists $k{$_} ? $k{$_} : "?$_" } @jv;
        $g =~ /var '"$3"' = \[\.\.\.\]string\{([^}]*)\}/ or exit 1;
        my @gv = ($1 =~ /"([^"]*)"/g);
        exit 1 unless @jv && "@jv" eq "@gv";
        exit 0;' <<<"$st
<<<SPLIT>>>
$go" || bad=1
  done
  pin T3 "HARD_MS is above UnarchiveService.READ_CAP_MS + DaemonSocket.CONNECT_CAP_MS" '
      my ($s, $u, $d) = split /\n<<<SPLIT>>>\n/, $c, 3;
      sub val { my ($src, $name) = @_; $src =~ /\b\Q$name\E = ([0-9L_* ]+);/ or return undef;
                (my $e = $1) =~ s/[L_]//g; $e =~ /^[0-9* ]+$/ or return undef; return eval $e; }
      my ($h, $rc, $cc) = (val($s, "HARD_MS"), val($u, "READ_CAP_MS"), val($d, "CONNECT_CAP_MS"));
      exit 1 unless defined $h && defined $rc && defined $cc && $h > $rc + $cc;
      exit 0;' <<<"$st
<<<SPLIT>>>
$us
<<<SPLIT>>>
$ds" || bad=1
  pin T4 "SweepStall.java imports nothing" '
      exit 1 if $c =~ /^\s*import\s/m; exit 1 unless $c =~ /final class SweepStall\b/; exit 0;' <<<"$st" || bad=1
  pin P1 "the remembered-tap, restore-only and work loops of sweepAuto each test SweepStall.abandoned(); the work loop drops the rest, sends one stopped for app i + 1 and breaks" '
      $c =~ /for \(int k = 0; k < remembered\.size\(\)[^{]*\{\s*if \(SweepStall\.abandoned\(\)\) break;/ or exit 1;
      $c =~ /c \+= OdRestoreList\.CHUNK\) \{((?:(?!MAT_LOCK\.lock\(\)).)*)MAT_LOCK\.lock\(\);/s or exit 1;
      index($1, "if (SweepStall.abandoned()) break;") >= 0 or exit 1;
      $c =~ /for \(int i = 0; i < work\.size\(\); i\+\+\) \{((?:(?!String pkg = work\.get\(i\);).)*)String pkg = work\.get\(i\);/s or exit 1;
      $1 =~ /if \(SweepStall\.abandoned\(\)\) \{\s*qDrop\(SignOutGate\.rest\(work, i\)\);\s*String (\w+) = SweepOutcome\.request\(i \+ 1, work\.size\(\), SweepOutcome\.STOPPED, 0\);\s*if \(\1 != null\) DaemonSocket\.roundTrip\(\1, 5000\);[^{}]*\bbreak;\s*\}/s or exit 1;
      exit 0;' <<<"$sweep" || bad=1
  pin P2 "step( acts only on SWEEP_THREAD; stepProgress( on SWEEP_THREAD or while the sweep waits for the lock" '
      my ($a, $b, $p) = split /\n<<<SPLIT>>>\n/, $c, 3;
      for my $m ($a, $b) { $m =~ /\{\s*if \(Thread\.currentThread\(\) != SWEEP_THREAD\) return;\s*SweepStall\.enter\(/ or exit 1; }
      $p =~ /\{\s*if \(Thread\.currentThread\(\) != SWEEP_THREAD && !SweepStall\.LOCK\.equals\(SweepStall\.step\(\)\)\) return;\s*SweepStall\.progress\(/ or exit 1;
      exit 0;' <<<"$s3
<<<SPLIT>>>
$s1
<<<SPLIT>>>
$sp" || bad=1
  pin P3 "each pass begins with sweepPassBegin (SWEEP_THREAD with SWEEP_SINCE under SWEEP_SLOT, the cleared interrupt and SweepStall.reset in one SweepStall-monitor block) and the watch; the outer finally ends it with sweepPassEnd, which clears SWEEP_THREAD only while it is this thread" '
      my ($j, $w, $b, $e) = split /\n<<<SPLIT>>>\n/, $c, 4;
      $j =~ /while \(true\) \{\s*sweepPassBegin\(\);\s*startSweepWatch\(\);/ or exit 1;
      $j =~ /\}\s*finally \{ sweepPassEnd\(\); SweepWake\.end\(wake\); \}\s*\z/s or exit 1;
      $b =~ /\{\s*synchronized \(SweepStall\.class\) \{\s*synchronized \(SWEEP_SLOT\) \{\s*SWEEP_SINCE = android\.os\.SystemClock\.elapsedRealtime\(\);\s*SWEEP_THREAD = Thread\.currentThread\(\);\s*\}\s*Thread\.interrupted\(\);\s*SweepStall\.reset\(\);\s*\}\s*\z/s or exit 1;
      $e =~ /\{\s*synchronized \(SweepStall\.class\) \{\s*synchronized \(SWEEP_SLOT\) \{ if \(SWEEP_THREAD == Thread\.currentThread\(\)\) SWEEP_THREAD = null; \}\s*\}\s*\z/s or exit 1;
      (() = $w =~ /SWEEP_THREAD = null;/g) == 1 or exit 1;
      (() = $w =~ /SWEEP_THREAD = Thread\.currentThread\(\);/g) == 1 or exit 1;
      (() = $w =~ /static volatile Thread SWEEP_THREAD;/g) == 1 or exit 1;
      exit 0;' <<<"$joined
<<<SPLIT>>>
$us
<<<SPLIT>>>
$pb
<<<SPLIT>>>
$pe" || bad=1
  pin P4 "daemon( and daemonMaterialize( own SWEEP_SOCK through sweepSockOwn and release it in their finally, both under the SweepStall monitor; the abandon interrupts and closes; the watch sends through sweepStallSend" '
      my ($d1, $d2, $w, $u, $o, $r) = split /\n<<<SPLIT>>>\n/, $c, 6;
      for my $m ($d1, $d2) {
        $m =~ /if \(!sweepSockOwn\(s\)\) throw new java\.io\.IOException\(/ or exit 1;
        $m =~ /finally \{\s*sweepSockRelease\(s\);/ or exit 1;
      }
      $o =~ /\{\s*synchronized \(SweepStall\.class\) \{\s*if \(Thread\.currentThread\(\) != SWEEP_THREAD\) return true;\s*if \(SweepStall\.abandoned\(\)\) \{(?:[^{}]|\{[^{}]*\})*\breturn false;\s*\}\s*SWEEP_SOCK = s;\s*return true;\s*\}\s*\z/s or exit 1;
      $r =~ /\{\s*synchronized \(SweepStall\.class\) \{\s*if \(s != null && SWEEP_SOCK == s\) SWEEP_SOCK = null;\s*\}\s*\z/s or exit 1;
      (() = $u =~ /\bSWEEP_SOCK = /g) == 2 or exit 1;
      $w =~ /public void abandon\(\) \{(.*?)\n\s*\}\s*\};/s or exit 1; my $ab = $1;
      $ab =~ /Thread (\w+) = SWEEP_THREAD;\s*if \(\1 != null\) \1\.interrupt\(\);/ or exit 1;
      $ab =~ /LocalSocket (\w+) = SWEEP_SOCK;\s*if \(\1 != null\) try \{ \1\.close\(\); \}/ or exit 1;
      $w =~ /public void send\(String req\) \{ sweepStallSend\(req\); \}/ or exit 1;
      $w =~ /SweepStall\.tick\(now, sink\)/ or exit 1;
      $u =~ /private static void sweepStallSend\(String (\w+)\) \{\s*if \(\1 != null\) DaemonSocket\.roundTrip\(\1, 5000\);\s*\}/ or exit 1;
      exit 0;' <<<"$dm
<<<SPLIT>>>
$dmat
<<<SPLIT>>>
$watch
<<<SPLIT>>>
$us
<<<SPLIT>>>
$so
<<<SPLIT>>>
$sr" || bad=1
  pin P5 "no SweepStall.request( or sweepStallSend( argument names a package, label or work item" '
      my $n = 0;
      while ($c =~ /\b(?:SweepStall\.request|sweepStallSend)(\((?:[^()]++|(?1))*\))/g) {
        $n++; exit 1 if $1 =~ /\b(?:pkg|label|dep|work\.get)\b/;
      }
      exit 1 unless $n >= 2;
      exit 0;' <<<"$us" || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  passcases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  return "$rc"
}

if check "$ROOT"; then echo "test-sweep-stall-java: cases and source checks pass"; else echo "test-sweep-stall-java: FAILED"; exit 1; fi
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH" "$d/core/agent"
  for n in "$CH/SweepStall.java" "$CH/UnarchiveService.java" "$CH/DaemonSocket.java" "$GO"; do cp "$ROOT/$n" "$d/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  CONVICTED $1 (fails '$4')"
}
S=$CH/SweepStall.java
U=$CH/UnarchiveService.java
fails=0
mut "M1 the STALL_MS compare flipped" "$S" 's/now >= nextStallAt/now < nextStallAt/' S1 || fails=$((fails+1))
mut "M2 the repeat removed" "$S" 's/nextStallAt \+= REPEAT_MS;/nextStallAt = Long.MAX_VALUE;/' S2 || fails=$((fails+1))
mut "M3 progress ignored" "$S" 's/(static synchronized void progress\(long now\) \{\n).*?(\n    \})/$1$2/s' S3 || fails=$((fails+1))
mut "M4 the abandon fires twice" "$S" 's/!abandonSent && //' S5 || fails=$((fails+1))
mut "M5 HARD_MS 20 min" "$S" 's/HARD_MS = 25L \* 60 \* 1000;/HARD_MS = 20L * 60 * 1000;/' T3 || fails=$((fails+1))
mut "M6 the work loop's abandon block removed" "$U" 's/\n[ \t]*if \(SweepStall\.abandoned\(\)\) \{\n[ \t]*\/\/ NWP-20261203-03: a step made no progress.*?\n[ \t]*break;\n[ \t]*\}//s' P1 || fails=$((fails+1))
mut "M7 the SWEEP_THREAD guard in step( removed" "$U" 's/(private static void step\(String token, int i, int n\) \{\n)[ \t]*if \(Thread\.currentThread\(\) != SWEEP_THREAD\) return;\n/$1/' P2 || fails=$((fails+1))
mut "M8 the SWEEP_THREAD clear removed" "$U" 's/finally \{ sweepPassEnd\(\); SweepWake\.end\(wake\); \}/finally { SweepWake.end(wake); }/' P3 || fails=$((fails+1))
mut "M9 sweepPassEnd clears whoever owns the sweep" "$U" 's/if \(SWEEP_THREAD == Thread\.currentThread\(\)\) SWEEP_THREAD = null;/SWEEP_THREAD = null;/' R1 || fails=$((fails+1))
mut "M10 tick abandons a newer pass" "$S" 's/if \(pass == gonePass\) try \{ sink\.abandon\(\); \}/try { sink.abandon(); }/' R4 || fails=$((fails+1))
mut "M11 sweepSockRelease clears whichever socket is SWEEP_SOCK" "$U" 's/if \(s != null && SWEEP_SOCK == s\) SWEEP_SOCK = null;/SWEEP_SOCK = null;/' R2 || fails=$((fails+1))
mut "M12 reset() out of sweepPassBegin's lock" "$U" 's/(            Thread\.interrupted\(\);\n)            SweepStall\.reset\(\);\n(        \}\n)/$1$2        SweepStall.reset();\n/' P3 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
