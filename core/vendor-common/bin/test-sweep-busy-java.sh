#!/usr/bin/env bash
# test-sweep-busy-java.sh [--mutate] -- NWP-20261118-05: an Auto sweep waits out a busy worker lane. ERR-WORKER-BUSY
# means nothing ran (NWP-20261022-02), so the sweep retries the SAME app on a growing schedule bounded below the
# daemon's autoSweepLease, then reports it `busy` and leaves the rest for the next sweep. Only an op that ran and
# failed reads fetch-failed. Field-seen on frankel 0.5.49 (NW-0ee95acd7ad4): 45 apps fetch-failed behind one odrestore.
# Compiles the chooser's pure SweepBusy and SweepOutcome (java.* only) with core/chooser/tests/sweep-busy ALONE and
# EXECUTES the cases (B1-B4), then checks the REAL UnarchiveService over its code with comments dropped (P1-P5):
#   B1  isBusy is true only for a reply whose trimmed first token is exactly ERR-WORKER-BUSY.
#   B2  waitMs grows and stays positive; the RETRY run step allows ends in STOP within BOUND_MS < 10 min.
#   B3  a scripted sweep that drives step() as sweepAuto's loop does: [busy, busy, OK] retries the same app twice, then
#       NEXT, sending no fetch-failed and no busy, and the queue total stays the sweep's size; [busy forever] ends in
#       STOP within the bound with exactly one busy token and every app left; [fetch-failed] is NEXT at once.
#   B4  SweepOutcome.request accepts "busy", and TOKENS holds it.
#   P1  materializeLocked's MATERIALIZE-APP reply arm checks SweepBusy.isBusy first: qDrop(group), matEnd = BUSY.
#   P2  materializeMember records depBusy from SweepBusy.isBusy(reply), and the dep abort can end BUSY.
#   P3  sweepAuto's loop calls SweepBusy.step once; its RETRY branch ends `i--; continue;` and counts and sends nothing.
#   P4  the RETRY wait sleeps at most 1 s per step and checks SignOutGate.begun() and (NWP-20261201-13) SweepHold.held()
#       each step.
#   P5  the STOP branch qDrops the apps not started, logs the busy line, and breaks.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-sweep-busy-java.sh            # the cases and the source checks
#   bash test-sweep-busy-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-busy-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-busy-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-busy/SweepBusyCases.java

# cases <root>: compile <root>'s SweepBusy and SweepOutcome with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepBusy.java" "$1/$CH/SweepOutcome.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepBusyCases
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

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3" ; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# sources <root>: P1-P5 over <root>'s UnarchiveService.java.
sources() {
  local r=$1 sweep mloc mmem loop bad=0
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  mloc=$(code "$r/$CH/UnarchiveService.java" "    private boolean materializeLocked(String pkg, boolean quiet) {")
  mmem=$(code "$r/$CH/UnarchiveService.java" "    private boolean materializeMember(String pkg) {")
  if [ -z "$sweep" ] || [ -z "$mloc" ] || [ -z "$mmem" ]; then
    echo "FAIL P0 sweepAuto, materializeLocked or materializeMember not found"; return 1
  fi
  loop=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ /(for \(int i = 0; i < work\.size\(\); i\+\+\) \{.*?)\}\s*finally\s*\{\s*DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n"/s
        or exit 1;
      print $1;' <<<"$sweep")
  [ -n "$loop" ] || { echo "FAIL P0 sweepAuto's materialise loop not found"; return 1; }
  pin P1 "materializeLocked's reply arm reads ERR-WORKER-BUSY as BUSY, after qDrop(group), before FETCH_FAILED (busy must qDrop(group) before it returns, or qFinish counts each retry done and the queue total grows)" '
      $c =~ /if \(reply == null \|\| !reply\.startsWith\("OK"\)\) \{/g or exit 1;
      my ($p, $d, $b) = (pos($c), 1, "");
      while ($p < length($c) && $d > 0) { my $ch = substr($c, $p++, 1); $d++ if $ch eq "{"; $d-- if $ch eq "}"; $b .= $ch if $d > 0; }
      $b =~ /\A\s*if\s*\(SweepBusy\.isBusy\(reply\)\)\s*\{\s*qDrop\(group\);\s*matEnd = SweepOutcome\.BUSY;\s*return false;\s*\}\s*matEnd = SweepOutcome\.FETCH_FAILED;\s*return false;\s*\z/s
        or exit 1;
      exit 0;' <<<"$mloc" || bad=1
  pin P2 "materializeMember records depBusy from its reply, and the dep abort ends BUSY on it before FETCH_FAILED" '
      my ($mloc, $mmem) = split /\n<<<SPLIT>>>\n/, $c;
      $mmem =~ /depBusy = false;\s*String reply = daemonMaterialize\(pkg\);.*?depBusy = SweepBusy\.isBusy\(reply\);\s*if \(reply == null \|\| !reply\.startsWith\("OK"\)\) return false;/s
        or exit 1;
      $mloc =~ /if \(!dok\) \{.*?qDrop\(group\);\s*if \(depBusy\) \{ matEnd = SweepOutcome\.BUSY; return false; \}\s*matEnd = SweepOutcome\.FETCH_FAILED;\s*return false;/s
        or exit 1;
      exit 0;' <<<"$mloc
<<<SPLIT>>>
$mmem" || bad=1
  # The RETRY and STOP bodies, brace-matched from their `if`.
  local retry stop
  retry=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ /if \(step == SweepBusy\.Step\.RETRY\) \{/g or exit 1;
      my ($p, $d, $b) = (pos($c), 1, "");
      while ($p < length($c) && $d > 0) { my $ch = substr($c, $p++, 1); $d++ if $ch eq "{"; $d-- if $ch eq "}"; $b .= $ch if $d > 0; }
      print $b;' <<<"$loop")
  stop=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ /if \(step == SweepBusy\.Step\.STOP\) \{/g or exit 1;
      my ($p, $d, $b) = (pos($c), 1, "");
      while ($p < length($c) && $d > 0) { my $ch = substr($c, $p++, 1); $d++ if $ch eq "{"; $d-- if $ch eq "}"; $b .= $ch if $d > 0; }
      print $b;' <<<"$loop")
  pin P3 "sweepAuto's loop calls SweepBusy.step once after the unlock, and its RETRY branch takes the SAME app (i--; continue;) without counting or sending" '
      my ($loop, $retry) = split /\n<<<SPLIT>>>\n/, $c;
      my $n = () = $loop =~ /SweepBusy\.step\(/g; exit 1 unless $n == 1;
      $loop =~ /finally \{ MAT_LOCK\.unlock\(\); \}\s*SweepBusy\.Step step = SweepBusy\.step\(end, busyTries, busyWaited\);\s*if \(step == SweepBusy\.Step\.RETRY\) \{/s
        or exit 1;
      $retry =~ /\bi--;\s*continue;\s*\z/ or exit 1;
      exit 1 if $retry =~ /\bi\+\+|\bdone\+\+|\bfailed\+\+|SweepOutcome\.request\(|\bbreak;\s*\z/;
      $loop =~ /if \(ok\) done\+\+; else if \(step == SweepBusy\.Step\.NEXT\) failed\+\+;/ or exit 1;
      exit 0;' <<<"$loop
<<<SPLIT>>>
$retry" || bad=1
  pin P4 "the RETRY wait sleeps at most 1 s a step and checks SignOutGate.begun() on every step" '
      $c =~ /for \(long left = w; left > 0 && !SignOutGate\.begun\(\) && !SweepHold\.held\(\); left -= 1000L\) \{\s*try \{ Thread\.sleep\(Math\.min\(left, 1000L\)\); \}/
        or exit 1;
      $c =~ /long w = SweepBusy\.waitMs\(busyTries\);\s*busyTries\+\+;\s*busyWaited \+= w;/ or exit 1;
      exit 0;' <<<"$retry" || bad=1
  pin P5 "the STOP branch qDrops the apps not started, logs the busy line, and ends the sweep" '
      $c =~ /\A\s*qDrop\(SignOutGate\.rest\(work, i \+ 1\)\);/ or exit 1;
      index($c, "\"#130 sweep: worker lane busy for \"") >= 0 or exit 1;
      index($c, "\" app(s) left for the next sweep\"") >= 0 or exit 1;
      $c =~ /\bbreak;\s*\z/ or exit 1;
      exit 0;' <<<"$stop" || bad=1
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in "$CH/SweepBusy.java" "$CH/SweepOutcome.java" "$CH/UnarchiveService.java"; do cp "$ROOT/$n" "$d/$n"; done
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
B=$CH/SweepBusy.java
O=$CH/SweepOutcome.java
U=$CH/UnarchiveService.java
fails=0
mut "S1 isBusy true for ERR-NOTREADY" "$B" 's/return BUSY_REPLY\.equals\(r\.substring\(0, sp\)\);/return r.startsWith("ERR-");/' B1 || fails=$((fails+1))
mut "S2 isBusy false for ERR-WORKER-BUSY" "$B" 's/return BUSY_REPLY\.equals\(r\.substring\(0, sp\)\);/return false;/' B1 || fails=$((fails+1))
mut "S3 the wait bound removed" "$B" 's/if \(waitedMs \+ waitMs\(attempt\) <= BOUND_MS\) return Step\.RETRY;/if (true) return Step.RETRY;/' B2 || fails=$((fails+1))
mut "S4 the retry advances to the next app" "$U" 's/^[ \t]*i--;\n//m' P3 || fails=$((fails+1))
mut "S5 BUSY dropped from TOKENS" "$O" 's/, ERROR, BUSY, NEEDS_PLAY, OLDER_COPY \}/, ERROR, NEEDS_PLAY, OLDER_COPY }/' B4 || fails=$((fails+1))
mut "S6 a busy MATERIALIZE-APP reply read as fetch-failed again" "$U" 's{if \(SweepBusy\.isBusy\(reply\)\) \{(?:\s*//[^\n]*)*\s*qDrop\(group\);\s*matEnd = SweepOutcome\.BUSY;\s*return false;\s*\}\s*}{}' P1 || fails=$((fails+1))
mut "S7 the dep abort's busy arm removed" "$U" 's/^[ \t]*if \(depBusy\) \{ matEnd = SweepOutcome\.BUSY; return false; \}[^\n]*\n//m' P2 || fails=$((fails+1))
mut "S8 the wait no longer checks SignOutGate" "$U" 's/for \(long left = w; left > 0 && !SignOutGate\.begun\(\)/for (long left = w; left > 0/' P4 || fails=$((fails+1))
mut "S9 the STOP no longer qDrops the rest" "$U" 's/^[ \t]*qDrop\(SignOutGate\.rest\(work, i \+ 1\)\);\n//m' P5 || fails=$((fails+1))
mut "S10 the schedule flattened to one constant" "$B" 's/return SCHEDULE_MS\[Math\.min\(attempt, SCHEDULE_MS\.length - 1\)\];/return 60_000L;/' B2 || fails=$((fails+1))
mut "S11 the busy arm no longer qDrops its group" "$U" 's{(SweepBusy\.isBusy\(reply\)\)\s*\{(?:\s*//[^\n]*)*\s*)qDrop\(group\);\s*}{$1}' P1 || fails=$((fails+1))
mut "S12 materializeMember no longer records a busy dep" "$U" 's/^[ \t]*depBusy = SweepBusy\.isBusy\(reply\);[^\n]*\n//m' P2 || fails=$((fails+1))
mut "S13 a RETRY counts the app failed" "$U" 's/(busyWaited \+= w;\n)/$1failed++;\n/' P3 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
