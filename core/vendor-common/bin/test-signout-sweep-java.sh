#!/usr/bin/env bash
# test-signout-sweep-java.sh [--mutate] -- NWP-20261109-06 (Q116): a sign-out stops the post-login Auto sweep.
# Compiles the chooser's pure SignOutGate (java.* only, no Android SDK) with core/chooser/tests/signout-sweep's cases
# ALONE and EXECUTES them (G1, G2), then checks the REAL ProfileActivity.doLogoffImpl and UnarchiveService.sweepAuto,
# over their code with comments dropped, so a comment can neither satisfy nor trip a check:
#   S1 doLogoffImpl raises SignOutGate.begin() after DozeAppsMirror.capture and before profileName(), the sign-out
#      captures (AppHeld.releaseForSignOut) and the LOGOUT write.
#   S2 its `if (sealFailed) {` branch lowers it (SignOutGate.end()) as its first statement, before its return, its
#      `if (LogoutAck.lockLanding(reply)) {` branch (NWP-20261111-08, Q067) lowers it before its return, and nothing
#      else in doLogoffImpl lowers it.
#   S3 each of sweepAuto's two loops checks SignOutGate.begun() before its restore-only chunk (restoreOnlyLocked /
#      restoreOnlyListLocked, NWP-20261128-16) / materializeAndInstall.
#   S4 the materialise loop's stop takes the not-started apps off the queue: qDrop(SignOutGate.rest(work, i)).
#   S5 AUTO-SWEEP 0 is still sent from sweepAuto's finally.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of the three files, each of which must FAIL a named check. A mutant that
# does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-signout-sweep-java.sh            # the cases and the source checks
#   bash test-signout-sweep-java.sh --mutate   # ... plus the mutants
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
  echo "test-signout-sweep-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-signout-sweep-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/signout-sweep/SignOutGateCases.java

# cases <root>: compile <root>'s SignOutGate with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SignOutGate.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SignOutGateCases
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

# sources <root>: S1-S5 over <root>'s ProfileActivity.java and UnarchiveService.java.
sources() {
  local r=$1 logoff sweep bad=0
  logoff=$(code "$r/$CH/ProfileActivity.java" "    private void doLogoffImpl(final boolean forInstall) {")
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  if [ -z "$logoff" ] || [ -z "$sweep" ]; then echo "FAIL S0 doLogoffImpl or sweepAuto not found"; return 1; fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      my $n = () = $c =~ /SignOutGate\.begin\(\);/g; exit 1 unless $n == 1;
      my $b = index($c, "SignOutGate.begin();");
      for my $after ("DozeAppsMirror.capture(this);") { my $p = index($c, $after); exit 1 if $p < 0 || $p > $b; }
      for my $before ("String pn = profileName();", "AppHeld.releaseForSignOut", "os.write(\"LOGOUT\\n\"") {
        my $p = index($c, $before); exit 1 if $p < 0 || $p < $b; }
      exit 0;' <<<"$logoff"; then
    echo "ok S1 doLogoffImpl raises SignOutGate.begin() after DozeAppsMirror.capture, before profileName()/captures/LOGOUT"
  else
    echo "FAIL S1 doLogoffImpl does not call SignOutGate.begin() exactly once after DozeAppsMirror.capture(this); and before String pn = profileName();, AppHeld.releaseForSignOut and the LOGOUT write"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      my $n = () = $c =~ /SignOutGate\.end\(\);/g; exit 1 unless $n == 2;
      exit 1 unless $c =~ /if \(sealFailed\) \{\s*SignOutGate\.end\(\);(.*?)\breturn;/s;
      exit 1 unless $c =~ /if \(LogoutAck\.lockLanding\(reply\)\) \{(?:(?!\breturn;).)*?SignOutGate\.end\(\);/s;
      exit 0;' <<<"$logoff"; then
    echo "ok S2 the sealFailed branch lowers it first and the lockLanding branch before its return; nothing else in doLogoffImpl does"
  else
    echo "FAIL S2 the if (sealFailed) { branch does not call SignOutGate.end(); as its first statement before its return;, the if (LogoutAck.lockLanding(reply)) { branch does not call it before its return; (or another path in doLogoffImpl lowers it)"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      exit 1 unless $c =~ /for \(int c = 0; c < retry\.size\(\); c \+= OdRestoreList\.CHUNK\) \{\s*if \(SignOutGate\.begun\(\)\) break;\s*java\.util\.List<String> chunk = [^;]*;\s*MAT_LOCK\.lock\(\);.*?restoreOnlyListLocked\(keep\)/s;
      exit 1 if $c =~ /for \(String pkg : work\)/;
      exit 1 unless $c =~ /for \(int i = 0; i < work\.size\(\); i\+\+\) \{\s*if \(SignOutGate\.begun\(\)\) \{(?:(?!materializeAndInstall).)*?\bbreak;\s*\}\s*String pkg = work\.get\(i\);.*?materializeAndInstall\(pkg, true\)/s;
      exit 0;' <<<"$sweep"; then
    echo "ok S3 both sweep loops check SignOutGate.begun() before their restore / materialise"
  else
    echo "FAIL S3 sweepAuto's restore-only loop (before MAT_LOCK.lock()) or its indexed materialise loop (before materializeAndInstall) does not stop on SignOutGate.begun()"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      exit 1 unless $c =~ /if \(SignOutGate\.begun\(\)\) \{\s*qDrop\(SignOutGate\.rest\(work, i\)\);(?:(?!materializeAndInstall).)*?"#130 sweep: stopped for a sign-out -- " \+ \(work\.size\(\) - i\)\s*\+ " app\(s\) not started \(Q116\)"\);\s*break;\s*\}/s;
      exit 0;' <<<"$sweep"; then
    echo "ok S4 the materialise loop stop drops the not-started apps (qDrop(SignOutGate.rest(work, i))) and logs counts"
  else
    echo "FAIL S4 the materialise loop's stop does not call qDrop(SignOutGate.rest(work, i)); then log the count and break"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      my $n = () = $c =~ /DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n", 30000\);/g; exit 1 unless $n == 1;
      exit 1 unless $c =~ /\}\s*finally\s*\{\s*DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n", 30000\);\s*\}/;
      exit 0;' <<<"$sweep"; then
    echo "ok S5 AUTO-SWEEP 0 is still sent from sweepAuto's finally"
  else
    echo "FAIL S5 sweepAuto no longer sends AUTO-SWEEP\\n0\\n from a finally"; bad=1
  fi
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
mut() { # mut <label> <file name under $CH> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in SignOutGate.java ProfileActivity.java UnarchiveService.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
mut "M1 begin() removed from doLogoffImpl" ProfileActivity.java 's/^[ \t]*SignOutGate\.begin\(\);\n//m' S1 || fails=$((fails+1))
mut "M2 the first end() removed (the lockLanding branch's)" ProfileActivity.java 's/^[ \t]*SignOutGate\.end\(\);[^\n]*\n//m' S2 || fails=$((fails+1))
mut "M2b end() removed from the sealFailed branch" ProfileActivity.java 's/(if \(sealFailed\) \{\s*)SignOutGate\.end\(\);[^\n]*\n/$1/s' S2 || fails=$((fails+1))
mut "M2c end() moved after the lockLanding branch's return" ProfileActivity.java 's/(if \(LogoutAck\.lockLanding\(reply\)\) \{(?:(?!\breturn;).)*?)SignOutGate\.end\(\);\n((?:(?!\breturn;).)*?\breturn;)/$1$2 SignOutGate.end();/s' S2 || fails=$((fails+1))
mut "M3 the materialise loop's check removed" UnarchiveService.java 's/if \(SignOutGate\.begun\(\)\) \{/if (false) {/' S3 || fails=$((fails+1))
mut "M4 the restore-only loop's check removed" UnarchiveService.java 's/^[ \t]*if \(SignOutGate\.begun\(\)\) break;[^\n]*\n//m' S3 || fails=$((fails+1))
mut "M5 the qDrop call removed" UnarchiveService.java 's/qDrop\(SignOutGate\.rest\(work, i\)\);//' S4 || fails=$((fails+1))
mut "M6 rest() starts at next+1" SignOutGate.java 's/Math\.max\(next, 0\)/Math.max(next + 1, 0)/' "G2 rest([a,b,c],1) is [b, c]" || fails=$((fails+1))
mut "M7 end() leaves the flag set" SignOutGate.java 's/static void end\(\) \{ BEGUN\.set\(false\); \}/static void end() { BEGUN.set(true); }/' "G1 begun() is false after end()" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
