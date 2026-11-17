#!/usr/bin/env bash
# test-sweep-hold-notice-java.sh [--mutate] -- NWP-20261203-18 (backlog "Once the Auto sweep's landing card is closed, the
# sweep cannot be paused or stopped: Pause and Stop live only on the card"): placement A, Pause and Stop on the Auto
# sweep's progress notification. Compiles the chooser's pure HoldNotice, SweepHold, SweepJoin and LandingLine (java.* only,
# no Android SDK) with core/chooser/tests/sweep-hold-notice's cases ALONE and EXECUTES them, then checks the REAL
# UnarchiveService with comments dropped, so a comment can neither satisfy nor trip a check:
#   C1  HoldNotice.offer() is true only for a running sweep in state NONE; the words are "pause" and "stop".
#   C2  SweepJoin.running() is false idle, true after enter, still true across a rerun exit, false after the last exit.
#   N0  every method the checks read exists.
#   N1  each of the four FG_ID writers calls applyHoldActions once, before its startForeground / nm.notify.
#   N2  applyHoldActions gates on HoldNotice.offer(SweepJoin.running(), SweepHold.state()) and adds two actions, each a
#       PendingIntent.getService with FLAG_IMMUTABLE and EXTRA_HOLD, labelled LandingLine.PAUSE and LandingLine.STOP. No
#       FLAG_MUTABLE. A throw is caught.
#   N3  the EXTRA_HOLD arm precedes startForegroundNotice in onStartCommand, re-checks offer, maps pause to
#       SweepHold.pause(passCard()) and stop to SweepHold.stop(), re-posts while work runs AND stops the service when idle,
#       returns, and names no ACTIVE increment or decrement, Thread, DaemonSocket, daemon call, wake lock or package.
#   N4  sweepAuto sets PASS_CARD = card after Sweep.begin and before the empty-work return; sweepAutoJoined resets
#       PASS_CARD = 0 first in its loop after NWP-20261203-03's sweepPassBegin(); startSweepWatch(); (neither reads
#       PASS_CARD), before LANDING.set and sweepAuto(. PASS_CARD and passCard() exist.
#
# Mutants (--mutate; each must FAIL the check named beside it; INERT or BROKEN counts as a failure):
#   M1-M4 drop applyHoldActions from startForegroundNotice / updateNotice / updateNoticeBytes / updateNoticePhase (N1);
#   M5 offer ignores the state (C1); M6 running() returns rerun (C2); M7 FLAG_MUTABLE in applyHoldActions (N2);
#   M8 the stop word calls pause (N3); M9 the arm skips the offer re-check (N3); M10 the arm increments ACTIVE (N3);
#   M11 no stopSelfSafely when idle (N3); M12 PASS_CARD never reset (N4).
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-sweep-hold-notice-java.sh            # the cases and the source checks
#   bash test-sweep-hold-notice-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-sweep-hold-notice-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-hold-notice-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-hold-notice/HoldNoticeCases.java

# cases <root>: compile <root>'s pure classes with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/HoldNotice.java" "$1/$CH/SweepHold.java" \
    "$1/$CH/SweepJoin.java" "$1/$CH/LandingLine.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.HoldNoticeCases
}

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` inside a string literal is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $in && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# codefile <file>: the whole file with the same comment rules.
codefile() {
  perl -ne '
    next if m{^\s*(//|\*|/\*)};
    s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
    print;' "$1"
}

# pin <id> <what> <perl body over $c, which exits 0 on a pass>: one check, one ok or FAIL line.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3"; then
    echo "ok $1 $2"
  else
    echo "FAIL $1 $2"; return 1
  fi
}

# A balanced {...} block, for the perl checks below (strings are skipped, so a brace in a literal does not count).
export B_RE='(\{(?:[^{}"]++|"(?:[^"\\\n]|\\.)*+"|(?-1))*+\})'

sources() {
  local r=$1 bad=0 u sfn un unb unp aha osc sa saj whole
  u=$r/$CH/UnarchiveService.java
  sfn=$(code "$u" "    private void startForegroundNotice() {")
  un=$(code "$u" "    private void updateNotice(CharSequence title, String pkg) {")
  unb=$(code "$u" "    private void updateNoticeBytes(String pkg, long doneB, long totalB) {")
  unp=$(code "$u" "    private void updateNoticePhase(String verb) {")
  aha=$(code "$u" "    private void applyHoldActions(Notification.Builder b) {")
  osc=$(code "$u" "    public int onStartCommand(Intent intent, int flags, int startId) {")
  sa=$(code "$u" "    private void sweepAuto(boolean byHand) {")
  saj=$(code "$u" "    private void sweepAutoJoined(boolean byHand) {")
  whole=$(codefile "$u")
  local missing="" pair name text
  for pair in "startForegroundNotice:$sfn" "updateNotice:$un" "updateNoticeBytes:$unb" "updateNoticePhase:$unp" \
              "applyHoldActions:$aha" "onStartCommand:$osc" "sweepAuto:$sa" "sweepAutoJoined:$saj"; do
    name=${pair%%:*}; text=${pair#*:}
    [ -n "$text" ] || missing="$missing $name"
  done
  if [ -n "$missing" ]; then echo "FAIL N0 missing method(s):$missing"; bad=1; else echo "ok N0 every method the checks read exists"; fi

  local w post
  for pair in "startForegroundNotice|startForeground(FG_ID" "updateNotice|nm.notify(FG_ID" \
              "updateNoticeBytes|nm.notify(FG_ID" "updateNoticePhase|nm.notify(FG_ID"; do
    w=${pair%%|*}; post=${pair#*|}
    case "$w" in
      startForegroundNotice) text=$sfn ;; updateNotice) text=$un ;; updateNoticeBytes) text=$unb ;; *) text=$unp ;;
    esac
    POST=$post pin N1 "$w calls applyHoldActions once, before $post" '
      my @n = ($c =~ /\bapplyHoldActions\(/g);
      my $a = index($c, "applyHoldActions("); my $p = index($c, $ENV{POST});
      exit(@n == 1 && $a >= 0 && $p > $a ? 0 : 1);' <<<"$text" || bad=1
  done

  pin N2 "applyHoldActions gates on offer and adds Pause and Stop as immutable getService intents" '
    my $B = $ENV{B_RE};
    my $g = q{HoldNotice.offer(SweepJoin.running(), SweepHold.state())};
    my $first = index($c, "addAction(");
    my $gated = 0;
    if ($c =~ /if \(!\Q$g\E\) return;/ && $-[0] < $first) { $gated = 1; }
    while ($c =~ /if \(\Q$g\E\) $B/g) { my $blk = $1; my @a = ($blk =~ /addAction\(/g); $gated = 1 if @a == 2; }
    my @add = ($c =~ /\baddAction\(/g);
    my @gs = ($c =~ /PendingIntent\.getService\(/g);
    my $p = $c =~ /addAction\([^;]*LandingLine\.PAUSE\b[^;]*PendingIntent\.getService\([^;]*putExtra\(EXTRA_HOLD, HoldNotice\.HOLD_PAUSE\)[^;]*FLAG_IMMUTABLE[^;]*;/;
    my $s = $c =~ /addAction\([^;]*LandingLine\.STOP\b[^;]*PendingIntent\.getService\([^;]*putExtra\(EXTRA_HOLD, HoldNotice\.HOLD_STOP\)[^;]*FLAG_IMMUTABLE[^;]*;/;
    my $mut = $c =~ /\bFLAG_MUTABLE\b/;
    my $catch = $c =~ /catch \(Throwable /;
    exit($first >= 0 && $gated && @add == 2 && @gs == 2 && $p && $s && !$mut && $catch ? 0 : 1);' <<<"$aha" || bad=1

  pin N3 "the EXTRA_HOLD arm comes first, re-checks offer, maps each word, re-posts or stops, returns, and starts nothing" '
    my $B = $ENV{B_RE};
    my $x = index($c, "getStringExtra(EXTRA_HOLD)"); exit 1 if $x < 0;
    pos($c) = $x;
    $c =~ /\G.*?if \((\w+) != null\) $B/gs or exit 1;
    my ($v, $arm, $at) = ($1, $2, $-[0]);
    exit 1 unless index($c, "startForegroundNotice()") > $at;
    my $g = q{HoldNotice.offer(SweepJoin.running(), SweepHold.state())};
    my $ok = 0;
    while ($arm =~ /if \(\Q$g\E\) $B/g) {
      my $blk = $1;
      $ok = 1 if $blk =~ /HoldNotice\.HOLD_PAUSE\.equals\(\Q$v\E\)\)\s*SweepHold\.pause\(passCard\(\)\);/
              && $blk =~ /HoldNotice\.HOLD_STOP\.equals\(\Q$v\E\)\)\s*SweepHold\.stop\(\);/
              && $blk !~ /HOLD_STOP\.equals\(\Q$v\E\)\)\s*SweepHold\.pause/
              && $blk !~ /HOLD_PAUSE\.equals\(\Q$v\E\)\)\s*SweepHold\.stop/;
    }
    exit 1 unless $ok;
    exit 1 unless $arm =~ /if \(ACTIVE\.get\(\) > 0\) startForegroundNotice\(\);\s*else stopSelfSafely\(\);/;
    exit 1 unless $arm =~ /return START_NOT_STICKY;\s*\}\z/;
    exit 1 if $arm =~ /ACTIVE\.(?:increment|decrement|getAndIncrement|getAndDecrement|add|set)|\bThread\b|DaemonSocket|\bdaemon\(|fetchWake|SweepWake|EXTRA_PKG|\bpkg\b|sweepAuto/;
    exit 0;' <<<"$osc" || bad=1

  pin N4 "PASS_CARD is set in sweepAuto before the empty-work return and reset first in each pass" '
    my ($sa, $saj, $whole) = split /\x00/, $c;
    my $B = $ENV{B_RE};
    my $b = index($sa, "LandingLine.Sweep.begin(");
    my $set = index($sa, "PASS_CARD = card;");
    my $end = index($sa, "if (card != 0 && work.isEmpty() && retry.isEmpty()) cardEnded(card);");
    exit 1 unless $b >= 0 && $set > $b && $end > $set;
    $saj =~ /while \(true\) $B/ or exit 1;
    my $loop = $1;
    exit 1 unless $loop =~ /\A\{\s*sweepPassBegin\(\);\s*startSweepWatch\(\);\s*PASS_CARD = 0;/;
    my $r = index($loop, "PASS_CARD = 0;");
    exit 1 unless index($loop, "LANDING.set(") > $r && index($loop, "sweepAuto(") > $r;
    exit 1 unless $whole =~ /private static volatile long PASS_CARD;/ && $whole =~ /static long passCard\(\) \{ return PASS_CARD; \}/;
    exit 0;' < <(printf '%s\0%s\0%s' "$sa" "$saj" "$whole") || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile. The source checks run even when the cases do not
# compile, so a tree without HoldNotice still prints every N line.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  [ "$crc" -eq 3 ] && return 3
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file name under $CH> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in HoldNotice.java SweepHold.java SweepJoin.java LandingLine.java UnarchiveService.java; do
    cp "$ROOT/$CH/$n" "$d/$CH/$n"
  done
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
U=UnarchiveService.java
mut "M1 startForegroundNotice drops the actions" "$U" 's/^[ \t]*applyHoldActions\(nb\);\n//m' "N1 startForegroundNotice" || fails=$((fails+1))
mut "M2 updateNotice drops the actions" "$U" 's/(private void updateNotice\(CharSequence title.*?)[ \t]*applyHoldActions\(b\);\n/$1/s' "N1 updateNotice calls" || fails=$((fails+1))
mut "M3 updateNoticeBytes drops the actions" "$U" 's/(private void updateNoticeBytes\(.*?)[ \t]*applyHoldActions\(b\);\n/$1/s' "N1 updateNoticeBytes" || fails=$((fails+1))
mut "M4 updateNoticePhase drops the actions" "$U" 's/(private void updateNoticePhase\(.*?)[ \t]*applyHoldActions\(b\);\n/$1/s' "N1 updateNoticePhase" || fails=$((fails+1))
mut "M5 offer ignores the state" HoldNotice.java 's/return sweepRunning && s == SweepHold\.State\.NONE;/return sweepRunning;/' "C1 a sweep running, PAUSED" || fails=$((fails+1))
mut "M6 running() returns rerun" SweepJoin.java 's/synchronized \(LOCK\) \{ return running; \}/synchronized (LOCK) { return rerun; }/' "C2 after enter: running" || fails=$((fails+1))
mut "M7 the actions are mutable" "$U" 's/(private void applyHoldActions\(.*?)FLAG_IMMUTABLE/$1FLAG_MUTABLE/s' N2 || fails=$((fails+1))
mut "M8 the stop word calls pause" "$U" 's/(HoldNotice\.HOLD_STOP\.equals\(hold\)\)) SweepHold\.stop\(\);/$1 SweepHold.pause(passCard());/' N3 || fails=$((fails+1))
mut "M9 the arm skips the offer re-check" "$U" 's/(final String hold = .*?)if \(HoldNotice\.offer\(SweepJoin\.running\(\), SweepHold\.state\(\)\)\) \{/$1if (true) {/s' N3 || fails=$((fails+1))
mut "M10 the arm increments ACTIVE" "$U" 's/(if \(hold != null\) \{\n)/$1            ACTIVE.incrementAndGet();\n/' N3 || fails=$((fails+1))
mut "M11 the arm leaves an idle service running" "$U" 's/if \(ACTIVE\.get\(\) > 0\) startForegroundNotice\(\); else stopSelfSafely\(\);/if (ACTIVE.get() > 0) startForegroundNotice();/' N3 || fails=$((fails+1))
mut "M12 PASS_CARD is never reset" "$U" 's/^[ \t]*PASS_CARD = 0;[^\n]*\n//m' N4 || fails=$((fails+1))
if [ "$fails" -ne 0 ]; then echo "test-sweep-hold-notice-java: $fails mutant(s) NOT convicted"; exit 1; fi
echo "test-sweep-hold-notice-java: every mutant convicted"
