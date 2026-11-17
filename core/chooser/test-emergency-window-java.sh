#!/usr/bin/env bash
# test-emergency-window-java.sh [--mutate] -- the chooser client of the Q047 emergency-window verbs, run under javac
# (NWP-20261206-03).
#
# WHY THIS IS COMMITTED. The chooser remembers an outbound emergency call in a per-process static, and that static does
# not survive a user switch (docs/backlog.md, "The emergency-callback window does not survive a user switch, so a PSAP
# callback after a login can be rejected"). Q047 decided that the daemon also holds the mark: EmergencyWindow tells it
# (EMERGENCY-MARK) and asks it (EMERGENCY-RECENT) within 1.5 s, and no answer in time lets the call ring. The decision is
# EmergencyWindowRule.java, pure Java, so tests/emergency-window/run.sh compiles it with EmergencyWindowCases and runs
# them; the PINS below read EmergencyWindow.java (the I/O half) and NowhereCallControlService.java as data. Since
# NWP-20261115-18 the call-control service is wired to it, and P11-P13 hold that wiring: tell() in the outbound-emergency
# branch of onCallAdded, and signal 4 of emergencyExemption the rule over the static, with no local-only check left.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-emergency-window-java.sh            # the cases and the pins
#   bash test-emergency-window-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
ER="$DIR/EmergencyWindowRule.java"
EW="$DIR/EmergencyWindow.java"
CC="$DIR/NowhereCallControlService.java"
RUN="$here/tests/emergency-window/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $CC or $RUN" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# count <file> <fixed-string>: how many lines of <file> hold <fixed-string>.
count() {
  grep -cF -- "$2" "$1"
}

# suite <EmergencyWindowRule.java> <EmergencyWindow.java> <NowhereCallControlService.java>
#   -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local er="$1" ew="$2" cc="$3" n
  [ -f "$er" ] || { echo "  PIN   EmergencyWindowRule.java does not exist" >&2; return 1; }
  [ -f "$ew" ] || { echo "  PIN   EmergencyWindow.java does not exist" >&2; return 1; }
  # P1: the rule stays out of the daemon-verb scan's sender files, and stays pure.
  if perl -0ne 'exit(/DaemonSocket|LocalSocket|nowhere_login|android\./ ? 0 : 1)' "$er"; then
    echo "  PIN   P1 EmergencyWindowRule.java names the socket or android" >&2; return 1
  fi
  # P2: the two windows are equal.
  pin "$er" "P2 the rule's window is not 15 minutes" 'static final long WINDOW_MS = 15L \* 60L \* 1000L;' || return 1
  pin "$cc" "P2 the call-control window is not 15 minutes" 'EMERGENCY_CALLBACK_WINDOW_MS = 15L \* 60L \* 1000L;' || return 1
  # P3-P6: ask() is bounded as a whole and fails open.
  pin "$ew" "P3 ASK_CAP_MS is not 1500" 'static final int ASK_CAP_MS = 1500;' || return 1
  pin "$ew" "P4 ask() does not run the EMERGENCY-RECENT round trip on its own thread" \
    'static String ask\(\) \{.*?Thread t = new Thread\(\(\) -> \{.*?DaemonSocket\.roundTrip\("EMERGENCY-RECENT\\n", ASK_CAP_MS\).*?latch\.countDown\(\);.*?\}, "nowhere-emergency-ask"\);\s*t\.setDaemon\(true\);\s*t\.start\(\);' || return 1
  pin "$ew" "P5 ask() does not wait on the latch for at most ASK_CAP_MS" \
    'if \(!latch\.await\(ASK_CAP_MS, TimeUnit\.MILLISECONDS\)\) return null;' || return 1
  pin "$ew" "P6 ask() does not return null on an empty reply" \
    'return \(r == null \|\| r\.isEmpty\(\)\) \? null : r;' || return 1
  # P7: tell() never runs the round trip on the caller's thread.
  pin "$ew" "P7 tell() does not run the EMERGENCY-MARK round trip on its own thread" \
    'static void tell\(\) \{\s*Thread t = new Thread\(\(\) -> \{.*?DaemonSocket\.roundTrip\("EMERGENCY-MARK\\n", 3000\).*?\}, "nowhere-emergency-tell"\);\s*t\.setDaemon\(true\);\s*t\.start\(\);\s*\}' || return 1
  # P8: each literal request once, and no other round trip.
  n=$(count "$ew" 'roundTrip("EMERGENCY-MARK\n"'); [ "$n" = 1 ] || { echo "  PIN   P8 EMERGENCY-MARK is sent $n times" >&2; return 1; }
  n=$(count "$ew" 'roundTrip("EMERGENCY-RECENT\n"'); [ "$n" = 1 ] || { echo "  PIN   P8 EMERGENCY-RECENT is sent $n times" >&2; return 1; }
  n=$(count "$ew" 'roundTrip('); [ "$n" = 2 ] || { echo "  PIN   P8 EmergencyWindow.java has $n round trips, not 2" >&2; return 1; }
  # P9: the only log line names a class, never a number or the reply text.
  pin "$ew" "P9 the mark log line is not the class-only line" \
    'String c = EmergencyWindowRule\.markFailure\(r\);\s*if \(c != null\) android\.util\.Log\.w\("NowhereChooser", "emergency window: mark not recorded \(" \+ c \+ "\)"\);' || return 1
  n=$(count "$ew" 'Log.'); [ "$n" = 1 ] || { echo "  PIN   P9 EmergencyWindow.java has $n log lines, not 1" >&2; return 1; }
  # P10: the I/O entry point is the rule with the real clock and the bounded ask.
  pin "$ew" "P10 exemptReason(long) is not the rule over the clock and ask()" \
    'static String exemptReason\(long markedAtMs\) \{\s*return EmergencyWindowRule\.exemptReason\(markedAtMs, System\.currentTimeMillis\(\), EmergencyWindow::ask\);\s*\}' || return 1
  # P11-P13 (NWP-20261115-18): the call-control service is wired to the daemon's window. P11: tell() inside the
  # outbound-emergency branch, right after the static is set (comment lines only between), and nowhere else.
  pin "$cc" "P11 onCallAdded does not tell the daemon in the outbound-emergency branch, right after the static" \
    'tm\.isEmergencyNumber\(to\)\) \{[^}]*?\n\s*sLastEmergencyOutboundAt = System\.currentTimeMillis\(\);\n(?:\s*\/\/[^\n]*\n)*\s*EmergencyWindow\.tell\(\);\n' || return 1
  n=$(count "$cc" 'EmergencyWindow.tell()'); [ "$n" = 1 ] || { echo "  PIN   P11 EmergencyWindow.tell() occurs $n times, not once" >&2; return 1; }
  # P12: signal 4 of emergencyExemption is the rule over the static, between signals 3 and 5, and the only call of it.
  pin "$cc" "P12 signal 4 is not EmergencyWindow.exemptReason over the static" \
    'static String emergencyExemption\(Context app, Call\.Details d\) \{.*?\n\s*\/\/ 4\. [^\n]*\n(?:\s*\/\/[^\n]*\n)*\s*try \{\s*String recent = EmergencyWindow\.exemptReason\(sLastEmergencyOutboundAt\);\s*if \(recent != null\) return recent;\s*\} catch \(Throwable ignore\) \{\}\n\s*\/\/ 5\. ' || return 1
  n=$(count "$cc" 'EmergencyWindow.exemptReason('); [ "$n" = 1 ] || { echo "  PIN   P12 EmergencyWindow.exemptReason( occurs $n times, not once" >&2; return 1; }
  # P13: no local-only window check is left beside the rule (the rule owns the window's semantics).
  if perl -0ne 'exit(/long since = sLastEmergencyOutboundAt|< EMERGENCY_CALLBACK_WINDOW_MS/ ? 0 : 1)' "$cc"; then
    echo "  PIN   P13 NowhereCallControlService.java still checks the window locally, beside the rule" >&2; return 1
  fi
  bash "$RUN" "$er"
}

echo "== $ER"
suite "$ER" "$EW" "$CC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: er|ew|cc> <perl-expr> <convicting line>: the mutant is CONVICTED only when the suite fails AND its
# output holds <convicting line> (a fixed string: the failing case or pin the label names). A failure elsewhere proves
# nothing about the mutation the label claims.
mut() {
  local d src m erf ewf ccf rc
  d=$(mktemp -d -p "$W")
  erf="$ER"; ewf="$EW"; ccf="$CC"
  case "$2" in er) src="$ER" ;; ew) src="$EW" ;; cc) src="$CC" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in er) erf="$m" ;; ew) ewf="$m" ;; cc) ccf="$m" ;; esac
  suite "$erf" "$ewf" "$ccf" >"$d/out" 2>&1; rc=$?
  # Only a failing CASE ("--- FAIL") or a failing PIN convicts; a compile error (rc 3) is a broken mutant.
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) if grep -qF -- "$4" "$d/out"; then echo "  convicted $1"; return 0; fi
       echo "  WRONG     $1 -- the suite failed, but not on: $4"; sed 's/^/      /' "$d/out"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "R1 no answer fails closed (case daemon [null])"          er 's/if \(reply == null\) return FAIL_OPEN;/if (reply == null) return null;/' \
  '--- FAIL daemon [null]:' || fails=$((fails+1))
mut "R2 ask before the local check (case exempt local hit never asks)" er 's/(static String exemptReason\(long markedAtMs, long nowMs, Supplier<String> ask\) \{\n)/$1        ask.get();\n/' \
  '--- FAIL exempt local hit never asks:' || fails=$((fails+1))
mut "R3 the window's edge is inside (case local 900s misses)" er 's/if \(age < WINDOW_MS\)/if (age <= WINDOW_MS)/' \
  '--- FAIL local 900s misses:' || fails=$((fails+1))
mut "R4 a negative age is a miss (case local negative age counts as 0)" er 's/if \(age < WINDOW_MS\)/if (age >= 0 \&\& age < WINDOW_MS)/' \
  '--- FAIL local negative age counts as 0:' || fails=$((fails+1))
mut "R5 a bare YES without a number is a hit (case daemon [YES])" er 's/(\n(\s*)if \(!r\.startsWith\("YES "\)\) return null;)/\n$2if (r.equals("YES")) return "an emergency call left this phone 0s ago (daemon)";$1/' \
  '--- FAIL daemon [YES]:' || fails=$((fails+1))
mut "R6 ask() awaits without a timeout (pin P5)"              ew 's/if \(!latch\.await\(ASK_CAP_MS, TimeUnit\.MILLISECONDS\)\) return null;/latch.await();/' \
  'PIN   P5 ' || fails=$((fails+1))
mut "R7 tell() runs the mark on the caller's thread (pin P7)" ew 's/Thread t = new Thread\(\(\) -> \{(\n\s*String r = "";.*?)\}, "nowhere-emergency-tell"\);\s*t\.setDaemon\(true\);\s*t\.start\(\);/{$1}/s' \
  'PIN   P7 ' || fails=$((fails+1))
mut "R8 the rule names the socket (pin P1)"                   er 's/(final class EmergencyWindowRule \{\n)/$1    \/\/ DaemonSocket\n/' \
  'PIN   P1 ' || fails=$((fails+1))
mut "R9 the age after YES is not checked as a number (case daemon [YES -1])" er 's/\n\s*if \(!n\.matches\("\[0-9\]\{1,18\}"\)\) return null;\n/\n/' \
  '--- FAIL daemon [YES -1]:' || fails=$((fails+1))
mut "R10 tell() removed from the outbound-emergency branch (pin P11)" cc 's/\n[ \t]*EmergencyWindow\.tell\(\);\n/\n/' \
  'PIN   P11 ' || fails=$((fails+1))
mut "R11 tell() on every outbound call, not only an emergency one (pin P11)" cc 's/\n[ \t]*EmergencyWindow\.tell\(\);\n/\n/; s/(\n([ \t]*)String to = NowhereInCallService\.numberOf\(d\);)/\n$2EmergencyWindow.tell();$1/' \
  'PIN   P11 ' || fails=$((fails+1))
mut "R12 signal 4 reverted to the local-only static check (pin P12)" cc 's/try \{\s*String recent = EmergencyWindow\.exemptReason\(sLastEmergencyOutboundAt\);\s*if \(recent != null\) return recent;\s*\} catch \(Throwable ignore\) \{\}/long since = sLastEmergencyOutboundAt;\n        if (since > 0 && System.currentTimeMillis() - since < EMERGENCY_CALLBACK_WINDOW_MS) return "an emergency call left this phone";/' \
  'PIN   P12 ' || fails=$((fails+1))
mut "R13 exemptReason called with 0, not the static (pin P12)" cc 's/EmergencyWindow\.exemptReason\(sLastEmergencyOutboundAt\)/EmergencyWindow.exemptReason(0)/' \
  'PIN   P12 ' || fails=$((fails+1))
mut "R14 the old local check kept beside the rule (pin P13)" cc 's/(\n([ \t]*)\/\/ 1\. The platform flagged)/\n$2long since = sLastEmergencyOutboundAt; if (since > 0 && System.currentTimeMillis() - since < EMERGENCY_CALLBACK_WINDOW_MS) return "local";$1/' \
  'PIN   P13 ' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
