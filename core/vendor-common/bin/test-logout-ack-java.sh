#!/usr/bin/env bash
# test-logout-ack-java.sh [--mutate] -- the sign-out screen reads WAIT lines ahead of LOGOUT's answer, under javac
# (NWP-20261106-01).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (Q116, 2026-10-20) has the daemon send a progress line before it
# takes the session lock, so a sign-out behind a long download is not read as a dead daemon and does not reboot the
# phone. The reader goes first: LogoutAck.java is pure java and is compiled as-is with LogoutAckCases; the PINS below
# check the wiring the cases cannot see (doLogoffImpl reads LOGOUT's reply only through LogoutAck.answer, acks only
# through LogoutAck.acked, and keeps its per-read socket timeout).
#
# NWP-20261107-08 adds the wait line (dn-1106 #3): LogoutAck.WAIT_LINE, answer's onFirstWait, and the pins P6-P9 that
# doLogoffImpl shows it on the UI thread from a view that starts GONE and hides it when the answer arrives.
#
# NWP-20261111-08 adds LogoutAck.LOCK_LANDING (Q067, DECIDED 2026-10-20): LOGOUT answered "BUSY COLDLOCK" while a
# key-bound cold lock holds the session. The pins P10-P12 check that doLogoffImpl tests lockLanding(reply) after the
# wait line is hidden and before the `if (!acked)` reboot, and that the branch neither reboots nor polls SEAL-STATUS,
# lowers SignOutGate, rebuilds the held list before it hands the UI back, and returns. Mutants L9-L15 (the task's
# L1-L5 are L9-L13; L14 drops the return, L15 drops the held-list rebuild).
#
# NWP-20261116-11 moves the LOGOUT send into LogoutRetry's Sender lambda (h46 #4): the per-read timeout is now set
# before every read by LogoutAck.byDeadline(..., s::setSoTimeout) (90 s, less near the resend's deadline), and the
# answer is the four-argument LogoutAck.answer with the cap, so P5, P6 and the mutants L2, L5, L7, L8 and Q6 read those
# forms; each keeps what it pinned. test-logout-retry-java.sh pins the rest and runs byDeadline.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-logout-ack-java.sh            # the cases and the pins
#   bash test-logout-ack-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ProfileActivity.java"
CLS="$SRCDIR/LogoutAck.java"
CASES="$root/core/chooser/tests/logout-ack/LogoutAckCases.java"
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

LINE_TXT="Finishing an app download first. Your session is saved and closed as soon as it's done."

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# suite <ProfileActivity.java> <LogoutAck.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" b sl o na nr blk n_line n_other br
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$CASES" ] || { echo "  FAIL missing $CASES" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$cls" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/$(basename "$cls")" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$o" com.nowhere.chooser.LogoutAckCases || return 1

  b=$(body "$f" 'private void doLogoffImpl(final boolean forInstall)')
  # P1: the slice from the LOGOUT write to the first `acked =` after it exists, in that order
  sl=$(printf '%s\n' "$b" | awk '/os\.write\("LOGOUT\\n"/ { on=1 } on { print } on && /acked =/ { exit }')
  [[ "$sl" == *'os.write("LOGOUT\n"'* && "$sl" == *'acked ='* ]] || {
    echo "  PIN P1 no slice from the LOGOUT write to acked =" >&2; return 1; }
  sl=$(printf '%s\n' "$sl" | grep -v '^[[:space:]]*//')
  # P2: exactly one LogoutAck.answer( and no readLine
  na=$(printf '%s\n' "$sl" | grep -o 'LogoutAck\.answer(' | wc -l)
  nr=$(printf '%s\n' "$sl" | grep -c '\.readLine(' || true)
  [ "$na" = 1 ] && [ "$nr" = 0 ] || {
    echo "  PIN P2 LOGOUT's reply: $na LogoutAck.answer( and $nr readLine( between the write and acked =" >&2; return 1; }
  # P3: acked is set through LogoutAck.acked( and nowhere else
  [[ "$(printf '%s\n' "$sl" | tail -1)" == *'acked = LogoutAck.acked('* ]] || {
    echo "  PIN P3 the acked = line is not acked = LogoutAck.acked(" >&2; return 1; }
  [ "$(printf '%s\n' "$b" | grep -c 'acked = ')" = 2 ] || {
    echo "  PIN P3 doLogoffImpl assigns acked other than 'boolean acked = false;' and the LogoutAck.acked( line" >&2; return 1; }
  # P4: the answer is timed on elapsedRealtime
  [[ "$sl" == *'android.os.SystemClock::elapsedRealtime'* ]] || {
    echo "  PIN P4 LogoutAck.answer is not given android.os.SystemClock::elapsedRealtime" >&2; return 1; }
  # P5: the per-read socket timeout is set on the socket before every read of LOGOUT's answer (LogoutAck.byDeadline)
  printf '%s' "$b" | perl -0ne 'exit(/os\.write\("LOGOUT\\n".*LogoutAck\.answer\(new BufferedReader\(new InputStreamReader\(LogoutAck\.byDeadline\(\s*s\.getInputStream\(\),\s*android\.os\.SystemClock::elapsedRealtime,\s*deadlineMs,\s*s::setSoTimeout\),\s*"UTF-8"\)\)/s ? 0 : 1)' || {
    echo "  PIN P5 LOGOUT's answer is not read through LogoutAck.byDeadline(s.getInputStream(), elapsedRealtime, deadlineMs, s::setSoTimeout) after the write" >&2; return 1; }
  # P6: the four-argument answer gets a Runnable that sets the view to WAIT_LINE inside runOnUiThread
  printf '%s' "$b" | perl -0ne 'exit(/LogoutAck\.answer\(.*?android\.os\.SystemClock::elapsedRealtime,\s*\(\)\s*->\s*runOnUiThread\(\(\)\s*->\s*\{[^}]*waitLine\.setText\(LogoutAck\.WAIT_LINE\);[^}]*waitLine\.setVisibility\(View\.VISIBLE\);[^}]*\}\),\s*capMs\)/s ? 0 : 1)' || {
    echo "  PIN P6 LogoutAck.answer is not given a Runnable that shows LogoutAck.WAIT_LINE inside runOnUiThread" >&2; return 1; }
  # P7: the view starts GONE (and is never made VISIBLE before it is added)
  blk=$(printf '%s\n' "$b" | awk '/TextView waitLine = new TextView\(this\)/ { on=1 } on { print } on && /lo\.addView\(waitLine/ { exit }')
  [[ "$blk" == *'waitLine.setVisibility(View.GONE);'* && "$blk" != *'View.VISIBLE'* && "$blk" == *'lo.addView(waitLine'* ]] || {
    echo "  PIN P7 the wait line does not start GONE" >&2; return 1; }
  # P8: it is hidden again once LOGOUT's reply (or none) is in, before the acked branch
  printf '%s' "$b" | perl -0ne 'exit(/acked = LogoutAck\.acked\(reply\);.*?catch \(Exception ignore\) \{.*?\}\s*runOnUiThread\(\(\) -> waitLine\.setVisibility\(View\.GONE\)\);.*?if \(acked\)/s ? 0 : 1)' || {
    echo "  PIN P8 the wait line is not hidden when LOGOUT's answer arrives" >&2; return 1; }
  # P9: the sentence lives once in the chooser sources, in LogoutAck
  n_line=$(grep -cF "$LINE_TXT" "$cls" || true)
  n_other=$(find "$SRCDIR" -name '*.java' ! -name LogoutAck.java -exec grep -hF "$LINE_TXT" {} + | wc -l)
  [ "$n_line" = 1 ] && [ "$n_other" = 0 ] || {
    echo "  PIN P9 WAIT_LINE's text: $n_line in LogoutAck.java, $n_other in the other chooser sources" >&2; return 1; }
  # P10: one lockLanding(reply) test, after the wait line is hidden and before the `if (acked)` poll and the reboot
  printf '%s' "$b" | perl -0ne '
    my $k = "if (LogoutAck.lockLanding(reply)) {"; my $n = () = /\Q$k\E/g; exit 1 unless $n == 1;
    my $p = index($_, $k); my $h = index($_, "runOnUiThread(() -> waitLine.setVisibility(View.GONE));");
    my $a = index($_, "if (acked) {"); my $r = index($_, "if (!acked) {");
    exit(($h >= 0 && $h < $p && $a > $p && $r > $p) ? 0 : 1)' || {
    echo "  PIN P10 doLogoffImpl does not test LogoutAck.lockLanding(reply) once, after the wait line is hidden and before if (acked) / if (!acked)" >&2; return 1; }
  # P11: the branch neither reboots nor polls; it rebuilds the held list, then hands the UI back, then returns
  br=$(printf '%s' "$b" | perl -0ne 'print $1 if /(if \(LogoutAck\.lockLanding\(reply\)\) \{.*?\breturn;\s*\})/s')
  printf '%s' "$br" | perl -0ne '
    exit 1 if $_ eq "" || /reboot\(/ || /sealStatus\(/;
    my $t = index($_, "new Thread(() -> AppHeld.refresh(this), \"nowhere-heldrebuild\").start();");
    exit 1 unless /runOnUiThread\(\(\) -> \{\s*loggingOff = false;\s*finish\(\);\s*\}\);\s*return;\s*\}\z/s;
    my $u = index($_, "runOnUiThread(");
    exit(($t >= 0 && $t < $u) ? 0 : 1)' || {
    echo "  PIN P11 the lockLanding branch reboots, polls sealStatus, skips AppHeld.refresh before the UI hop, or does not end in runOnUiThread(loggingOff = false; finish();) + return" >&2; return 1; }
  # P12: the branch lowers SignOutGate
  [[ "$br" == *'SignOutGate.end();'* ]] || {
    echo "  PIN P12 the lockLanding branch does not lower SignOutGate" >&2; return 1; }
  echo "  pins ok"
  return 0
}

echo "== $ACT"
suite "$ACT" "$CLS" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc a c
  d=$(mktemp -d -p "$W"); a="$d/ProfileActivity.java"; c="$d/LogoutAck.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'L1 prefix without the space' cls 's/WAIT_PREFIX = "WAIT ";/WAIT_PREFIX = "WAIT";/'
mut 'L2 no cap' cls 's/if \(nowMs\.getAsLong\(\) - start >= capMs\) return null;//'
mut 'L3 first line whatever it is' cls 's/if \(!line\.startsWith\(WAIT_PREFIX\)\) return line;/if (true) return line;/'
mut 'L4 acked accepts a WAIT line' cls 's/answer\.startsWith\("OK"\)/(answer.startsWith("OK") || answer.startsWith(WAIT_PREFIX))/'
mut 'L5 doLogoffImpl back to readLine()' act 's/LogoutAck\.answer\((new BufferedReader\(new InputStreamReader\(LogoutAck\.byDeadline\(.*?\),\s*"UTF-8"\)\)),\s*android\.os\.SystemClock::elapsedRealtime.*?\}\),\s*capMs\);/$1.readLine();/s'
mut 'L6 the old acked line back' act 's/acked = LogoutAck\.acked\(reply\);/acked = reply != null \&\& reply.startsWith("OK");/'
mut 'L7 cap off by one (> for >=)' cls 's/- start >= capMs/- start > capMs/'
mut 'L8 per-read timeout dropped' act 's/s::setSoTimeout\)/ms -> {})/g'
mut 'Q1 onFirstWait run at every WAIT' cls 's/if \(!told\) \{ told = true; onFirstWait\.run\(\); \}/onFirstWait.run();/'
mut 'Q2 onFirstWait never run' cls 's/if \(!told\) \{ told = true; onFirstWait\.run\(\); \}//'
mut 'Q3 onFirstWait run for the answer line' cls 's/if \(!line\.startsWith\(WAIT_PREFIX\)\) return line;/if (!line.startsWith(WAIT_PREFIX)) { onFirstWait.run(); return line; }/'
mut 'Q4 the line text changed' cls 's/app download first\. Your/app download first, Your/'
mut 'Q5 the view starts VISIBLE' act 's/waitLine\.setVisibility\(View\.GONE\);/waitLine.setVisibility(View.VISIBLE);/'
mut 'Q6 doLogoffImpl back on the two-argument form' act 's/(android\.os\.SystemClock::elapsedRealtime),\s*\(\)\s*->\s*runOnUiThread\(.*?\}\),\s*capMs\);/$1, capMs);/s'
mut 'L9 lockLanding by startsWith("BUSY")' cls 's/LOCK_LANDING\.equals\(answer\.replaceFirst\([^;]*\)\);/answer.startsWith("BUSY");/'
mut 'L10 the lockLanding branch removed' act 's/\n[ \t]*if \(LogoutAck\.lockLanding\(reply\)\) \{.*?\breturn;\s*\}//s'
mut 'L11 the branch after the reboot block' act 's/(\n[ \t]*if \(LogoutAck\.lockLanding\(reply\)\) \{.*?\breturn;\s*\})(.*?if \(!acked\) \{.*?finish\(\);\s*\}\s*\})/$2$1/s'
mut 'L12 acked true for LOCK_LANDING' cls 's/answer\.startsWith\("OK"\)/(answer.startsWith("OK") || lockLanding(answer))/'
mut 'L13 SignOutGate lowering dropped from the branch' act 's/(if \(LogoutAck\.lockLanding\(reply\)\) \{(?:(?!\breturn;).)*?)SignOutGate\.end\(\);[^\n]*\n/$1/s'
mut 'L14 the branch falls through (return dropped)' act 's/(if \(LogoutAck\.lockLanding\(reply\)\) \{(?:(?!\breturn;).)*?)\breturn;(\s*\})/$1$2/s'
mut 'L15 held-list rebuild dropped from the branch' act 's/(if \(LogoutAck\.lockLanding\(reply\)\) \{(?:(?!\breturn;).)*?)new Thread\(\(\) -> AppHeld\.refresh\(this\), "nowhere-heldrebuild"\)\.start\(\);[^\n]*\n/$1/s'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
