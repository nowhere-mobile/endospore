#!/usr/bin/env bash
# test-restart-rearm-java.sh [--mutate] -- after the user-0 chooser process restarts during a session, the idle cold
# lock re-arms from the session's own prefs, run under javac (NWP-20261126-10).
#
# WHY THIS IS COMMITTED. The idle cold lock lives in user-0 process memory: armIdleWatcher's runtime screen-off
# receiver and alarm, and the five lock statics applyRoamedPrefs sets at sign-in. The process is android:persistent and
# is restarted during a session (NowhereApp's header), and none of armIdleWatcher's three callers (login, resume,
# applyLivePrefs) runs after that. Now NowhereApp.onCreate's user-0 block calls RestartRearm.atProcessBirth, which waits
# for a live, unlocked session and starts CredentialService "relayprefs" in it; that branch runs
# RestartRearm.sendFromSession, which sends the sendLivePrefs broadcast to PrefsLiveReceiver, and applyLivePrefs
# re-arms. Drop a link and the session stays CE-unlocked until sign-out, with green CI.
#
# RestartRearm.Rule (shouldAsk, extras) is pure; it is extracted from RestartRearm.java and compiled with the REAL
# ProfileActivity.prefValueIn and PREFS_FILE (extracted from ProfileActivity.java), the real WipeOnSave and the cases.
# Source pins (comment lines dropped) hold the three Android links. The 120 s poll is not run here.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-restart-rearm-java.sh            # the cases and the pins
#   bash test-restart-rearm-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RestartRearm.java"
APP="$SRC/NowhereApp.java"
CRED="$SRC/CredentialService.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/restart-rearm/RestartRearmCases.java"
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

# suite <RestartRearm.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d p out rc rule pf pv
  [ -f "$src" ] || { echo "  FAIL  RestartRearm.java does not exist" >&2; return 1; }
  rule=$(awk '/^    static final class Rule \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$src")
  [ -n "$rule" ] || { echo "  FAIL  RestartRearm.java has no '    static final class Rule {' block" >&2; return 1; }
  pf=$(grep -E '^    static final String PREFS_FILE = ' "$PA")
  pv=$(awk '/^    static String prefValueIn\(String text, String key\) \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$PA")
  [ -n "$pf" ] && [ -n "$pv" ] \
    || { echo "  FAIL  harness: ProfileActivity.java has no PREFS_FILE line or no prefValueIn method" >&2; return 3; }
  d=$(mktemp -d -p "$W") || return 3
  p="$d/src/com/nowhere/chooser"
  mkdir -p "$p"
  printf 'package com.nowhere.chooser;\nfinal class RestartRearm {\n%s\n}\n' "$rule" > "$p/RestartRearm.java"
  printf 'package com.nowhere.chooser;\nfinal class ProfileActivity {\n%s\n%s\n}\n' "$pf" "$pv" > "$p/ProfileActivity.java"
  cp "$SRC/WipeOnSave.java" "$p/"
  cp "$CASES" "$p/RestartRearmCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$p"/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RestartRearmCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pins <NowhereApp.java> <CredentialService.java> <RestartRearm.java> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local app="$1" cred="$2" rr="$3" bad=0 u0 calls br sfs apb s g t l r b
  [ -f "$rr" ] || { echo "  FAIL  pins: RestartRearm.java does not exist" >&2; bad=1; rr=/dev/null; }

  # P1: NowhereApp.onCreate calls atProcessBirth exactly once, inside its user-0 block, and nothing else calls it.
  u0=$(block "$app" '^        if \(android\.os\.UserHandle\.myUserId\(\) == 0\) \{$')
  [ -n "$u0" ] || { echo "  FAIL  P1 NowhereApp.onCreate has no 'if (android.os.UserHandle.myUserId() == 0) {' block" >&2; bad=1; }
  [ "$(count "$u0" '^ *RestartRearm\.atProcessBirth\(this\);$')" -eq 1 ] \
    || { echo "  FAIL  P1 NowhereApp's user-0 block does not call RestartRearm.atProcessBirth(this) once" >&2; bad=1; }
  calls=0
  for s in "$SRC"/*.java; do
    case "$s" in "$SRC/RestartRearm.java"|"$SRC/NowhereApp.java") continue ;; esac
    calls=$((calls + $(code "$s" | grep -c 'atProcessBirth(')))
  done
  calls=$((calls + $(code "$app" | grep -c 'atProcessBirth(')))
  [ "$calls" -eq 1 ] || { echo "  FAIL  P1 the chooser source calls atProcessBirth $calls times, not once" >&2; bad=1; }

  # P2: CredentialService has one "relayprefs" branch that runs sendFromSession on a thread, with finishUnit in a finally.
  [ "$(code "$cred" | grep -cF 'getBooleanExtra("relayprefs", false)')" -eq 1 ] \
    || { echo "  FAIL  P2 CredentialService does not have exactly one \"relayprefs\" branch" >&2; bad=1; }
  br=$(block "$cred" '^        if \(intent != null && intent\.getBooleanExtra\("relayprefs", false\)\) \{$')
  t=$(first_line "$br" '^ *new Thread\(\(\) -> \{$')
  l=$(first_line "$br" '^ *try \{ RestartRearm\.sendFromSession\(this\); \} finally \{ finishUnit\(\); \}$')
  r=$(first_line "$br" '^ *return START_NOT_STICKY;$')
  [ -n "$t" ] && [ -n "$l" ] && [ -n "$r" ] && [ "$t" -lt "$l" ] && [ "$l" -lt "$r" ] \
    || { echo "  FAIL  P2 the \"relayprefs\" branch does not run 'try { RestartRearm.sendFromSession(this); } finally { finishUnit(); }' on a thread, then return" >&2; bad=1; }
  [ "$(code "$rr" | grep -cF 'putExtra("relayprefs", true)')" -eq 1 ] \
    || { echo "  FAIL  P2 RestartRearm does not put the \"relayprefs\" extra exactly once" >&2; bad=1; }

  # P3: sendFromSession sends the sendLivePrefs broadcast: explicit PrefsLiveReceiver, UserHandle.SYSTEM, six extras.
  sfs=$(mbody "$rr" '^    static void sendFromSession\(')
  [ -n "$sfs" ] || { echo "  FAIL  P3 RestartRearm has no 'static void sendFromSession(' body" >&2; bad=1; }
  [ "$(count "$sfs" 'sendBroadcastAsUser\(new android\.content\.Intent\(ctx, PrefsLiveReceiver\.class\)')" -eq 1 ] \
    && [ "$(count "$sfs" 'sendBroadcastAsUser\(')" -eq 1 ] \
    && [ "$(count "$sfs" 'android\.os\.UserHandle\.SYSTEM\);')" -eq 1 ] \
    || { echo "  FAIL  P3 sendFromSession does not send one explicit PrefsLiveReceiver broadcast to UserHandle.SYSTEM" >&2; bad=1; }
  for s in 'PrefsLiveReceiver\.EXTRA_IDLE, v\[0\]\)' 'PrefsLiveReceiver\.EXTRA_WIPE, v\[1\]\)' \
           'PrefsLiveReceiver\.EXTRA_WIPESAVED, v\[2\]\)' 'PrefsLiveReceiver\.EXTRA_HOLDLOCK, v\[3\]\)' \
           'PrefsLiveReceiver\.EXTRA_HOLDAUDIO, v\[4\]\)' 'PrefsLiveReceiver\.EXTRA_UID, uid\)'; do
    [ "$(count "$sfs" "$s")" -eq 1 ] || { echo "  FAIL  P3 sendFromSession does not carry '$s' once" >&2; bad=1; }
  done
  [ "$(count "$sfs" 'final int uid = android\.os\.UserHandle\.myUserId\(\);')" -eq 1 ] \
    && [ "$(count "$sfs" 'new java\.io\.File\(ctx\.getFilesDir\(\), ProfileActivity\.PREFS_FILE\)')" -eq 1 ] \
    && [ "$(count "$sfs" 'final String\[\] v = Rule\.extras\(text\);')" -eq 1 ] \
    || { echo "  FAIL  P3 sendFromSession does not read files/PREFS_FILE through Rule.extras as this user" >&2; bad=1; }

  # P4: atProcessBirth returns for a non-zero user before it starts its one thread.
  apb=$(mbody "$rr" '^    static void atProcessBirth\(')
  [ -n "$apb" ] || { echo "  FAIL  P4 RestartRearm has no 'static void atProcessBirth(' body" >&2; bad=1; }
  case "$(printf '%s\n' "$apb" | sed -n 2p)" in
    '        if (android.os.UserHandle.myUserId() != 0) return;') ;;
    *) echo "  FAIL  P4 atProcessBirth's first statement is not the user-0 guard" >&2; bad=1 ;;
  esac
  t=$(first_line "$apb" 'new Thread\(')
  [ "$(count "$apb" 'new Thread\(')" -eq 1 ] && [ -n "$t" ] && [ "$t" -gt 2 ] \
    && [ "$(count "$apb" '\}, "nowhere-restart-rearm"\)\.start\(\);')" -eq 1 ] \
    || { echo "  FAIL  P4 atProcessBirth does not start one \"nowhere-restart-rearm\" thread after its guard" >&2; bad=1; }
  [ "$(count "$apb" 'Rule\.shouldAsk\(ChooserActivity\.isSessionLive\(\), cur, unlocked\)')" -eq 1 ] \
    && [ "$(count "$apb" '"restart rearm: no live session at process birth \(NWP-20261126-10\)"')" -eq 1 ] \
    || { echo "  FAIL  P4 atProcessBirth does not decide through Rule.shouldAsk or does not log the no-session line" >&2; bad=1; }
  [ "$(count "$apb" 'try_ < 8; try_\+\+')" -eq 1 ] && [ "$(count "$apb" ', android\.os\.UserHandle\.of\(uid\)\) != null\) \{')" -eq 1 ] \
    || { echo "  FAIL  P4 atProcessBirth's ask is not 8 startServiceAsUser tries with a null result a retry" >&2; bad=1; }

  # P5: an absent file reads as every value absent; an unreadable one returns before any send.
  l=$(first_line "$sfs" '\} catch \(java\.nio\.file\.NoSuchFileException ')
  case "$(printf '%s\n' "$sfs" | sed -n "$((${l:-0} + 1))p")" in
    *'text = "";') ;;
    *) echo "  FAIL  P5 sendFromSession does not read an absent file as \"\"" >&2; bad=1 ;;
  esac
  l=$(first_line "$sfs" 'nothing sent \(NWP-20261126-10\)"\);$')
  b=$(first_line "$sfs" 'sendBroadcastAsUser\(')
  if [ -z "$l" ]; then echo "  FAIL  P5 sendFromSession does not log the unreadable line" >&2; bad=1
  else
    case "$(printf '%s\n' "$sfs" | sed -n "$((l + 1))p")" in
      '            return;') [ -n "$b" ] && [ "$((l + 1))" -lt "$b" ] \
                               || { echo "  FAIL  P5 the unreadable branch's return is not before the send" >&2; bad=1; } ;;
      *) echo "  FAIL  P5 the unreadable branch does not return: it would send defaults" >&2; bad=1 ;;
    esac
  fi

  # G1: no log line prints a profile name.
  g=$(code "$rr" | grep -E 'Log\.[a-z]\(|^ *\+ ' | grep -iwE 'name|profile|alias|label' || true)
  [ -z "$g" ] || { echo "  FAIL  G1 a RestartRearm log line prints a profile name: $g" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

rc=0
echo "== $SUT"
suite "$SUT" || { echo "FAILED (cases)"; rc=1; }
if pins "$APP" "$CRED" "$SUT"; then echo "pins: ok"; else echo "FAILED (pins)"; rc=1; fi
[ "$rc" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates RestartRearm.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RestartRearm.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  CONVICTED $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <APP|CRED|RR> <perl-expr>   (mutates one source; the pins must fail)
  local d c rc why app="$APP" cred="$CRED" rr="$SUT" orig
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    APP) orig="$APP"; c="$d/NowhereApp.java"; app="$c" ;;
    CRED) orig="$CRED"; c="$d/CredentialService.java"; cred="$c" ;;
    RR) orig="$SUT"; c="$d/RestartRearm.java"; rr="$c" ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  why=$(pins "$app" "$cred" "$rr" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  CONVICTED $1 --$(printf '%s\n' "$why" | grep -m1 'FAIL' | sed 's/^ *FAIL//')"
}
fails=0
mut "M1 shouldAsk ignores currentUnlocked" 's/ && currentUnlocked;/;/' || fails=$((fails+1))
mut "M2 shouldAsk accepts user 0" 's/currentUser >= 10/currentUser >= 0/' || fails=$((fails+1))
mut "M3 extras swaps holdlock and holdaudio" 's/"holdlock", "holdaudio"/"holdaudio", "holdlock"/' || fails=$((fails+1))
mutpin "M4 the NowhereApp call removed" APP 's/\n *RestartRearm\.atProcessBirth\(this\);//' || fails=$((fails+1))
mutpin "M5 the relayprefs branch drops finishUnit" CRED 's/try \{ RestartRearm\.sendFromSession\(this\); \} finally \{ finishUnit\(\); \}/try { RestartRearm.sendFromSession(this); } finally { }/' || fails=$((fails+1))
mutpin "M6 the unreadable branch sends" RR 's/(nothing sent \(NWP-20261126-10\)"\);\n *)return;/${1}text = "";/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 6 of 6 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
