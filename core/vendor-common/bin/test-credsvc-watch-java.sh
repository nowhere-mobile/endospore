#!/usr/bin/env bash
# test-credsvc-watch-java.sh [--mutate] -- a session CredentialService left restarting with the gate's starts pending is
# confirmed stuck twice, stopped, and sent those starts again, run under javac (NWP-20261203-05).
#
# WHY THIS IS COMMITTED. At every sign-in ActivityManager kills the session user's chooser process ("permissions
# revoked"), and a CredentialService start in flight at that instant leaves its record restarting with app=null. While
# it is restarting, a new start only queues, so the web-import ingest, the claim apply, the GrapheneOS flags, the SMS
# role, the telephony ingest and RestartRearm's relayprefs ask never run (docs/backlog.md §B, "At every sign-in the
# session's chooser process is killed for "permissions revoked" ..."). CredSvcWatch.watch reads the service twice
# (Rule.FIRST_MS, then Rule.CONFIRM_MS), and only when both reads see it restarting with no process does it stop it and
# re-send each kind the gate recorded for that session. Stop a service with a pid, or on one read, and live work dies;
# drop a record or the watch call, and the queue stays dead, with green CI.
#
# CredSvcWatch.Rule (stuck, recover, nextSeconds, accepted, Sent, sameSession, Seen, resend, Trace, Flight) is pure; it is
# extracted with the six kind constants and compiled with the cases. Source pins (comment lines dropped) hold the Android
# side: the stop's place in watch, the session check, the trace in the finally, read's scan of every entry, a record
# beside each of the five ChooserActivity starts and the relayprefs ask, the two watch calls, and CredentialService's
# one-ingest-at-a-time guard. The 35 s of
# sleeps and the ActivityManager reads are not run here: the lynx run in the backlog row is what proves them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-credsvc-watch-java.sh            # the cases and the pins
#   bash test-credsvc-watch-java.sh --mutate   # ... plus broken copies that must each FAIL on the named check
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/CredSvcWatch.java"
CA="$SRC/ChooserActivity.java"
RR="$SRC/RestartRearm.java"
CS="$SRC/CredentialService.java"
CASES="$root/core/chooser/tests/credsvc-watch/CredSvcWatchCases.java"
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
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none -- refusing to report" >&2; exit 2; }

# code <file>: the file without its comment lines.
code() { awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/' "$1"; }
# mbody <file> <regex>: a member's body, from its signature to the closing brace at four spaces, comment lines dropped.
mbody() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print } on && /^    }$/ { exit }' "$1"
}
# block <file> <regex>: from the first line matching regex to its matching closing brace, comment lines dropped.
block() {
  code "$1" | RE="$2" perl -ne 'BEGIN { $re = $ENV{RE} } if (!$on && /$re/) { $on = 1 } if ($on) { print;
    $d += () = /\{/g; $d -= () = /\}/g; exit if $d <= 0 && /\}/ }'
}
# count <body> <regex>: matching lines.
count() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }
# first_line <body> <regex>: the first matching line number, empty when none.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }'; }
# nth_line <body> <regex> <n>: the n-th matching line number, empty when none.
nth_line() { printf '%s\n' "$1" | RE="$2" N="$3" awk '$0 ~ ENVIRON["RE"] { if (++k == ENVIRON["N"] + 0) { print NR; exit } }'; }
# follows <body> <regexA> <regexB>: 0 when the line right after the first line matching A matches B.
follows() {
  local l nx
  l=$(first_line "$1" "$2")
  [ -n "$l" ] || return 1
  nx=$(printf '%s\n' "$1" | sed -n "$((l + 1))p")
  printf '%s\n' "$nx" | RE="$3" awk '$0 ~ ENVIRON["RE"] { f = 1 } END { exit !f }'
}
# lt <a> <b> ...: 0 when every argument is a number and each is less than the next.
lt() {
  local x prev=""
  for x in "$@"; do
    case "$x" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "$prev" ] && [ "$prev" -ge "$x" ]; then return 1; fi
    prev=$x
  done
  return 0
}

# suite <CredSvcWatch.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d p out rc rule consts n
  [ -f "$src" ] || { echo "  FAIL  CredSvcWatch.java does not exist" >&2; return 1; }
  consts=$(grep -E '^    static final String [A-Z_]+ = "[A-Za-z]+";$' "$src")
  n=$(printf '%s\n' "$consts" | grep -c .)
  [ "$n" -eq 6 ] || { echo "  FAIL  CredSvcWatch.java has $n kind constant lines, not 6" >&2; return 1; }
  rule=$(awk '/^    static final class Rule \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$src")
  [ -n "$rule" ] || { echo "  FAIL  CredSvcWatch.java has no '    static final class Rule {' block" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  p="$d/src/com/nowhere/chooser"
  mkdir -p "$p"
  printf 'package com.nowhere.chooser;\nfinal class CredSvcWatch {\n%s\n%s\n}\n' "$consts" "$rule" > "$p/CredSvcWatch.java"
  cp "$CASES" "$p/CredSvcWatchCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$p"/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.CredSvcWatchCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pins <ChooserActivity.java> <RestartRearm.java> <CredSvcWatch.java> <CredentialService.java> -> 0 when the wiring
# holds, 1 otherwise.
pins() {
  local ca="$1" rr="$2" cw="$3" cs="$4" bad=0 w r1 r2 f c s1 s2 rec st rl cede gos apb n ret rrec rw g rd ss fin tl ib
  [ -f "$cw" ] || { echo "  FAIL  P1 CredSvcWatch.java does not exist" >&2; bad=1; cw=/dev/null; }

  # P1: watch stops the service once, only after both sleeps, the second read and Rule.recover; nowhere else.
  w=$(mbody "$cw" '^    static void watch\(')
  [ -n "$w" ] || { echo "  FAIL  P1 CredSvcWatch has no 'static void watch(' body" >&2; bad=1; }
  r1=$(nth_line "$w" '(^|[^A-Za-z_.])read\(app, uid\)' 1)
  r2=$(nth_line "$w" '(^|[^A-Za-z_.])read\(app, uid\)' 2)
  f=$(first_line "$w" 'Thread\.sleep\(Rule\.FIRST_MS\)')
  c=$(first_line "$w" 'Thread\.sleep\(Rule\.CONFIRM_MS\)')
  rec=$(first_line "$w" 'Rule\.recover\(')
  st=$(first_line "$w" 'stopService\(')
  [ "$(count "$w" '(^|[^A-Za-z_.])read\(app, uid\)')" -eq 2 ] \
    || { echo "  FAIL  P1 watch does not read the service exactly twice" >&2; bad=1; }
  [ "$(count "$w" 'stopService\(')" -eq 1 ] && [ "$(code "$cw" | grep -c 'stopService(')" -eq 1 ] \
    || { echo "  FAIL  P1 stopService( does not appear exactly once in CredSvcWatch, inside watch" >&2; bad=1; }
  lt "$f" "$r1" "$c" "$r2" "$rec" "$st" \
    || { echo "  FAIL  P1 watch's order is not sleep FIRST_MS, read, sleep CONFIRM_MS, read, Rule.recover, stopService" >&2; bad=1; }

  # P2: the stop is gated on Rule.stuck of both reads.
  s1=$(first_line "$w" '^ *final boolean stuck1 = last != null && Rule\.stuck\(last\.found, last\.pid, last\.restartingAt\);$')
  s2=$(first_line "$w" '^ *final boolean stuck2 = last != null && Rule\.stuck\(last\.found, last\.pid, last\.restartingAt\);$')
  [ "$(count "$w" 'Rule\.stuck\(')" -eq 2 ] && [ "$(count "$w" '^ *if \(Rule\.recover\(stuck1, stuck2\)\) \{$')" -eq 1 ] \
    && lt "$r1" "$s1" "$c" "$r2" "$s2" "$rec" \
    || { echo "  FAIL  P2 the stop is not gated by 'if (Rule.recover(stuck1, stuck2)) {' on Rule.stuck of each read" >&2; bad=1; }

  # P3: roamLogin records each of its three kicks on the line right after the kick's catch.
  rl=$(block "$ca" '^    private void roamLogin\(final String name, final String pw, final boolean isCreate, final String keyMode\) \{$')
  [ -n "$rl" ] || { echo "  FAIL  P3 ChooserActivity has no four-argument roamLogin" >&2; bad=1; }
  follows "$rl" '"telingest kick", t\); \}$' '^ *CredSvcWatch\.record\(appCtx, fuid, CredSvcWatch\.TELINGEST\);' \
    && [ "$(count "$rl" 'CredSvcWatch\.TELINGEST\)')" -eq 1 ] \
    || { echo "  FAIL  P3 roamLogin does not record TELINGEST right after the telingest kick" >&2; bad=1; }
  follows "$rl" '"ingest kick", t\); \}$' '^ *CredSvcWatch\.record\(appCtx, fuid, CredSvcWatch\.INGEST\);' \
    && [ "$(count "$rl" 'CredSvcWatch\.INGEST\)')" -eq 1 ] \
    || { echo "  FAIL  P3 roamLogin does not record INGEST right after the ingest kick" >&2; bad=1; }
  follows "$rl" '"claims-login kick", t\); \}$' '^ *CredSvcWatch\.record\(appCtx, fuid, CredSvcWatch\.CLAIMS_LOGIN\);' \
    && [ "$(count "$rl" 'CredSvcWatch\.CLAIMS_LOGIN\)')" -eq 1 ] \
    || { echo "  FAIL  P3 roamLogin does not record CLAIMS_LOGIN right after the claims-login kick" >&2; bad=1; }

  # P4: the sign-in watch follows the claims-login record, once in ChooserActivity.
  [ "$(code "$ca" | grep -cF 'CredSvcWatch.watch(')" -eq 1 ] \
    && follows "$rl" '^ *CredSvcWatch\.record\(appCtx, fuid, CredSvcWatch\.CLAIMS_LOGIN\);' \
                     '^ *CredSvcWatch\.watch\(appCtx, fuid, "signin"\);$' \
    || { echo "  FAIL  P4 'CredSvcWatch.watch(appCtx, fuid, \"signin\");' is not once, right after the claims-login record" >&2; bad=1; }

  # P5: the cede records SMSROLE right after its smsrole kick, before the repair is scheduled.
  cede=$(mbody "$ca" '^    private void cedeSmsToMessagingInRoamedUser\(')
  follows "$cede" '"#148 sms role kick", t\); \}$' \
          '^ *CredSvcWatch\.record\(getApplicationContext\(\), uid, CredSvcWatch\.SMSROLE\);' \
    && [ "$(count "$cede" 'CredSvcWatch\.SMSROLE\)')" -eq 1 ] \
    && lt "$(first_line "$cede" 'CredSvcWatch\.SMSROLE\)')" "$(first_line "$cede" '^ *repairSmsRoleLater\(uid, "cede"\);$')" \
    || { echo "  FAIL  P5 the cede does not record SMSROLE right after its smsrole kick, before repairSmsRoleLater" >&2; bad=1; }

  # P6: kickGosState records GOSSTATE first inside its successful start.
  gos=$(mbody "$ca" '^    private static void kickGosState\(')
  follows "$gos" '\.putExtra\("gosstate", true\), android\.os\.UserHandle\.of\(uid\)\) != null\) \{$' \
          '^ *CredSvcWatch\.record\(appCtx, uid, CredSvcWatch\.GOSSTATE\);' \
    && [ "$(count "$gos" 'CredSvcWatch\.GOSSTATE\)')" -eq 1 ] \
    || { echo "  FAIL  P6 kickGosState does not record GOSSTATE first inside its successful start" >&2; bad=1; }

  # P7: RestartRearm records RELAYPREFS and watches only inside the non-null ask, before its return.
  apb=$(mbody "$rr" '^    static void atProcessBirth\(')
  n=$(first_line "$apb" '\.putExtra\("relayprefs", true\), android\.os\.UserHandle\.of\(uid\)\) != null\) \{$')
  ret=""
  [ -n "$n" ] && ret=$(printf '%s\n' "$apb" | awk -v n="$n" 'NR > n && /^ *return;$/ { print NR; exit }')
  rrec=$(first_line "$apb" '^ *CredSvcWatch\.record\(app, uid, CredSvcWatch\.RELAYPREFS\);$')
  rw=$(first_line "$apb" '^ *CredSvcWatch\.watch\(app, uid, "rearm"\);$')
  [ "$(code "$rr" | grep -cF 'CredSvcWatch.record(')" -eq 1 ] && [ "$(code "$rr" | grep -cF 'CredSvcWatch.watch(')" -eq 1 ] \
    && lt "$n" "$rrec" "$rw" "$ret" \
    || { echo "  FAIL  P7 RestartRearm does not record RELAYPREFS and watch \"rearm\" once each, after a non-null ask and before its return" >&2; bad=1; }

  # P8: one login.log line per watch, written in the thread's finally, so a throw anywhere still writes it (RF-004);
  # the line itself is Rule.Trace.line, which C15 checks. G1: no log line prints a name.
  fin=$(first_line "$w" '^ *\} finally \{$')
  tl=$(first_line "$w" '^ *ChooserActivity\.idleTrace\(tr\.line\(uid\)\);$')
  [ "$(code "$cw" | grep -c 'idleTrace(')" -eq 1 ] && [ "$(count "$w" 'idleTrace\(')" -eq 1 ] \
    && [ "$(count "$w" '^ *\} catch \(Throwable t\) \{$')" -ge 1 ] && lt "$st" "$fin" "$tl" \
    && [ "$(count "$w" 'Rule\.resend\(')" -eq 1 ] && [ "$(count "$w" '\}, SENT\.resendList\(uid, s0\), tr\);$')" -eq 1 ] \
    || { echo "  FAIL  P8 watch does not trace 'ChooserActivity.idleTrace(tr.line(uid));' once, in its finally after the stop, with the recovery counted into tr" >&2; bad=1; }
  g=$(code "$cw" | grep -E 'Log\.[a-z]\(|idleTrace\(|^ *\+ ' | grep -iwE 'name|profile|alias|label|pkg' || true)
  [ -s "$cw" ] && [ -z "$g" ] || { echo "  FAIL  G1 a CredSvcWatch log line prints a name, or there is no CredSvcWatch: $g" >&2; bad=1; }

  # P9: the records name the constants, never a literal: five in ChooserActivity, one in RestartRearm.
  [ "$(code "$ca" | grep -cF '"claimsLogin"')" -eq 1 ] \
    && [ "$(code "$ca" | grep -cE 'CredSvcWatch\.record\((appCtx|getApplicationContext\(\)), f?uid, CredSvcWatch\.[A-Z_]+\);')" -eq 5 ] \
    && [ "$(code "$rr" | grep -cE 'CredSvcWatch\.record\(app, uid, CredSvcWatch\.[A-Z_]+\);')" -eq 1 ] \
    && [ "$(code "$ca" | grep -cE 'CredSvcWatch\.record\([^)]*"')" -eq 0 ] \
    && [ "$(code "$rr" | grep -cE 'CredSvcWatch\.record\([^)]*"')" -eq 0 ] \
    || { echo "  FAIL  P9 the six records are not all there, or one names its kind as a string literal" >&2; bad=1; }

  # P10: read adds every matching entry and returns once, after the loop (RF-001: AOSP lists a restarting record twice).
  rd=$(mbody "$cw" '^    private static Rule\.Seen read\(')
  [ "$(count "$rd" '^ *seen\.add\(info\.pid, info\.restarting\);$')" -eq 1 ] \
    && [ "$(count "$rd" '(^|[^A-Za-z_])return([^A-Za-z_]|$)')" -eq 1 ] && [ "$(count "$rd" '^ *return seen;$')" -eq 1 ] \
    && lt "$(first_line "$rd" 'seen\.add\(')" "$(first_line "$rd" '^ *return seen;$')" \
    || { echo "  FAIL  P10 read does not add every matching entry to one Rule.Seen and return it after the loop" >&2; bad=1; }

  # P11: CredentialService runs the ingest through runOnce, and nowhere else (RF-002).
  ib=$(block "$cs" '^ *if \(intent != null && intent\.getBooleanExtra\("ingest", false\)\) \{$')
  [ "$(count "$ib" '^ *try \{ CredSvcWatch\.runOnce\(CredSvcWatch\.INGEST, \(\) -> Ingest\.run\(this\)\); \} finally \{ finishUnit\(\); \}$')" -eq 1 ] \
    && [ "$(code "$cs" | grep -cE '(^|[^A-Za-z_])Ingest\.run\(')" -eq 1 ] \
    || { echo "  FAIL  P11 CredentialService's ingest start does not run Ingest.run through CredSvcWatch.runOnce(INGEST, ...)" >&2; bad=1; }

  # P12: the session check is Rule.sameSession, between the confirming sleep and the second read (RF-003).
  ss=$(first_line "$w" '^ *if \(!Rule\.sameSession\(s0, serial\(app, uid\)\)\) \{$')
  [ "$(count "$w" 'sameSession\(')" -eq 1 ] && [ "$(count "$w" 'serial\(app, uid\) *!=')" -eq 0 ] && lt "$c" "$ss" "$r2" "$st" \
    || { echo "  FAIL  P12 watch does not check 'if (!Rule.sameSession(s0, serial(app, uid))) {' after the confirming sleep and before the second read" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

rc=0
echo "== $SUT"
suite "$SUT" || { echo "FAILED (cases)"; rc=1; }
if pins "$CA" "$RR" "$SUT" "$CS"; then echo "pins: ok"; else echo "FAILED (pins)"; rc=1; fi
[ "$rc" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by the named check -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <case> <perl-expr>   (mutates CredSvcWatch.java; the named case must fail)
  local d m out rc
  d=$(mktemp -d -p "$W") || return 1; m="$d/CredSvcWatch.java"
  cp "$SUT" "$m"
  if ! perl -0pi -e "$3" "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(suite "$m" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL $2 "*) echo "  CONVICTED $1 -- $(printf '%s\n' "$out" | grep -m1 "^FAIL $2 ")" ;;
    *) echo "  WRONG-CASE $1 -- failed, but not on $2: $(printf '%s\n' "$out" | grep -m1 'FAIL')"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <pin> <CA|RR|CW|CS> <perl-expr>   (mutates one source; the named pin must fail)
  local d m rc why ca="$CA" rr="$RR" cw="$SUT" cs="$CS" orig
  d=$(mktemp -d -p "$W") || return 1
  case "$3" in
    CA) orig="$CA"; m="$d/ChooserActivity.java"; ca="$m" ;;
    RR) orig="$RR"; m="$d/RestartRearm.java"; rr="$m" ;;
    CW) orig="$SUT"; m="$d/CredSvcWatch.java"; cw="$m" ;;
    CS) orig="$CS"; m="$d/CredentialService.java"; cs="$m" ;;
  esac
  cp "$orig" "$m"
  if ! perl -0pi -e "$4" "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  why=$(pins "$ca" "$rr" "$cw" "$cs" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$why" in
    *"FAIL  $2 "*) echo "  CONVICTED $1 -- $(printf '%s\n' "$why" | grep -m1 "FAIL  $2 " | sed 's/^ *FAIL  //')" ;;
    *) echo "  WRONG-CASE $1 -- failed, but not on $2: $(printf '%s\n' "$why" | grep -m1 'FAIL')"; return 1 ;;
  esac
}
fails=0
mut "M1 stuck ignores the pid" C1 's/found && pid == 0 && restartingAt != 0/found && restartingAt != 0/' || fails=$((fails+1))
mut "M2 recover on the first read" C2 's/return firstStuck && secondStuck;/return firstStuck;/' || fails=$((fails+1))
mut "M3 a new serial keeps the old kinds" C5 's/\n *kinds\.remove\(uid\);//' || fails=$((fails+1))
mut "M4 resendList drops ingest" C3 's/GOSSTATE, INGEST, SMSROLE/GOSSTATE, SMSROLE/' || fails=$((fails+1))
mutpin "M5 the sign-in watch removed" P4 CA 's/\n *CredSvcWatch\.watch\(appCtx, fuid, "signin"\);//' || fails=$((fails+1))
mutpin "M6 the stop moved before the second read" P1 CW 'my $x; s/(\n *app\.createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\)\n *\.stopService\([^\n]*)// and $x = $1; s/(\n *try \{ last = read\(app, uid\); \} catch \(Throwable t\) \{\n *last = null;)/$x$1/' || fails=$((fails+1))
mutpin "M7 the RestartRearm watch removed" P7 RR 's/\n *CredSvcWatch\.watch\(app, uid, "rearm"\);//' || fails=$((fails+1))
mutpin "M8 the cede record removed" P5 CA 's/\n *CredSvcWatch\.record\(getApplicationContext\(\), uid, CredSvcWatch\.SMSROLE\);[^\n]*//' || fails=$((fails+1))
mut "M9 accepted takes any word" C6 's/if \(kind == null\) return false;/if (kind != null) return true;/' || fails=$((fails+1))
mut "M10 ORDER swaps gosstate and ingest" C3 's/GOSSTATE, INGEST, SMSROLE/INGEST, GOSSTATE, SMSROLE/' || fails=$((fails+1))
mut "M11 Seen keeps the last entry's restart time" C12 's/if \(entryRestarting != 0\) restartingAt = entryRestarting;/restartingAt = entryRestarting;/' || fails=$((fails+1))
mut "M12 Seen keeps the last entry's pid" C12 's/if \(entryPid != 0\) pid = entryPid;/pid = entryPid;/' || fails=$((fails+1))
mutpin "M13 read returns the first match" P10 CW 's/(\n *)seen\.add\(info\.pid, info\.restarting\);/$1return new Rule.Seen() {{ add(info.pid, info.restarting); }};/' || fails=$((fails+1))
mut "M14 a second ingest runs beside the first" C13 's/if \(!begin\(kind\)\) return false;/begin(kind);/' || fails=$((fails+1))
mutpin "M15 CredentialService runs Ingest.run bare" P11 CS 's/CredSvcWatch\.runOnce\(CredSvcWatch\.INGEST, \(\) -> Ingest\.run\(this\)\);/Ingest.run(this);/' || fails=$((fails+1))
mut "M16 two unreadable serials match" C14 's/return before >= 0 && before == now;/return before == now;/' || fails=$((fails+1))
mutpin "M17 the session check back to a bare compare" P12 CW 's/if \(!Rule\.sameSession\(s0, serial\(app, uid\)\)\) \{/if (serial(app, uid) != s0) {/' || fails=$((fails+1))
mut "M18 a throwing start loses the count" C15 's/\n *t\.tail = " err";\n *return e;/\n                t.resent = 0;\n                t.tail = " err";\n                return e;/' || fails=$((fails+1))
mut "M19 a throwing recovery is not marked" C15 's/\n *t\.tail = " err";\n *return e;/\n                return e;/' || fails=$((fails+1))
mutpin "M20 the trace moved out of the finally" P8 CW 'my $x; s/(\n *ChooserActivity\.idleTrace\(tr\.line\(uid\)\);)// and $x = $1; s/(\n *\} catch \(Throwable t\) \{\n *tr\.tail = " err";\n *android\.util\.Log\.w\(TAG, "credsvc-watch \(" \+ why \+ "\) user " \+ uid, t\);)/$x$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 20 of 20 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
