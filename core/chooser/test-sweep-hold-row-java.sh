#!/usr/bin/env bash
# test-sweep-hold-row-java.sh -- NWP-20261203-23 (backlog "Once the Auto sweep's landing card is closed, the sweep
# cannot be paused or stopped: Pause and Stop live only on the card"; Chester, 2026-11-12: both placements, this is B).
#
# WHY: Pause and Stop lived only on the landing card. Closing the card ("Got it") never stops the sweep, so with the
# card closed there was no way to hold it. Your apps' install row now offers Pause and Stop while a sweep runs, and a
# pause resumes from the same row ("Resume installing apps", the Install chip's by-hand start).
#
# WHAT RUNS: HoldRow, SweepHold, SweepJoin and LandingLine compile with tests/sweep-hold-row/HoldRowCases.java:
#   K1-K6   HoldRow.mode over running x NONE / PAUSED / STOPPED.
#   K7-K9   HoldRow.label per mode, verbatim ("Installing apps" is the draft LandingLine.RUNNING_ROW).
#   K10-K14 SweepJoin.running() idle, after enter, after a join, after an exit with a rerun, after the last exit.
# WHAT IS PINNED (ProfileActivity and UnarchiveService cannot be compiled off the build host; code with comments
# dropped):
#   R1 installPendingRow(n, allowMetered, onWifi, mode) labels the row through HoldRow.label(mode).
#   R2 its RUNNING block adds LandingLine.PAUSE and LandingLine.STOP chips; Pause calls
#      SweepHold.pause(UnarchiveService.passCard()) and Stop SweepHold.stop(), each behind a HoldRow.mode re-check;
#      the block starts no service or thread, names no File or DaemonSocket, and returns the row.
#   R3 the Install chip after it stays a by-hand start (EXTRA_SWEEP + EXTRA_BY_HAND) and nothing names EXTRA_RESUME.
#   R4 applyPendingRow computes the mode once, after rowAction, turns NONE into REPLACE when shown[1] != mode, passes
#      the mode to installPendingRow and records shown[1]; the build declares pendingShown = {0, -1}.
#   R5 the build registers an ACTION_SWEEP_STATE receiver, RECEIVER_NOT_EXPORTED, under isAttachedToWindow(), after
#      the first applyPendingRow and before onRowChange; it re-applies the row on the UI thread with no recount, and a
#      detach listener in that guard unregisters it.
#   R6 sweepAuto sets PASS_CARD = card after the landing catch and before the empty-work end; each pass of
#      sweepAutoJoined resets it first after NWP-20261203-03's sweepPassBegin(); startSweepWatch(); (neither reads
#      PASS_CARD); passCard() returns it.
#   R7 sweepAutoJoined calls tellSweepState() in its loop before sweepAuto( and after the last exit, before its return;
#      tellSweepState sends ACTION_SWEEP_STATE to this package in a try.
#
# It needs a JDK and perl, and it FAILS when either is missing: a Java suite that skips would read green on a runner
# that never ran it. --mutate re-runs it against broken copies (M1-M10); each must FAIL its named check. A mutant that
# does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash core/chooser/test-sweep-hold-row-java.sh            # the cases and the source checks
#   bash core/chooser/test-sweep-hold-row-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-hold-row-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-hold-row-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /'
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-hold-row/HoldRowCases.java
PURE="HoldRow SweepHold SweepJoin LandingLine SweepOutcome"

# cases <root>: compile <root>'s pure classes with the cases into a fresh dir and run them. 3: they did not compile.
cases() {
  local d n srcs=()
  d=$(mktemp -d -p "$W")
  for n in $PURE; do srcs+=("$1/$CH/$n.java"); done
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "${srcs[@]}" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.HoldRowCases
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
  if perl -0e 'my $c = do { local $/; <STDIN> }; our $B = qr/(\{(?:[^{}"]++|"(?:[^"\\\n]|\\.)*+"|(?-1))*+\})/; '"$3"; then
    echo "ok $1 $2"
  else
    echo "FAIL $1 $2"; return 1
  fi
}

# sources <root>: R1-R7 over <root>'s ProfileActivity and UnarchiveService. Every check prints its own line.
sources() {
  local r=$1 row apply sya pa sweep joined tell svc bad=0
  row=$(code "$r/$CH/ProfileActivity.java" "    private LinearLayout installPendingRow(int n, boolean allowMetered, boolean onWifi, int mode) {")
  apply=$(code "$r/$CH/ProfileActivity.java" "    private void applyPendingRow(LinearLayout ll, View summary, View[] rowRef, int[] shown, int n, boolean sweepEnded) {")
  sya=$(code "$r/$CH/ProfileActivity.java" "    private void showYourApps() {")
  pa=$(codefile "$r/$CH/ProfileActivity.java")
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  joined=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAutoJoined(boolean byHand) {")
  tell=$(code "$r/$CH/UnarchiveService.java" "    private void tellSweepState() {")
  svc=$(codefile "$r/$CH/UnarchiveService.java")

  pin R1 "installPendingRow(n, allowMetered, onWifi, mode) labels the row through HoldRow.label(mode)" '
      exit 1 unless $c =~ /\S/;
      exit 1 unless $c =~ /\blab\.setText\(HoldRow\.label\(mode\)\);/;
      exit 1 if $c =~ /SweepHold\.state\(\) ==/;
      exit 0;' <<<"$row" || bad=1

  pin R2 "the RUNNING block adds Pause and Stop chips that call SweepHold.pause(UnarchiveService.passCard()) and SweepHold.stop() behind a HoldRow.mode re-check, with no service, thread or I/O" '
      my @b; while ($c =~ /if \(mode == HoldRow\.RUNNING\) $B/g) { push @b, $1; }
      exit 1 unless @b == 1;
      my $k = $b[0];
      exit 1 unless $k =~ /\bholdChip\(LandingLine\.PAUSE\)/ && $k =~ /\bholdChip\(LandingLine\.STOP\)/;
      my $g = qr/if \(HoldRow\.mode\(SweepJoin\.running\(\), SweepHold\.state\(\)\) == HoldRow\.RUNNING\) /;
      exit 1 unless $k =~ /pause\.setOnClickListener\(v -> \{\s*${g}SweepHold\.pause\(UnarchiveService\.passCard\(\)\);\s*inert\.run\(\);\s*\}\);/;
      exit 1 unless $k =~ /stop\.setOnClickListener\(v -> \{\s*${g}SweepHold\.stop\(\);\s*inert\.run\(\);\s*\}\);/;
      my $np = () = $k =~ /SweepHold\.pause\(/g; my $ns = () = $k =~ /SweepHold\.stop\(/g;
      exit 1 unless $np == 1 && $ns == 1;
      exit 1 unless $k =~ /setEnabled\(false\);/ && $k =~ /setAlpha\(0\.4f\);/;
      exit 1 if $k =~ /startService|startForegroundService|new Thread|\bFile\b|DaemonSocket|sendBroadcast/;
      exit 1 unless $k =~ /return row;\s*\}\z/;
      exit 0;' <<<"$row" || bad=1

  pin R3 "the Install chip after the RUNNING block stays a by-hand start (EXTRA_SWEEP + EXTRA_BY_HAND), and installPendingRow names no EXTRA_RESUME" '
      $c =~ /if \(mode == HoldRow\.RUNNING\) $B/g or exit 1;
      my $after = substr($c, pos($c));
      exit 1 unless $after =~ /startService\(new Intent\(this, UnarchiveService\.class\)\.putExtra\(UnarchiveService\.EXTRA_SWEEP, true\)\s*\.putExtra\(UnarchiveService\.EXTRA_BY_HAND, true\)\);/;
      exit 1 if $c =~ /EXTRA_RESUME/;
      exit 0;' <<<"$row" || bad=1

  pin R4 "applyPendingRow computes the mode once after rowAction, replaces the row when shown[1] != mode, passes it on and records it; pendingShown is {0, -1}" '
      my ($a, $f) = split /\n<<<SPLIT>>>\n/, $c, 2;
      my $M = "int mode = HoldRow.mode(SweepJoin.running(), SweepHold.state());";
      my $n = () = $a =~ /\Q$M\E/g; exit 1 unless $n == 1;
      my $ra = index($a, "act = AutoPendingCopy.rowAction(");
      my $m = index($a, $M);
      my $rp = index($a, "if (act == PendingRow.NONE && rowRef[0] != null && shown[1] != mode) act = PendingRow.REPLACE;");
      my $no = index($a, "if (act == PendingRow.NONE) return;");
      exit 1 unless $ra >= 0 && $ra < $m && $m < $rp && $rp < $no;
      my $call = index($a, "View v = installPendingRow(n, allowMetered, onWifi, mode);"); exit 1 unless $call > $no;
      exit 1 unless $a =~ /shown\[0\] = n;\s*shown\[1\] = mode;/;
      exit 1 unless $f =~ /final int\[\] pendingShown = \{0, -1\};/;
      exit 0;' <<<"$apply
<<<SPLIT>>>
$pa" || bad=1

  pin R5 "the build registers an ACTION_SWEEP_STATE receiver (not exported, under isAttachedToWindow) after the first applyPendingRow and before onRowChange, re-applies the row on the UI thread with no recount, and unregisters it on detach" '
      my $a = index($c, "applyPendingRow(ll, summary, pendingRowView, pendingShown, pendingAuto.size());");
      my $o = index($c, "final Runnable onRowChange");
      exit 1 unless $a >= 0 && $o > $a;
      my $seg = substr($c, $a, $o - $a);
      $seg =~ /if \(ll\.isAttachedToWindow\(\)\) $B/ or exit 1;
      my $g = $1;
      $g =~ /registerReceiver\((\w+), new android\.content\.IntentFilter\(UnarchiveService\.ACTION_SWEEP_STATE\),\s*android\.content\.Context\.RECEIVER_NOT_EXPORTED\);/ or exit 1;
      my $v = $1;
      exit 1 unless $g =~ /final android\.content\.BroadcastReceiver \Q$v\E = new android\.content\.BroadcastReceiver\(\)/;
      exit 1 unless $g =~ /runOnUiThread\(\(\) -> \{\s*if \(!ll\.isAttachedToWindow\(\)\) return;\s*if \(MODE_PENDING\.get\(\) == 0 && pendingShown\[0\] > 0\)\s*applyPendingRow\(ll, summary, pendingRowView, pendingShown, pendingShown\[0\]\);\s*\}\);/;
      exit 1 if $g =~ /pendingAutoApps|refreshPendingRow|new Thread/;
      $g =~ /ll\.addOnAttachStateChangeListener\(.*?public void onViewDetachedFromWindow\(View v\) $B/s or exit 1;
      exit 1 unless $1 =~ /unregisterReceiver\(\Q$v\E\);/;
      exit 0;' <<<"$sya" || bad=1

  pin R6 "sweepAuto sets PASS_CARD = card after the landing catch and before the empty-work end; each pass resets it first; passCard() returns it" '
      my ($s, $j, $f) = split /\n<<<SPLIT>>>\n/, $c, 3;
      my $lc = index($s, "\"landing line\", t); }");
      my $pc = index($s, "PASS_CARD = card;");
      my $ce = index($s, "if (card != 0 && work.isEmpty() && retry.isEmpty())");
      exit 1 unless $lc >= 0 && $lc < $pc && $pc < $ce;
      exit 1 unless $j =~ /while \(true\) \{\s*sweepPassBegin\(\);\s*startSweepWatch\(\);\s*PASS_CARD = 0;/;
      exit 1 unless $f =~ /private static volatile long PASS_CARD;/;
      exit 1 unless $f =~ /static long passCard\(\) \{ return PASS_CARD; \}/;
      exit 0;' <<<"$sweep
<<<SPLIT>>>
$joined
<<<SPLIT>>>
$svc" || bad=1

  pin R7 "sweepAutoJoined calls tellSweepState() in its loop before sweepAuto( and after the last exit before its return; tellSweepState sends ACTION_SWEEP_STATE to this package in a try" '
      my ($j, $t, $f) = split /\n<<<SPLIT>>>\n/, $c, 3;
      $j =~ /while \(true\) \{(.*)\z/s or exit 1;
      my $loop = $1;
      my $ts = index($loop, "tellSweepState();"); my $sa = index($loop, "sweepAuto(");
      exit 1 unless $ts >= 0 && $ts < $sa;
      exit 1 unless $loop =~ /finally \{ (\w+) = SweepJoin\.exit\(\); \}\s*if \(\1 < 0\) \{ tellSweepState\(\); return; \}/;
      exit 1 unless $t =~ /try \{ sendBroadcast\(new Intent\(ACTION_SWEEP_STATE\)\.setPackage\(getPackageName\(\)\)\); \}\s*catch \(Throwable \w+\)/;
      exit 1 unless $f =~ /static final String ACTION_SWEEP_STATE = "com\.nowhere\.chooser\.action\.AUTO_SWEEP_STATE";/;
      exit 0;' <<<"$joined
<<<SPLIT>>>
$tell
<<<SPLIT>>>
$svc" || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile. The source checks run even then.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  [ "$crc" -eq 3 ] && return 3
  return "$rc"
}

check "$ROOT" || { echo "test-sweep-hold-row-java: FAILED"; exit 1; }
echo "test-sweep-hold-row-java: cases and source checks pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file name under $CH> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in $PURE ProfileActivity UnarchiveService; do cp "$ROOT/$CH/$n.java" "$d/$CH/$n.java"; done
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
R=HoldRow.java
J=SweepJoin.java
P=ProfileActivity.java
U=UnarchiveService.java
mut "M1 mode() reads a stop as RUNNING" "$R" 's/(State\.STOPPED\) return )INSTALL;/$1RUNNING;/' K5 || fails=$((fails+1))
mut "M2 mode() is RUNNING with no sweep" "$R" 's/return sweepRunning \? RUNNING : INSTALL;/return RUNNING;/' K2 || fails=$((fails+1))
mut "M3 the row's Pause calls stop" "$P" 's/SweepHold\.pause\(UnarchiveService\.passCard\(\)\);/SweepHold.stop();/' R2 || fails=$((fails+1))
mut "M4 the row's Pause drops the mode re-check" "$P" 's/if \(HoldRow\.mode\(SweepJoin\.running\(\), SweepHold\.state\(\)\) == HoldRow\.RUNNING\) (SweepHold\.pause)/$1/' R2 || fails=$((fails+1))
mut "M5 the Install chip gains EXTRA_RESUME" "$P" 's/(\.putExtra\(UnarchiveService\.EXTRA_BY_HAND, true\))(\); \/\/ NWP-20261112-11)/$1.putExtra(UnarchiveService.EXTRA_RESUME, true)$2/' R3 || fails=$((fails+1))
mut "M6 no replace on a mode change" "$P" 's/^[ \t]*if \(act == PendingRow\.NONE && rowRef\[0\] != null && shown\[1\] != mode\) act = PendingRow\.REPLACE;\n//m' R4 || fails=$((fails+1))
mut "M7 the sweep-state receiver is never unregistered" "$P" 's/try \{ unregisterReceiver\(sweepState\); \} catch \(Throwable ignore\) \{\}//' R5 || fails=$((fails+1))
mut "M8 PASS_CARD is never reset" "$U" 's/^[ \t]*PASS_CARD = 0;[^\n]*\n//m' R6 || fails=$((fails+1))
mut "M9 running() returns rerun" "$J" 's/(static boolean running\(\) \{\s*synchronized \(LOCK\) \{ return )running;/$1rerun;/' K11 || fails=$((fails+1))
mut "M10 no tellSweepState after the last exit" "$U" 's/if \(next < 0\) \{ tellSweepState\(\); return; \}/if (next < 0) return;/' R7 || fails=$((fails+1))
if [ "$fails" -ne 0 ]; then echo "test-sweep-hold-row-java: $fails mutant(s) not convicted"; exit 1; fi
echo "test-sweep-hold-row-java: all mutants convicted"
