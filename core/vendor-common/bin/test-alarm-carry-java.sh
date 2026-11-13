#!/usr/bin/env bash
# test-alarm-carry-java.sh [--mutate] -- NWP-20261129-39: the evidence for the backlog row "A clock alarm set in a roamed
# session did not ring, and showed as missed when the clock was opened". A sign-out seals its next alarm's time, and the
# first relay after the next sign-in sends the verdict to login.log. Silent when it regresses: no report can then tell
# path (3), an alarm not registered again after the sign-in, from the other paths.
# Compiles the chooser's pure AlarmCarry with core/chooser/tests/alarm-carry ALONE and EXECUTES the cases (C1-C7), then
# checks the REAL ProfileActivity and CredentialService over their code with comments dropped (S1-S5):
#   C1  record then verdict gives each sealed and now token, the boundaries included (sealed == now is past).
#   C2  a second verdict returns null: the file is reported once, and it is gone.
#   C3  record(0) and a negative record delete the file.
#   C4  an absent file returns null.
#   C5  a malformed or unreadable file gives sealed=bad, and it is deleted.
#   C6  record leaves only the file in the dir, holding the decimal value, and a later record replaces it.
#   C7  a missing dir: neither method throws.
#   S1  doLogoffImpl records the value captureNextAlarm returned, once, before its LOGOUT.
#   S2  doColdLock captures the alarm and records nothing: a cold lock resumes the same user.
#   S3  relayNextAlarm calls verdict once, after its read's catch block.
#   S4  relayNextAlarm takes no verdict while a sign-out runs, and sends a verdict that is not null once, 8000 ms.
#   S5  captureNextAlarm returns long, and returns `when` after its SET-GATE-ALARM send.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies of AlarmCarry, ProfileActivity and CredentialService, each of which must FAIL a
# named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-alarm-carry-java.sh            # the cases and the source checks
#   bash test-alarm-carry-java.sh --mutate   # ... plus the mutants
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
  echo "test-alarm-carry-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-alarm-carry-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir, case dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/alarm-carry/AlarmCarryCases.java

# cases <root>: compile <root>'s AlarmCarry with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/AlarmCarry.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.AlarmCarryCases
}

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped and
# trailing `//` comments stripped (a `//` inside a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$@"
}

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3"; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# sources <root>: S1-S5 over <root>'s ProfileActivity.java and CredentialService.java.
sources() {
  local r=$1 pa cs logoff lock cap relay bad=0
  pa=$r/$CH/ProfileActivity.java
  cs=$r/$CH/CredentialService.java
  logoff=$(code "$pa" "    private void doLogoffImpl(final boolean forInstall) {")
  lock=$(code "$pa" "    private void doColdLock() {")
  cap=$(code "$pa" "    private long captureNextAlarm() {")
  relay=$(code "$cs" "    private static void relayNextAlarm(Context ctx, String trigger) {")
  [ -n "$logoff" ] || { echo "FAIL S1 doLogoffImpl not found"; bad=1; }
  [ -n "$lock" ] || { echo "FAIL S2 doColdLock not found"; bad=1; }
  [ -n "$cap" ] || { echo "FAIL S5 captureNextAlarm does not return long"; bad=1; }
  [ -n "$relay" ] || { echo "FAIL S3 relayNextAlarm not found"; bad=1; }
  [ "$bad" -eq 0 ] || return 1
  pin S1 "doLogoffImpl records the value captureNextAlarm returned, once, before its LOGOUT" '
    my $n = () = $c =~ /AlarmCarry\.record\(/g; exit 1 unless $n == 1;
    $c =~ /long (\w+) = captureNextAlarm\(\);\s*AlarmCarry\.record\(getFilesDir\(\), \1\);/ or exit 1;
    my $rec = $-[0];
    my $out = index($c, "LogoutRetry.run("); exit 1 if $out < 0;
    exit(($rec < $out) ? 0 : 1);' <<<"$logoff" || bad=1
  pin S2 "doColdLock captures the alarm and records nothing" '
    exit 1 if $c =~ /AlarmCarry/;
    exit(($c =~ /\n\s*captureNextAlarm\(\);/) ? 0 : 1);' <<<"$lock" || bad=1
  pin S3 "relayNextAlarm calls verdict once, after its read succeeded" '
    my $n = () = $c =~ /AlarmCarry\.verdict\(/g; exit 1 unless $n == 1;
    $c =~ /\n(\s*)\} catch \(Throwable t\) \{.*?\n\1\}\n/s or exit 1;
    my ($catch, $end) = ($-[0], $+[0]);
    exit 1 unless substr($c, $catch, $end - $catch) =~ /\breturn;/;
    my $null = index($c, "am == null"); exit 1 if $null < 0 || $null > $catch;
    exit((index($c, "AlarmCarry.verdict(") >= $end) ? 0 : 1);' <<<"$relay" || bad=1
  pin S4 "relayNextAlarm takes no verdict while a sign-out runs, and sends a verdict once" '
    $c =~ /String (\w+) = SignOutGate\.begun\(\) \? null : AlarmCarry\.verdict\(ctx\.getFilesDir\(\), System\.currentTimeMillis\(\), when\);\s*if \(\1 != null\) \{(.*?)\n\s*\}\n/s
      or exit 1;
    my ($v, $body) = ($1, $2);
    my $n = () = $c =~ /"ALARM-CARRY/g; exit 1 unless $n == 1;
    exit((index($body, "DaemonSocket.roundTrip(\"ALARM-CARRY\\n\" + $v + \"\\n\", 8000)") >= 0) ? 0 : 1);' <<<"$relay" || bad=1
  pin S5 "captureNextAlarm returns the time it read, after its send" '
    my $send = index($c, "SET-GATE-ALARM"); exit 1 if $send < 0;
    $c =~ /\n\s*return when;\s*\z/ or exit 1;
    exit(($-[0] > $send) ? 0 : 1);' <<<"$cap" || bad=1
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
  for n in "$CH/AlarmCarry.java" "$CH/ProfileActivity.java" "$CH/CredentialService.java"; do
    cp "$ROOT/$n" "$d/$n"
  done
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
A=$CH/AlarmCarry.java
P=$CH/ProfileActivity.java
C=$CH/CredentialService.java
fails=0
mut "K1 the delete in verdict removed" "$A" 's/long sealed = read\(f\);\n\s*f\.delete\(\);/long sealed = read(f);/' C2 || fails=$((fails+1))
mut "K2 the past/future comparison flipped" "$A" 's/sealed <= nowMs \? "past" : "future"/sealed <= nowMs ? "future" : "past"/' C1 || fails=$((fails+1))
mut "K3 same, earlier and later swapped" "$A" 's/registered == sealed \? "same"\n(\s*): registered < sealed \? "earlier" : "later"/registered == sealed ? "later"\n$1: registered < sealed ? "same" : "earlier"/' C1 || fails=$((fails+1))
mut "K4 record(0) no longer deletes" "$A" 's/if \(when <= 0L\) \{\n\s*f\.delete\(\);/if (when <= 0L) {/' C3 || fails=$((fails+1))
mut "K5 the doLogoffImpl record removed" "$P" 's/^[ \t]*AlarmCarry\.record\(getFilesDir\(\), nextAlarm\);[^\n]*\n//m' S1 || fails=$((fails+1))
mut "K6 verdict moved into the catch" "$C" 's/(String carry = SignOutGate\.begun\(\) \? null : AlarmCarry\.verdict\([^\n]*\n)//; s/(could not read the next alarm", t\);\n)/$1            String moved = AlarmCarry.verdict(ctx.getFilesDir(), System.currentTimeMillis(), 0L);\n/; s/if \(carry != null\) \{/String carry = null;\n        if (carry != null) {/' S3 || fails=$((fails+1))
mut "K7 the sign-out guard removed" "$C" 's/SignOutGate\.begun\(\) \? null : AlarmCarry\.verdict\(/AlarmCarry.verdict(/' S4 || fails=$((fails+1))
mut "K8 doColdLock also records" "$P" 's/(new Thread\(\(\) -> \{\n\s*)captureNextAlarm\(\);(\n\s*\/\/ NWP-20261006-23)/$1AlarmCarry.record(getFilesDir(), captureNextAlarm());\n            captureNextAlarm();$2/' S2 || fails=$((fails+1))
mut "K9 captureNextAlarm returns 0 always" "$P" 's/\n\s*return when;\n/\n        return 0L;\n/' S5 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
