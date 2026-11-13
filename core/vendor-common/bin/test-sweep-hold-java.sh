#!/usr/bin/env bash
# test-sweep-hold-java.sh [--mutate] -- NWP-20261201-13 (backlog "An Auto sweep cannot be paused or stopped"): the Auto
# sweep's Pause and Stop. Compiles the chooser's pure SweepHold, SweepJoin, LandingLine, SweepOutcome and SignOutGate (java.* only,
# no Android SDK) with core/chooser/tests/sweep-hold's cases ALONE and EXECUTES them, then checks the REAL chooser
# sources with comments dropped, so a comment can neither satisfy nor trip a check:
#   H1  each sweepAuto loop checks SweepHold.held() before its restoreOnly* / materializeAndInstall call. The materialise
#       one takes the rest off the queue (qDrop(SignOutGate.rest(work, i))) and sets `cut = true`. The busy wait ends too.
#   H2  the held, non-by-hand return sits after the remembered-tap loop and before pendingAutoApps, AUTO-SWEEP 1,
#       Sweep.begin and qEnqueue(work).
#   H3  a by-hand start clears the hold before `sw.start()`.
#   H4  sweepAuto has one early-return held branch and one materialise held branch, and neither names a keep writer.
#   H5  SweepHold.java exists, imports nothing and names no storage. Its three callers name it. No code line of the five
#       files mixes it with storage: the "nothing sealed" rule.
#   H6  the card's Pause and Stop handlers call SweepHold behind their guards, with no I/O, thread, service or broadcast.
#   H7  after the loop, SweepHold.close(card, cut) maps PAUSE to Sweep.pause(card), STOP to Sweep.stop(card) and END to
#       Sweep.end(card). CONTINUE touches nothing: a by-hand start ended the pause and the next pass takes the card.
#   H8  the EXTRA_RESUME arm follows the netRekick block, calls SweepHold.resume() and sweepAutoJoined(false), and returns
#       before snapshotAppSeen.
#   H9  the empty-work return ends a non-zero card, and the card is told.
#   H10 a Resume continues its card: sweepAuto takes it from SweepHold, calls Sweep.resume and shows no new card.
#   H11 the card paints Resume, the held lines and the inert buttons, its Resume starts EXTRA_SWEEP + EXTRA_RESUME, and
#       both layouts have the row.
#   H12 installPendingRow reads RESUME_ROW only while PAUSED, and its tap stays a by-hand start.
#   H13 a sweep that stops on a busy remembered tap puts a waiting Resume back to paused, on the card too, and tells it.
#   H14 the completion broadcast follows the close of the card, and the card closes only on Sweep.done.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of the eight files, each of which must FAIL a named check. A mutant that
# does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-sweep-hold-java.sh            # the cases and the source checks
#   bash test-sweep-hold-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-hold-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-hold-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-hold/SweepHoldCases.java

# cases <root>: compile <root>'s pure classes with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepHold.java" "$1/$CH/SweepJoin.java" "$1/$CH/LandingLine.java" \
    "$1/$CH/SweepOutcome.java" "$1/$CH/SignOutGate.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepHoldCases
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

h4() { # h4 <sweepAuto code>
  perl -0e '
    my $c = do { local $/; <STDIN> };
    my $B = qr/(\{(?:[^{}"]++|"(?:[^"\\\n]|\\.)*+"|(?1))*+\})/;
    my $K = qr/\b(?:keepInMode|keepAuto|keepAutoImpl)\b/;
    my $bad = 0;
    my %h = ("early return" => qr/if \(!byHand && SweepHold\.held\(\)\) $B/,
             "materialise block" => qr/if \(SweepHold\.held\(\)\) $B/);
    for my $n (sort keys %h) {
      my $re = $h{$n}; my @b; while ($c =~ /$re/g) { push @b, $1; }
      if (@b != 1) { print "FAIL H4 sweepAuto has " . scalar(@b) . " $n held branch(es), want 1\n"; $bad = 1; next; }
      if ($b[0] =~ $K) { print "FAIL H4 the $n held branch names a keep writer\n"; $bad = 1; }
    }
    print "ok H4 both held branches found, neither names a keep writer\n" unless $bad;
    exit $bad;' <<<"$1"
}

h5() { # h5 <root>
  local r=$1 n c bad=0
  local tok='\bFile\b|FileOutputStream|SharedPreferences|getFilesDir|DaemonSocket'
  if [ -f "$r/$CH/SweepHold.java" ]; then
    c=$(codefile "$r/$CH/SweepHold.java")
    if ! TOK=$tok perl -ne 'exit 1 if /^\s*import\b/ || /$ENV{TOK}/' <<<"$c"; then
      echo "FAIL H5 SweepHold.java has an import or names a storage token"; bad=1
    fi
  else
    echo "FAIL H5 SweepHold.java does not exist"; bad=1
  fi
  for n in UnarchiveService LandingNoticeActivity ProfileActivity; do
    c=$(codefile "$r/$CH/$n.java")
    if ! perl -ne '$s = 1 if /\bSweepHold\b/; END { exit($s ? 0 : 1) }' <<<"$c"; then
      echo "FAIL H5 $n.java has no SweepHold reference"; bad=1
    fi
  done
  for n in SweepHold UnarchiveService LandingLine LandingNoticeActivity ProfileActivity; do
    [ -f "$r/$CH/$n.java" ] || continue
    c=$(codefile "$r/$CH/$n.java")
    if ! TOK=$tok perl -ne 'exit 1 if /\bSweepHold\b/ && /$ENV{TOK}/' <<<"$c"; then
      echo "FAIL H5 a line of $n.java names SweepHold and a storage token"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] && echo "ok H5 SweepHold has no import or storage token; three callers reference it; no line mixes it with storage"
  return "$bad"
}

# sources <root>: H1-H13 over <root>'s chooser sources. Every check prints its own line and the next one still runs.
sources() {
  local r=$1 sweep start svc pause stop resume hold render row notice repause bad=0
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  start=$(code "$r/$CH/UnarchiveService.java" "    public int onStartCommand(Intent intent, int flags, int startId) {")
  repause=$(code "$r/$CH/UnarchiveService.java" "    private void repauseResumed() {")
  row=$(code "$r/$CH/ProfileActivity.java" "    private LinearLayout installPendingRow(int n, boolean allowMetered, boolean onWifi) {")
  pause=$(code "$r/$CH/LandingNoticeActivity.java" "    private void tapPause() {")
  stop=$(code "$r/$CH/LandingNoticeActivity.java" "    private void tapStop() {")
  resume=$(code "$r/$CH/LandingNoticeActivity.java" "    private void tapResume() {")
  hold=$(code "$r/$CH/LandingNoticeActivity.java" "    private void addHoldRow(LinearLayout card) {")
  render=$(code "$r/$CH/LandingNoticeActivity.java" "    private void render() {")
  svc=$(codefile "$r/$CH/UnarchiveService.java")
  notice=$(codefile "$r/$CH/LandingNoticeActivity.java")
  if [ -z "$sweep" ] || [ -z "$start" ] || [ -z "$row" ]; then
    echo "FAIL S0 sweepAuto, onStartCommand or installPendingRow not found"; return 1
  fi

  pin H1 "each sweep loop checks SweepHold.held() before its restore / materialise, the materialise one drops the rest and sets cut, and the busy wait ends on held()" '
      exit 1 unless $c =~ /c \+= OdRestoreList\.CHUNK\) \{\s*if \(SignOutGate\.begun\(\)\) break;\s*if \(SweepHold\.held\(\)\) break;(?:(?!restoreOnly).)*?MAT_LOCK\.lock\(\);.*?restoreOnlyLocked\(/s;
      exit 1 unless $c =~ /for \(int i = 0; i < work\.size\(\); i\+\+\) \{(?:(?!materializeAndInstall).)*?if \(SweepHold\.held\(\)\) \{\s*qDrop\(SignOutGate\.rest\(work, i\)\);(?:(?!materializeAndInstall).)*?cut = true;\s*break;\s*\}\s*String pkg = work\.get\(i\);.*?materializeAndInstall\(pkg, true\)/s;
      exit 1 unless $c =~ /left > 0 && !SignOutGate\.begun\(\) && !SweepHold\.held\(\); left -= 1000L/;
      exit 0;' <<<"$sweep" || bad=1

  pin H2 "the held, non-by-hand return sits after the remembered-tap loop and before pendingAutoApps, AUTO-SWEEP 1, Sweep.begin and qEnqueue(work)" '
      $c =~ /if \(!byHand && SweepHold\.held\(\)\) \{[^}]*\breturn;\s*\}/ or exit 1;
      my $p = $-[0];
      my $t = index($c, "for (int k = 0; k < remembered.size()"); exit 1 if $t < 0 || $t > $p;
      my $b = index($c, "if (tapLaneBusy) {"); exit 1 if $b < 0 || $b > $p;
      for my $w ("pendingAutoApps(", q{"AUTO-SWEEP\n1\n"}, "LandingLine.Sweep.begin(", "qEnqueue(work);") {
        my $i = index($c, $w); exit 1 if $i < 0 || $i < $p;
      }
      exit 0;' <<<"$sweep" || bad=1

  pin H3 "a by-hand start clears the hold before sw.start()" '
      my $h = index($c, "if (byHand) SweepHold.clear();"); exit 1 if $h < 0;
      my $s = index($c, "sw.start()"); exit 1 if $s < 0 || $s < $h;
      exit 0;' <<<"$start" || bad=1

  h4 "$sweep" || bad=1
  h5 "$r" || bad=1

  # H6 is over the two handlers only: tapResume is the one that starts the service.
  if [ -z "$pause" ] || [ -z "$stop" ]; then
    echo "FAIL H6 tapPause or tapStop not found"; bad=1
  else
    pin H6 "the card's Pause and Stop handlers call SweepHold behind their guards, with no I/O, thread, service or broadcast" '
        my ($p, $s) = split /\n<<<SPLIT>>>\n/, $c, 2;
        my $g = qr/if \(LandingLine\.Sweep\.done\(sweep\) \|\| LandingLine\.Sweep\.paused\(sweep\)\) return;/;
        exit 1 unless $p =~ /$g\s*SweepHold\.pause\(sweep\);/;
        exit 1 unless $s =~ /$g\s*SweepHold\.stop\(\);/;
        for my $b ($p, $s) {
          exit 1 if $b =~ /\b(?:File|FileOutputStream|Thread|Runnable|startService|startActivity|sendBroadcast|DaemonSocket|getSharedPreferences|keepAuto|keepInMode)\b/;
        }
        exit 0;' <<<"$pause
<<<SPLIT>>>
$stop" || bad=1
  fi

  pin H7 "after the loop, SweepHold.close maps PAUSE to Sweep.pause(card), STOP to Sweep.stop(card), END to Sweep.end(card), and CONTINUE to nothing" '
      exit 1 unless $c =~ /SweepHold\.Close close = SweepHold\.close\(card, cut\);\s*if \(close == SweepHold\.Close\.PAUSE\) LandingLine\.Sweep\.pause\(card\);\s*else if \(close == SweepHold\.Close\.STOP\) LandingLine\.Sweep\.stop\(card\);\s*else if \(close == SweepHold\.Close\.END\) LandingLine\.Sweep\.end\(card\);/;
      my $f = index($c, q{"AUTO-SWEEP\n0\n"}); exit 1 if $f < 0 || $f > $-[0];
      exit 0;' <<<"$sweep" || bad=1

  pin H8 "the EXTRA_RESUME arm follows the netRekick block, calls SweepHold.resume() and sweepAutoJoined(false), and returns before snapshotAppSeen" '
      index($c, q{intent.getBooleanExtra(EXTRA_RESUME, false)}) >= 0 or exit 1;
      my $n = index($c, "if (netRekick) {"); exit 1 if $n < 0;
      $c =~ /if \(resumeSweep\) \{((?:(?!snapshotAppSeen).)*?)\breturn;\s*\}/s or exit 1;
      my ($b, $at, $end) = ($1, $-[0], $+[0]); exit 1 if $at < $n;
      $b =~ /SweepHold\.resume\(\);\s*try \{ sweepAutoJoined\(false\); \}\s*catch \(Throwable \w+\) \{[^}]*\}\s*finally \{ workerDone\(\); \}/ or exit 1;
      my $s = index($c, "StoreInstaller.snapshotAppSeen("); exit 1 if $s < $end;
      exit 0;' <<<"$start" || bad=1

  pin H9 "the empty-work return ends a non-zero card first, and the card is told" '
      my ($s, $f) = split /\n<<<SPLIT>>>\n/, $c, 2;
      exit 1 unless $s =~ /if \(card != 0 && work\.isEmpty\(\) && retry\.isEmpty\(\)\) cardEnded\(card\);\s*if \(work\.isEmpty\(\) && retry\.isEmpty\(\)\) \{[^}]*\breturn; \}/;
      exit 1 unless $f =~ /private void cardEnded\(long card\) \{ LandingLine\.Sweep\.end\(card\); tellCard\(\); \}/;
      exit 1 unless $f =~ /private void tellCard\(\) \{\s*try \{ sendBroadcast\(new Intent\(LandingNoticeActivity\.ACTION_APP\)\.setPackage\(getPackageName\(\)\)\); \}/;
      exit 0;' <<<"$sweep
<<<SPLIT>>>
$svc" || bad=1

  pin H10 "a Resume continues its card: sweepAuto takes it from SweepHold, tells the card, and shows no new card" '
      my ($s, $f) = split /\n<<<SPLIT>>>\n/, $c, 2;
      exit 1 unless $s =~ /long resumed = SweepHold\.takeResumed\(\);\s*long card = 0;\s*if \(resumed != 0L\) \{\s*card = resumed;\s*cardResumed\(card\);\s*landing = false;\s*\}/;
      my $p = $-[0]; my $show = index($s, "LandingLine.show("); exit 1 if $show < $p;
      exit 1 unless $f =~ /private void cardResumed\(long card\) \{ LandingLine\.Sweep\.resume\(card\); tellCard\(\); \}/;
      exit 0;' <<<"$sweep
<<<SPLIT>>>
$svc" || bad=1

  if [ -z "$resume" ] || [ -z "$hold" ] || [ -z "$render" ]; then
    echo "FAIL H11 tapResume, addHoldRow or render not found"; bad=1
  else
    pin H11 "the card paints Resume, the held lines and the inert buttons, its Resume starts the sweep with EXTRA_RESUME and not by hand, and both layouts have the row" '
        my ($res, $hold, $ren, $f) = split /\n<<<SPLIT>>>\n/, $c, 4;
        exit 1 unless $res =~ /putExtra\(UnarchiveService\.EXTRA_SWEEP, true\)\s*\.putExtra\(UnarchiveService\.EXTRA_RESUME, true\)/;
        exit 1 if $res =~ /EXTRA_BY_HAND|SweepHold\./;
        exit 1 unless $hold =~ /if \(LandingLine\.Sweep\.paused\(sweep\)\) tapResume\(\); else tapPause\(\);/;
        exit 1 unless $hold =~ /stopBtn\.setOnClickListener\(v -> tapStop\(\)\);/;
        exit 1 unless $ren =~ /LandingLine\.heldLine\(paused, LandingLine\.Sweep\.stopped\(sweep\), got, pkgs\.length\)/;
        exit 1 unless $ren =~ /pauseBtn\.setText\(paused \? LandingLine\.RESUME : LandingLine\.PAUSE\);/;
        exit 1 unless $ren =~ /setHoldButton\(pauseBtn, !ended\);\s*setHoldButton\(stopBtn, !ended && !paused\);/;
        exit 1 unless $ren =~ /holdLine\.setText\(line != null \? line : LandingLine\.KEEP\);\s*return;/;
        exit 1 unless $ren =~ /headline\.setText\(LandingLine\.headline\(got, pkgs\.length\)\);\s*if \(line != null\) headline\.setText\(line\);/;
        my $n = () = $f =~ /^\s*addHoldRow\(card\);/mg; exit 1 unless $n == 2;
        exit 1 unless $f =~ /card\.addView\(gotIt, lp\);\s*addHoldRow\(card\);/;
        exit 1 unless $f =~ /card\.addView\(moreRow\);\s*addHoldRow\(card\);/;
        exit 0;' <<<"$resume
<<<SPLIT>>>
$hold
<<<SPLIT>>>
$render
<<<SPLIT>>>
$notice" || bad=1
  fi

  pin H12 "installPendingRow reads RESUME_ROW only while PAUSED, and its tap stays a by-hand start" '
      exit 1 unless $c =~ /lab\.setText\(SweepHold\.state\(\) == SweepHold\.State\.PAUSED \? LandingLine\.RESUME_ROW : "Install pending apps now"\);/;
      exit 1 unless $c =~ /putExtra\(UnarchiveService\.EXTRA_SWEEP, true\)\s*\.putExtra\(UnarchiveService\.EXTRA_BY_HAND, true\)/;
      exit 1 if $c =~ /EXTRA_RESUME/;
      exit 0;' <<<"$row" || bad=1

  pin H13 "a sweep that stops on a busy remembered tap puts a waiting Resume back to paused, on the card too, and tells the card" '
      my ($s, $h) = split /\n<<<SPLIT>>>\n/, $c, 2;
      exit 1 unless $s =~ /if \(tapLaneBusy\) \{[^{}]*?repauseResumed\(\);\s*return;\s*\}/s;
      exit 1 unless $h =~ /long waiting = SweepHold\.takeResumed\(\);\s*if \(waiting != 0L\) \{ SweepHold\.pause\(waiting\); LandingLine\.Sweep\.pause\(waiting\); tellCard\(\); \}\s*$/s;
      exit 0;' <<<"$sweep
<<<SPLIT>>>
$repause" || bad=1

  pin H14 "the completion broadcast follows the close of the card, and the card closes only on Sweep.done" '
      my ($s, $f) = split /\n<<<SPLIT>>>\n/, $c, 2;
      my $e = index($s, "SweepHold.close(card, cut)"); exit 1 if $e < 0;
      my $b = index($s, "new Intent(ACTION_SWEEP_DONE)"); exit 1 if $b < $e;
      exit 1 unless $f =~ /render\(\);\s*if \(LandingLine\.Sweep\.done\(sweep\)\) closeSoon\(\);/;
      my $n = () = $f =~ /\bcloseSoon\(\);/g; exit 1 unless $n == 1;
      exit 0;' <<<"$sweep
<<<SPLIT>>>
$notice" || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile. The source checks run even when the cases do not
# compile, so a tree with no SweepHold still prints every H line.
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
  for n in SweepHold.java SweepJoin.java LandingLine.java SweepOutcome.java SignOutGate.java UnarchiveService.java \
           LandingNoticeActivity.java ProfileActivity.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
C=LandingNoticeActivity.java
P=ProfileActivity.java
H=SweepHold.java
L=LandingLine.java
mut "M1 held() dropped from the materialise loop" "$U" 's/if \(SweepHold\.held\(\)\) \{/if (false) {/' H1 || fails=$((fails+1))
mut "M2 held() dropped from the restore-only loop" "$U" 's/^[ \t]*if \(SweepHold\.held\(\)\) break;[^\n]*\n//m' H1 || fails=$((fails+1))
mut "M3 held() dropped from the busy wait" "$U" 's/ && !SweepHold\.held\(\); left -= 1000L/; left -= 1000L/' H1 || fails=$((fails+1))
mut "M4 the early return removed" "$U" 's/^[ \t]*if \(!byHand && SweepHold\.held\(\)\) \{.*?\n[ \t]*\}\n//ms' H2 || fails=$((fails+1))
mut "M5 the by-hand clear removed" "$U" 's/^[ \t]*if \(byHand\) SweepHold\.clear\(\);\n//m' H3 || fails=$((fails+1))
mut "M6 resume() also clears STOPPED" "$H" 's/if \(state != State\.PAUSED\) return 0;/if (state == State.NONE) return 0;/' "T3 resume leaves STOPPED" || fails=$((fails+1))
mut "M7 pause calls Sweep.end" "$U" 's/LandingLine\.Sweep\.pause\(card\)/LandingLine.Sweep.end(card)/' H7 || fails=$((fails+1))
mut "M8 the resume arm drops SweepHold.resume()" "$U" 's/^[ \t]*SweepHold\.resume\(\);\n//m' H8 || fails=$((fails+1))
mut "M9 the empty-work return no longer ends the card" "$U" 's/^[ \t]*if \(card != 0 && work\.isEmpty\(\) && retry\.isEmpty\(\)\) cardEnded\(card\);\n//m' H9 || fails=$((fails+1))
mut "M10 the Stop path calls keepAuto" "$U" 's/(if \(SweepHold\.held\(\)\) \{\n)/$1 StoreInstaller.keepAuto(this, "x");\n/' H4 || fails=$((fails+1))
mut "M11 SweepHold writes a file" "$H" 's/(private SweepHold\(\) \{\})/$1\n    static void dump() throws Exception { new java.io.FileOutputStream("x").close(); }/' H5 || fails=$((fails+1))
mut "M12 done() true while paused" "$L" 's/(paused = true;\n\s*stopped = false;\n\s*)done = false;/$1done = true;/' "S2 done is false while paused" || fails=$((fails+1))
mut "M13 the early return calls keepInMode" "$U" 's/(if \(!byHand && SweepHold\.held\(\)\) \{\n)/$1 StoreInstaller.keepInMode(this, "x");\n/' H4 || fails=$((fails+1))
mut "M14 the materialise held block removed" "$U" 's/ {16}if \(SweepHold\.held\(\)\) \{.*?break;\s*\}\n//s' H4 || fails=$((fails+1))
mut "M15 UnarchiveService has no SweepHold reference" "$U" 's/\bSweepHold\b/SweepGate/g' H5 || fails=$((fails+1))
mut "M16 LandingNoticeActivity has no SweepHold reference" "$C" 's/\bSweepHold\b/SweepGate/g' H5 || fails=$((fails+1))
mut "M17 ProfileActivity has no SweepHold reference" "$P" 's/\bSweepHold\b/SweepGate/g' H5 || fails=$((fails+1))
mut "M18 a card handler line also writes a preference" "$C" 's/(SweepHold\.stop\(\);)/$1 getSharedPreferences("x", 0).edit().apply();/' H5 || fails=$((fails+1))
mut "M19 SweepHold.java gains an import" "$H" 's/^(package [^\n]*\n)/$1import java.util.List;\n/m' H5 || fails=$((fails+1))
mut "M20 tapStop starts a thread" "$C" 's/(SweepHold\.stop\(\);)/$1 new Thread(() -> {}).start();/' H6 || fails=$((fails+1))
mut "M21 tapPause loses its guard" "$C" 's/(private void tapPause\(\) \{\n)[ \t]*if [^\n]*\n/$1/' H6 || fails=$((fails+1))
mut "M22 stop calls Sweep.end" "$U" 's/LandingLine\.Sweep\.stop\(card\)/LandingLine.Sweep.end(card)/' H7 || fails=$((fails+1))
mut "M23 the materialise block does not set cut" "$U" 's/^[ \t]*cut = true;\n//m' H1 || fails=$((fails+1))
mut "M24 a resume keeps no card for the next pass" "$H" 's/^[ \t]*resumedCard = resumed;\n//m' "J3 the rerun continues the paused card" || fails=$((fails+1))
mut "M25 a resume is a by-hand sweep" "$U" 's/(SweepHold\.resume\(\);\s*try \{ )sweepAutoJoined\(false\)/$1sweepAutoJoined(true)/' H8 || fails=$((fails+1))
mut "M26 the resume arm falls through to the landing" "$U" 's/(#130 auto sweep \(resume\)", t\); \}\n\s*finally \{ workerDone\(\); \}\n)\s*return;\n/$1/' H8 || fails=$((fails+1))
mut "M27 a resume shows a new card" "$U" 's/^[ \t]*landing = false;\n//m' H10 || fails=$((fails+1))
mut "M28 a resume does not tell the card" "$U" 's/^[ \t]*cardResumed\(card\);\n//m' H10 || fails=$((fails+1))
mut "M29 the card's Resume starts by hand" "$C" 's/UnarchiveService\.EXTRA_RESUME/UnarchiveService.EXTRA_BY_HAND/' H11 || fails=$((fails+1))
mut "M30 a paused card keeps the Pause word" "$C" 's/paused \? LandingLine\.RESUME : LandingLine\.PAUSE/LandingLine.PAUSE/' H11 || fails=$((fails+1))
mut "M31 the big layout has no row" "$C" 's/(card\.addView\(moreRow\);\n)[ \t]*addHoldRow\(card\);\n/$1/' H11 || fails=$((fails+1))
mut "M32 the small layout has no row" "$C" 's/(card\.addView\(gotIt, lp\);\n)[ \t]*addHoldRow\(card\);\n/$1/' H11 || fails=$((fails+1))
mut "M33 the Your apps label ignores the hold" "$P" 's/SweepHold\.state\(\) == SweepHold\.State\.PAUSED \? LandingLine\.RESUME_ROW : //' H12 || fails=$((fails+1))
mut "M34 the Your apps label reads Resume on a stop" "$P" 's/SweepHold\.State\.PAUSED \? LandingLine\.RESUME_ROW/SweepHold.State.STOPPED ? LandingLine.RESUME_ROW/' H12 || fails=$((fails+1))
mut "M35 a stopped card says the paused line" "$L" 's/return stopped \? STOPPED_LINE : null;/return stopped ? PAUSED_LINE : null;/' "W2 a stopped card" || fails=$((fails+1))
mut "M36 a card with every app landed keeps the held line" "$L" 's/^[ \t]*if \(landed == total\) return null;\n//m' "W3 a paused card with every app landed" || fails=$((fails+1))
mut "M37 begin keeps paused" "$L" 's/(done = false;\n\s*)paused = false;\n/$1/' "S6 begin after a pause resets paused" || fails=$((fails+1))
mut "M38 stop does not end the card" "$L" 's/(stopped = true;\n\s*paused = false;\n\s*)done = true;/$1done = false;/' "S4 done is true after stop" || fails=$((fails+1))
mut "M39 clear keeps STOPPED" "$H" 's/(static void clear\(\) \{\n\s*synchronized \(LOCK\) \{\n\s*if \(state == State\.PAUSED\) resumedCard = card;\n\s*)state = State\.NONE;\n/$1/' "T4 clear resets STOPPED" || fails=$((fails+1))
mut "M40 pause overrides a stop" "$H" 's/^[ \t]*if \(state == State\.STOPPED\) return;\n//m' "T3 pause from STOPPED changes nothing" || fails=$((fails+1))
mut "M41 resume keeps a failed app settled" "$L" 's/^[ \t]*if \(!landed\[i\]\) settled\[i\] = false;\n//m' "S8 a resume lands a retry" || fails=$((fails+1))
mut "M43 sweepAuto does not take the resumed card" "$U" 's/long resumed = SweepHold\.takeResumed\(\);/long resumed = 0L;/' H10 || fails=$((fails+1))
mut "M44 the card is taken on every read" "$H" 's/^[ \t]*resumedCard = 0;\n//m' "R1 only one pass takes the card" || fails=$((fails+1))
mut "M45 a by-hand start loses a paused card" "$H" 's/^[ \t]*if \(state == State\.PAUSED\) resumedCard = card;\n//m' "R3 a by-hand start continues a paused card" || fails=$((fails+1))
mut "M46 a second Resume tap overwrites the card" "$H" 's/if \(state != State\.PAUSED\) return 0;/if (state != State.PAUSED) { resumedCard = 0; return 0; }/' "R2 a second Resume tap does not lose the card" || fails=$((fails+1))
mut "M47 the Resume arm starts the sweep before it ends the pause" "$U" 's/(SweepHold\.resume\(\);\s*)(try \{ sweepAutoJoined\(false\); \}[^\n]*\n[^\n]*\n[^\n]*workerDone\(\); \}\n)/$2 SweepHold.resume();\n/' H8 || fails=$((fails+1))
mut "M48 a stopped-on-busy sweep leaves the Resume waiting" "$U" 's/^[ \t]*if \(waiting != 0L\) \{ SweepHold\.pause\(waiting\); LandingLine\.Sweep\.pause\(waiting\); tellCard\(\); \}\n//m' H13 || fails=$((fails+1))
mut "M49 a stopped-on-busy sweep does not tell the card" "$U" 's/LandingLine\.Sweep\.pause\(waiting\); tellCard\(\);/LandingLine.Sweep.pause(waiting);/' H13 || fails=$((fails+1))
mut "M50 a pass ends a card the next pass continues" "$H" 's/return sweep != 0 && resumedCard == sweep \? Close\.CONTINUE : Close\.END;/return Close.END;/' "P1 a card the next pass continues stays open" || fails=$((fails+1))
mut "M51 the service ends a card on CONTINUE" "$U" 's/else if \(close == SweepHold\.Close\.END\) LandingLine/else LandingLine/' H7 || fails=$((fails+1))
mut "M52 close ignores whether the pass cut the sweep" "$H" 's/^[ \t]*if \(!cut\) return Close\.END;\n//m' "C1 a pass that finished every app ends while paused" || fails=$((fails+1))
mut "M53 a pass with no card reads as continued" "$H" 's/return sweep != 0 && resumedCard == sweep/return resumedCard == sweep/' "C4 a pass with no card ends" || fails=$((fails+1))
mut "M54 any waiting resume keeps the card" "$H" 's/sweep != 0 && resumedCard == sweep/sweep != 0 \&\& resumedCard != 0/' "C4 another card" || fails=$((fails+1))
mut "M55 a stopped-on-busy sweep leaves the card running" "$U" 's/ LandingLine\.Sweep\.pause\(waiting\);//' H13 || fails=$((fails+1))
mut "M56 the card closes on every sync" "$C" 's/if \(LandingLine\.Sweep\.done\(sweep\)\) closeSoon\(\);/closeSoon();/' H14 || fails=$((fails+1))
mut "M57 the completion broadcast goes before the close" "$U" 's/(        SweepHold\.Close close = SweepHold\.close\(card, cut\);)/        sendBroadcast(new Intent(ACTION_SWEEP_DONE).setPackage(getPackageName()));\n$1/' H14 || fails=$((fails+1))
mut "M58 a cut pass of a paused sweep reads as continued" "$H" 's/if \(state == State\.PAUSED\) return Close\.PAUSE;/if (state == State.PAUSED) return Close.CONTINUE;/' "C2 a cut pass of a paused sweep pauses" || fails=$((fails+1))
mut "M42 resume reopens a landed app" "$L" 's/if \(!landed\[i\]\) settled\[i\] = false;/settled[i] = false;/' "S9 a resume keeps a landed app" || fails=$((fails+1))
mut "M59 the busy stop does not re-pause a waiting Resume" "$U" 's/^[ \t]*repauseResumed\(\);[^\n]*\n//m' H13 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
