#!/usr/bin/env bash
# test-logout-retry-java.sh [--mutate] -- the sign-out screen resends an undelivered LOGOUT once, inside one total
# bound, and logs the unknown cost before every other unacknowledged reboot, under javac (NWP-20261116-11).
#
# WHY THIS IS COMMITTED. Backlog row "The gate's own reboots lose every profile's pending telephony records: ...";
# its logoff-screen half is h46 #4 in docs/product-decisions.md (2026-10-28). doLogoffImpl made one bounded connect
# and one LOGOUT write, and rebooted at once when either failed: a daemon that init was restarting was never asked
# again, and the reboot took every profile's pending RAM-only telephony records with it. The decision: only a LOGOUT
# that was never delivered (no socket, or the write failed) is sent once more, after a bounded wait for the restart,
# inside one stated total bound; a delivered LOGOUT is never resent; before the other unacknowledged reboots the
# screen logs that an unknown number of records may be lost; the gate-only count verb is never asked.
#
# WHAT RUNS. LogoutRetry.java and LogoutAck.java are pure java and are compiled as-is with LogoutRetryCases (a fake
# Sender, a fake clock, recorded sleeps): C1-C10; C11-C11f drive LogoutAck.byDeadline and the four-argument answer
# with a fake socket on the SAME clock as the connects and the sleeps (RF-001: WAIT lines just inside the 90 s per-read
# timeout, connect time, a silent read), and check the resend ends within TOTAL_MS of the first failure. The PINS check the wiring in ProfileActivity.doLogoffImpl that the
# cases cannot see:
#   K1 LogoutRetry.run( is called exactly once
#   K2 "LOGOUT\n" is written exactly once, inside the Sender lambda, and that lambda ends before the run call
#   K3 inside the Sender a connect that ended past deadlineMs writes nothing; the answer is read through
#      LogoutAck.byDeadline(s.getInputStream(), elapsedRealtime, deadlineMs, s::setSoTimeout); LogoutAck.answer gets
#      the cap
#   K4 reply comes from LogoutRetry.run(sendLogout, elapsedRealtime, sleep).reply, then acked = LogoutAck.acked(reply)
#   K5 the if (!acked) block logs LogoutRetry.UNKNOWN_COST, alone on its line, before its reboot; the text lives once
#      in the chooser sources, in LogoutRetry.java
#   K6 neither doLogoffImpl nor LogoutRetry.java names TEL-PENDING
#   K7 LogoutRetry.java imports java.util.function members only
# MUTANTS R1-R17 (--mutate) must each be CONVICTED (rc 1); R1 (resend after a delivered LOGOUT) and R2 (no total
# bound) are the two the decision names.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-logout-retry-java.sh            # the cases and the pins
#   bash test-logout-retry-java.sh --mutate   # ... plus broken copies that must each FAIL
#   LOGOUT_RETRY_ACT=<copy> bash test-logout-retry-java.sh   # the pins against another ProfileActivity.java
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="${LOGOUT_RETRY_ACT:-$SRCDIR/ProfileActivity.java}"
RETRY="$SRCDIR/LogoutRetry.java"
ACK="$SRCDIR/LogoutAck.java"
CASES="$root/core/chooser/tests/logout-retry/LogoutRetryCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }

COST_TXT="an unknown number of pending telephony record(s) may be lost"

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` inside a string literal is kept). As test-signout-sweep-java.sh's.
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

# pins <ProfileActivity.java> <LogoutRetry.java> -> 0 pass, 1 a pin failed
pins() {
  local f="$1" retry="$2" b n_other imports other
  b=$(code "$f" "    private void doLogoffImpl(final boolean forInstall) {")
  [ -n "$b" ] || { echo "  PIN K0 doLogoffImpl not found" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'my $n = () = /LogoutRetry\.run\(/g; exit($n == 1 ? 0 : 1)' || {
    echo "  PIN K1 doLogoffImpl does not call LogoutRetry.run( exactly once" >&2; return 1; }
  printf '%s' "$b" | perl -0ne '
    my $n = () = /"LOGOUT\\n"/g; exit 1 unless $n == 1;
    exit 1 unless /final LogoutRetry\.Sender sendLogout = \(capMs, deadlineMs\) -> \{\n(.*?)\n            \};\n/s;
    my ($lam, $end) = ($1, $+[0]);
    exit 1 unless $lam =~ /"LOGOUT\\n"/;
    my $run = index($_, "LogoutRetry.run(sendLogout,");
    exit(($run >= $end) ? 0 : 1)' || {
    echo "  PIN K2 the LOGOUT write is not written once, inside the Sender lambda, which ends before LogoutRetry.run" >&2; return 1; }
  printf '%s' "$b" | perl -0ne '
    exit 1 unless /final LogoutRetry\.Sender sendLogout = \(capMs, deadlineMs\) -> \{\n(.*?)\n            \};\n/s;
    my $lam = $1;
    exit 1 unless $lam =~ /if \(android\.os\.SystemClock\.elapsedRealtime\(\) >= deadlineMs\) \{\s*return new LogoutRetry\.Result\(false, null\);\s*\}.*os\.write\("LOGOUT\\n"/s;
    exit 1 unless $lam =~ /os\.write\("LOGOUT\\n".*LogoutAck\.byDeadline\(\s*s\.getInputStream\(\),\s*android\.os\.SystemClock::elapsedRealtime,\s*deadlineMs,\s*s::setSoTimeout\)/s;
    exit 1 unless $lam =~ /LogoutAck\.answer\(.*?\}\),\s*capMs\);/s;
    exit 0' || {
    echo "  PIN K3 the Sender does not refuse to write past deadlineMs, read through LogoutAck.byDeadline(s.getInputStream(), elapsedRealtime, deadlineMs, s::setSoTimeout), or pass capMs to LogoutAck.answer" >&2; return 1; }
  printf '%s' "$b" | perl -0ne '
    exit(/reply = LogoutRetry\.run\(sendLogout,\s*android\.os\.SystemClock::elapsedRealtime,\s*android\.os\.SystemClock::sleep\)\.reply;\s*acked = LogoutAck\.acked\(reply\);/s ? 0 : 1)' || {
    echo "  PIN K4 reply is not LogoutRetry.run(sendLogout, elapsedRealtime, sleep).reply followed by acked = LogoutAck.acked(reply)" >&2; return 1; }
  printf '%s' "$b" | perl -0ne '
    exit 1 unless /\n([ \t]*)if \(!acked\) \{\n(.*?)\n\1\}\n/s;
    my $blk = "\n" . $2 . "\n";
    my $l = index($blk, "\n" . $1 . "    Log.w(\"NowhereProfile\", LogoutRetry.UNKNOWN_COST);\n");
    my $r = index($blk, ".reboot(");
    exit(($l >= 0 && $r > $l) ? 0 : 1)' || {
    echo "  PIN K5 the if (!acked) block does not log LogoutRetry.UNKNOWN_COST alone on its line before its reboot" >&2; return 1; }
  [ "$(grep -cF "\"$COST_TXT\"" "$retry" || true)" = 1 ] || {
    echo "  PIN K5 UNKNOWN_COST's text is not in LogoutRetry.java exactly once" >&2; return 1; }
  n_other=$(find "$(dirname "$f")" -name '*.java' ! -name LogoutRetry.java -exec grep -hF "$COST_TXT" {} + | wc -l)
  [ "$n_other" = 0 ] || { echo "  PIN K5 UNKNOWN_COST's text is in $n_other other chooser source line(s)" >&2; return 1; }
  [[ "$b" != *TEL-PENDING* ]] && ! grep -qF 'TEL-PENDING' "$retry" || {
    echo "  PIN K6 doLogoffImpl or LogoutRetry.java names TEL-PENDING (a gate-only verb)" >&2; return 1; }
  imports=$(grep -E '^import ' "$retry" || true)
  other=$(printf '%s\n' "$imports" | grep -vE '^(import java\.util\.function\.[A-Za-z]+;)?$' || true)
  [ -n "$imports" ] && [ -z "$other" ] || {
    echo "  PIN K7 LogoutRetry.java imports something other than java.util.function members" >&2; return 1; }
  return 0
}

# suite <ProfileActivity.java> <LogoutRetry.java> <LogoutAck.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the classes did not compile. Only 1 convicts.
suite() {
  local f="$1" retry="$2" ack="$3" o src
  for src in "$f" "$retry" "$ack" "$CASES"; do [ -f "$src" ] || { echo "  FAIL missing $src" >&2; return 2; }; done
  o=$(mktemp -d -p "$W")
  cp "$retry" "$ack" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/LogoutRetry.java" "$o/LogoutAck.java" \
    "$o/$(basename "$CASES")" || { echo "  FAIL the classes did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$o" com.nowhere.chooser.LogoutRetryCases || return 1
  pins "$f" "$retry" || return 1
  echo "  pins ok"
  return 0
}

echo "== $ACT"
suite "$ACT" "$RETRY" "$ACK" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: retry|ack|act> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc a r k orig copy
  d=$(mktemp -d -p "$W"); mkdir "$d/src"; a="$d/src/ProfileActivity.java"; r="$d/src/LogoutRetry.java"; k="$d/LogoutAck.java"
  cp "$ACT" "$a"; cp "$RETRY" "$r"; cp "$ACK" "$k"
  case "$target" in
    retry) orig="$RETRY"; copy="$r" ;;
    ack)   orig="$ACK";   copy="$k" ;;
    *)     orig="$ACT";   copy="$a" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$orig"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$r" "$k" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'R1 resend after a delivered LOGOUT' retry 's/if \(first\.delivered\) return first;/if (first.delivered \&\& LogoutAck.acked(first.reply)) return first;/'
mut 'R2 no total bound (the resend capped at MAX_WAIT_MS)' retry 's/long cap = TOTAL_MS - spent;/long cap = LogoutAck.MAX_WAIT_MS;/'
mut 'R3 no wait (resend at once)' retry 's/\n[ \t]*sleepMs\.accept\(POLL_MS\);//'
mut 'R4 a second delivered resend' retry 's/if \(r\.delivered\) return r;/if (r.delivered \&\& LogoutAck.acked(r.reply)) return r;/'
mut 'R5 the unknown-cost log removed' act 's/\n[ \t]*Log\.w\("NowhereProfile", LogoutRetry\.UNKNOWN_COST\);//'
mut 'R6 TEL-PENDING asked' act 's/(\n([ \t]*)Log\.w\("NowhereProfile", LogoutRetry\.UNKNOWN_COST\);)/\n$2sendDaemon("TEL-PENDING\\n");$1/'
mut 'R7 the restart wait unbounded' retry 's/if \(spent > RESTART_WAIT_MS\) return last;/if (spent > 10 * RESTART_WAIT_MS) return last;/'
mut 'R8 the four-argument answer ignores its cap' ack 's/- start >= capMs\)/- start >= MAX_WAIT_MS)/'
mut 'R9 the Sender drops the cap' act 's/\}\), capMs\);/}));/'
mut 'R10 LOGOUT also written outside the Sender' act 's/(acked = LogoutAck\.acked\(reply\);)/$1\n                sendDaemon("LOGOUT\\n");/'
mut 'R11 LogoutRetry.run bypassed' act 's/LogoutRetry\.run\(sendLogout,\s*android\.os\.SystemClock::elapsedRealtime,\s*android\.os\.SystemClock::sleep\)/sendLogout.send(LogoutAck.MAX_WAIT_MS, LogoutRetry.NO_DEADLINE)/'
mut 'R12 the resend has no deadline' retry 's/Result r = s\.send\(cap, deadline\);/Result r = s.send(cap, NO_DEADLINE);/'
mut 'R13 the deadline counts from each resend, not the first failure' retry 's/Result r = s\.send\(cap, deadline\);/Result r = s.send(cap, nowMs.getAsLong() + TOTAL_MS);/'
mut 'R14 byDeadline keeps the 90 s timeout near the deadline' ack 's/timeout\.set\(\(int\) Math\.min\(READ_MS, left\)\);/timeout.set(READ_MS);/'
mut 'R15 byDeadline reads past the deadline' ack 's/\n[ \t]*if \(left <= 0\) throw new InterruptedIOException\("LOGOUT deadline passed"\);\n[ \t]*timeout\.set\(\(int\) Math\.min\(READ_MS, left\)\);/\n                timeout.set((int) Math.max(0, Math.min(READ_MS, left)));/'
mut 'R16 the Sender ignores its deadline' act 's/deadlineMs,(\s*)s::setSoTimeout\)/LogoutRetry.NO_DEADLINE,$1s::setSoTimeout)/'
mut 'R17 the Sender writes past its deadline' act 's/\n[ \t]*if \(android\.os\.SystemClock\.elapsedRealtime\(\) >= deadlineMs\) \{\s*return new LogoutRetry\.Result\(false, null\);\s*\}//'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
