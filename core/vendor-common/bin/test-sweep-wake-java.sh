#!/usr/bin/env bash
# test-sweep-wake-java.sh [--mutate] -- NWP-20261128-07: the Auto sweep keeps the processor awake until it ends, for at
# most 2 hours (decided 2026-11-04). Measured on frankel (NWP-20261104-37): once the screen went off, 82% of a long
# sweep's window was suspended and apps 30 onward took 9 to 39 minutes each; the only lock near the sweep was the tap's
# `nowhere:appfetch`, which lapses after 25 minutes.
# Compiles the chooser's pure SweepWake (java.lang only) with core/chooser/tests/sweep-wake ALONE and EXECUTES the cases
# (W1-W8), then checks the REAL UnarchiveService over its code with comments dropped (P1-P4):
#   W1  begin calls acquire once with exactly 7200000 (CAP_MS).   W2  end releases a held lock once.
#   W3  end does not release a lock that is no longer held (the fake throws "under-locked"), and does not throw.
#   W4  a throwing acquire does not throw out of begin.            W5  a throwing release or isHeld does not throw out of end.
#   W6  begin / try / finally end releases after a body that returns, and after one that throws (the throw still
#       reaches the caller).                                       W7  begin and end each log one line.
#   W8  begin(A), begin(B), end(A), end(B) (the SweepJoin gap), and the same with the ends swapped: each releases its
#       own lock and logs its own held time (A 800 ms, B 500 ms), so B's begin does not overwrite A's start.
#   P1  sweepAutoJoined: the SweepJoin.enter if-block is followed by the lock, SweepWake.begin, `try {` and the
#       `while (true)` loop, and the method ends with `finally { SweepWake.end(<lock>); }`.
#   P2  no SweepWake before SweepJoin.enter(; exactly one SweepWake.begin( and one SweepWake.end( in the method.
#   P3  sweepWakeLock: PARTIAL_WAKE_LOCK tagged "nowhere:autosweep", setReferenceCounted(false), a catch (Throwable,
#       SystemClock.elapsedRealtime(), no `return null`, and its only exit returns the one anonymous SweepWake.Lock.
#   P4  SweepWake.java has no import (java.lang only); UnarchiveService.java holds "nowhere:autosweep" once.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-sweep-wake-java.sh            # the cases and the source checks
#   bash test-sweep-wake-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-wake-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-wake-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-wake/SweepWakeCases.java

# cases <root>: compile <root>'s SweepWake with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepWake.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepWakeCases
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

# sources <root>: P1-P4 over <root>'s UnarchiveService.java and SweepWake.java.
sources() {
  local r=$1 joined adapter whole sw bad=0
  joined=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAutoJoined(boolean byHand) {")
  adapter=$(code "$r/$CH/UnarchiveService.java" "    private SweepWake.Lock sweepWakeLock() {")
  whole=$(code "$r/$CH/UnarchiveService.java")
  sw=$(code "$r/$CH/SweepWake.java")
  [ -n "$joined" ] || { echo "FAIL P0 sweepAutoJoined not found"; return 1; }
  pin P1 "sweepAutoJoined takes the lock and begins right after the SweepJoin.enter block, wraps the while (true) loop in a try, and ends it in that try's finally" '
      $c =~ /if \(!SweepJoin\.enter\(\w+\)\) \{[^{}]*\breturn;\s*\}\s*SweepWake\.Lock (\w+) = sweepWakeLock\(\);\s*SweepWake\.begin\(\1\);\s*try \{\s*while \(true\) \{(.*)\z/s or exit 1;
      my ($v, $rest) = ($1, $2);
      $rest =~ /\}\s*finally \{ SweepWake\.end\(\Q$v\E\); \}\s*\z/s or exit 1;
      exit 0;' <<<"$joined" || bad=1
  pin P2 "no SweepWake before SweepJoin.enter(, and one SweepWake.begin( and one SweepWake.end( in sweepAutoJoined" '
      my $en = index($c, "SweepJoin.enter(");
      exit 1 unless $en >= 0;
      exit 1 if index(substr($c, 0, $en), "SweepWake") >= 0;
      my $nb = () = $c =~ /\bSweepWake\.begin\(/g;
      my $ne = () = $c =~ /\bSweepWake\.end\(/g;
      exit 1 unless $nb == 1 && $ne == 1;
      exit 0;' <<<"$joined" || bad=1
  pin P3 "sweepWakeLock builds a PARTIAL nowhere:autosweep lock, not reference-counted, catches Throwable, and always returns its one SweepWake.Lock (never null)" '
      index($c, "PARTIAL_WAKE_LOCK, \"nowhere:autosweep\"") >= 0 or exit 1;
      index($c, "setReferenceCounted(false)") >= 0 or exit 1;
      $c =~ /catch \(Throwable / or exit 1;
      index($c, "SystemClock.elapsedRealtime()") >= 0 or exit 1;
      $c !~ /\breturn\s+null\b/ or exit 1;
      (() = $c =~ /return new SweepWake\.Lock\(\) \{/g) == 1 or exit 1;
      (my $o = $c) =~ s/return new SweepWake\.Lock\(\) (\{(?:[^{}]++|(?1))*\});//s or exit 1;
      $o !~ /\breturn\b/ or exit 1;
      exit 0;' <<<"$adapter" || bad=1
  pin P4 "SweepWake.java imports nothing, and UnarchiveService.java holds \"nowhere:autosweep\" exactly once" '
      my ($sw, $whole) = split /\n<<<SPLIT>>>\n/, $c, 2;
      $whole = "" unless defined $whole;
      exit 1 if $sw =~ /^\s*import\s/m;
      exit 1 unless $sw =~ /final class SweepWake\b/;
      my $n = () = $whole =~ /"nowhere:autosweep"/g;
      exit 1 unless $n == 1;
      exit 0;' <<<"$sw
<<<SPLIT>>>
$whole" || bad=1
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

if check "$ROOT"; then echo "test-sweep-wake-java: cases and source checks pass"; else echo "test-sweep-wake-java: FAILED"; exit 1; fi
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in "$CH/SweepWake.java" "$CH/UnarchiveService.java"; do cp "$ROOT/$n" "$d/$n"; done
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
S=$CH/SweepWake.java
U=$CH/UnarchiveService.java
fails=0
mut "M1 the finally's end removed" "$U" 's/\} finally \{ SweepWake\.end\(wake\); \}/} finally { }/' P1 || fails=$((fails+1))
mut "M2 the timeout changed" "$S" 's/= 2L \* 60 \* 60 \* 1000;/= 25L * 60 * 1000;/' W1 || fails=$((fails+1))
mut "M3 the isHeld guard removed" "$S" 's/if \(l\.isHeld\(\)\) \{/if (true) {/' W3 || fails=$((fails+1))
mut "M4 the begin call removed from sweepAutoJoined" "$U" 's/\n[ \t]*SweepWake\.begin\(wake\);//' P1 || fails=$((fails+1))
mut "M5 begin moved before SweepJoin.enter" "$U" 's/(\n[ \t]*if \(!SweepJoin\.enter\(flags\)\) \{.*?\n[ \t]*return;\n[ \t]*\})(\n[ \t]*SweepWake\.Lock wake = sweepWakeLock\(\);\n[ \t]*SweepWake\.begin\(wake\);)/$2$1/s' P2 || fails=$((fails+1))
mut "M6 the throwing-acquire catch removed" "$S" 's/(\} catch \(Throwable t\) \{\n[ \t]*)(say\(l, "#130 sweep wake lock: the acquire failed)/$1if (t != null) throw new RuntimeException(t);\n            $2/' W4 || fails=$((fails+1))
mut "M7 one start for every sweep (begin forgets the others)" "$S" 's/running = new Since\(l, t0, running\);/running = new Since(l, t0, null);/' W8 || fails=$((fails+1))
mut "M8 the adapter returns null on a failed lock" "$U" 's/(the sweep runs unheld \(NWP-20261128-07\)", t\);\n)/$1            return null;\n/' P3 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
