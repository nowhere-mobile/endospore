#!/usr/bin/env bash
# test-sweep-join-java.sh [--mutate] -- NWP-20261126-04: a second Auto sweep start joins the running one. Each sweep start
# ran on its own thread and sweepAuto read its pendingAutoApps list once, at its start, so two starts within one sign-in
# walked the same apps. Field-seen on husky 0.5.52 (NW-91ed3c80d0c7): `auto sweep started (1 running)` then
# `(2 running)`, each of 2 apps processed twice, and the periodic-save hold lasted 396 s against 284 s for one sweep.
# Compiles the chooser's pure SweepJoin (java.lang only) with core/chooser/tests/sweep-join ALONE and EXECUTES the cases
# (J1-J8), then checks the REAL UnarchiveService over its code with comments dropped (P1-P3):
#   J1  enter on an idle join is true.                J2  a second enter while running is false.
#   J3  exit with no join returns -1, and a later enter is true again.
#   J4  one join: exit returns its bits once and the sweep stays running; the next exit returns -1.
#   J5  two joins (BY_HAND, then LANDING) collapse into ONE rerun carrying 3; a join with no bits still reruns (0).
#   J6  through a helper that mirrors sweepAutoJoined's loop: a pass that throws with no join leaves the join idle; a
#       pass that throws while a join is pending still runs the rerun, then ends idle.
#   J7  the row's CLOSES WHEN: a model sign-in with two Auto apps; A reads [a, b], B arrives during A's first app and
#       joins, the rerun reads an empty list, and each app is processed once.
#   J8  a by-hand join after a pass whose apps waited for Wi-Fi reruns with BY_HAND, so the waiting apps are fetched.
#   P1  onStartCommand calls sweepAutoJoined(false) in the netRekick branch and sweepAutoJoined(byHand) after the
#       presence snapshot and wakeRestored, and calls no sweepAuto( itself.
#   P2  sweepAuto( is called only inside sweepAutoJoined: once there, and nowhere else in the file.
#   P3  sweepAutoJoined reads and removes LANDING, then calls SweepJoin.enter (its false branch returns) before any
#       sweepAuto call, then the SweepWake lock lines and `try {` (NWP-20261128-07), and in its loop catches Throwable
#       around each pass and calls SweepJoin.exit in that try's finally.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-sweep-join-java.sh            # the cases and the source checks
#   bash test-sweep-join-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-join-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-join-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-join/SweepJoinCases.java

# cases <root>: compile <root>'s SweepJoin with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepJoin.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepJoinCases
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

# sources <root>: P1-P3 over <root>'s UnarchiveService.java.
sources() {
  local r=$1 start joined whole bad=0
  start=$(code "$r/$CH/UnarchiveService.java" "    public int onStartCommand(Intent intent, int flags, int startId) {")
  joined=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAutoJoined(boolean byHand) {")
  whole=$(code "$r/$CH/UnarchiveService.java")
  [ -n "$start" ] || { echo "FAIL P0 onStartCommand not found"; return 1; }
  [ -n "$whole" ] || { echo "FAIL P0 UnarchiveService.java not read"; return 1; }
  pin P1 "onStartCommand runs sweepAutoJoined(false) in the netRekick branch and sweepAutoJoined(byHand) after the snapshot and wakeRestored, and no sweepAuto( itself" '
      exit 1 if $c =~ /\bsweepAuto\(/;
      my $n = () = $c =~ /\bsweepAutoJoined\(/g; exit 1 unless $n == 3;
      $c =~ /if \(netRekick\) \{((?:(?!snapshotAppSeen|wakeRestored|if \(resumeSweep\)).)*?)\breturn;\s*\}/s or exit 1;
      my $nb = $1;
      $nb =~ /try \{ sweepAutoJoined\(false\); \}\s*catch \(Throwable \w+\) \{[^}]*\}\s*finally \{ workerDone\(\); \}/ or exit 1;
      my $snap = index($c, "StoreInstaller.snapshotAppSeen(");
      my $wake = index($c, "wakeRestored(restoredOk)");
      $c =~ /try \{ sweepAutoJoined\(byHand\); \}\s*catch \(Throwable \w+\) \{[^}]*\}\s*finally \{ workerDone\(\); \}/g or exit 1;
      my $call = pos($c);
      exit 1 unless $snap >= 0 && $wake > $snap && $call > $wake;
      exit 0;' <<<"$start" || bad=1
  pin P2 "sweepAuto( is called only inside sweepAutoJoined (one call there, none elsewhere)" '
      my ($whole, $joined) = split /\n<<<SPLIT>>>\n/, $c, 2;
      $joined = "" unless defined $joined;
      my $nj = () = $joined =~ /\bsweepAuto\(/g; exit 1 unless $nj == 1;
      my $nw = () = $whole =~ /\bsweepAuto\(/g;
      my $nd = () = $whole =~ /private void sweepAuto\(boolean byHand\) \{/g;
      exit 1 unless $nd == 1 && $nw == 2;
      exit 0;' <<<"$whole
<<<SPLIT>>>
$joined" || bad=1
  pin P3 "sweepAutoJoined takes LANDING, enters SweepJoin (returning when it joins) before any pass, and catches Throwable around each pass with SweepJoin.exit in that try's finally" '
      my $g = index($c, "Boolean.TRUE.equals(LANDING.get())");
      my $rm = index($c, "LANDING.remove();");
      my $en = index($c, "SweepJoin.enter(");
      exit 1 unless $g >= 0 && $g < $rm && $rm < $en;
      $c =~ /\bsweepAuto\(/g or exit 1;
      exit 1 unless $-[0] > $en;
      $c =~ /if \(!SweepJoin\.enter\(\w+\)\) \{[^{}]*\breturn;\s*\}\s*SweepWake\.Lock (\w+) = sweepWakeLock\(\);\s*SweepWake\.begin\(\1\);\s*try \{\s*(?:while \(true\)|for \(;;\)) \{(.*)\z/s or exit 1;
      my $loop = $2;
      $loop =~ /\btry \{ sweepAuto\([^;]*\); \}\s*catch \(Throwable \w+\) \{[^}]*\}\s*finally \{ (\w+) = SweepJoin\.exit\(\); \}\s*if \(\1 < 0\) return;/s
        or exit 1;
      exit 0;' <<<"$joined" || bad=1
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

if check "$ROOT"; then echo "test-sweep-join-java: cases and source checks pass"; else echo "test-sweep-join-java: FAILED"; exit 1; fi
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in "$CH/SweepJoin.java" "$CH/UnarchiveService.java"; do cp "$ROOT/$n" "$d/$n"; done
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
J=$CH/SweepJoin.java
U=$CH/UnarchiveService.java
fails=0
mut "M1 enter always true" "$J" 's/if \(!running\) \{/if (true) {/' J7 || fails=$((fails+1))
mut "M2 exit ignores a pending rerun" "$J" 's/if \(rerun\) \{/if (false) {/' J4 || fails=$((fails+1))
mut "M3 exit leaves the join running with no rerun" "$J" 's/\n[ \t]*running = false;(\n[ \t]*return -1;)/$1/' J3 || fails=$((fails+1))
mut "M4 the joiners' flags are not ORed (last one wins)" "$J" 's/pendingFlags \|= flags;/pendingFlags = flags;/' J5 || fails=$((fails+1))
mut "M5 the netRekick call reverted to sweepAuto(false)" "$U" 's/try \{ sweepAutoJoined\(false\); \}/try { sweepAuto(false); }/' P1 || fails=$((fails+1))
mut "M6 the finally around the pass removed" "$U" 's/\n([ \t]*)finally \{ (next = SweepJoin\.exit\(\);) \}/\n$1$2/' P3 || fails=$((fails+1))
mut "M7 the per-pass catch removed" "$U" 's/\n[ \t]*catch \(Throwable t\) \{ android\.util\.Log\.w\("NowhereChooser", "#130 auto sweep", t\); \}(\n[ \t]*finally \{ next = )/$1/' P3 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
