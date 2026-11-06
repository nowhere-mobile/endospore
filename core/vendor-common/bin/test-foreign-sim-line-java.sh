#!/usr/bin/env bash
# test-foreign-sim-line-java.sh [--mutate] -- the foreign-SIM line on Preferences, run under javac (NWP-20261122-13).
#
# WHY THIS IS COMMITTED. A roamed session that owns no SIM sees Messages refuse to send, and a session that owns one
# never sees the phone's other SIM, with no reason and no route. h52 #3 (docs/product-decisions.md, 2026-11-01) decided
# one line on the session's Preferences, under Mobile data, while the phone has an active SIM this profile does not
# own, naming no SIM and with the same words whether that SIM is unbound or assigned elsewhere. The words, the wire
# form and the counting rule live in ForeignSimLine.java (pure java.util), which core/chooser/tests/foreign-sim-line/
# run.sh compiles and runs against ForeignSimLineCases. The PINS below check what the cases cannot see: ForeignSimLine
# has no identifier that could carry a SIM's identity or holder; the sign-in tail, lockOwnerSimsToBound's owns-nothing
# return, applyOwnerSimLock and reapplyLiveTelVerdict all reach ChooserActivity.sendSimCase; the send is an explicit
# intent to SimCaseReceiver with FLAG_INCLUDE_STOPPED_PACKAGES; the receiver is not exported and stores the decoded
# case; and showPreferences draws the line under the rows card, past the throwaway branch.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (a suite that quietly passes because its tool is missing reads
# exactly like one that ran). javac comes from PATH, else from the build host's JDK below; the version is printed first.
#
#   bash test-foreign-sim-line-java.sh            # the cases and the pins
#   bash test-foreign-sim-line-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
CH="$root/core/chooser"
ACT="$CH/src/com/nowhere/chooser/ChooserActivity.java"
FSL="$CH/src/com/nowhere/chooser/ForeignSimLine.java"
RCV="$CH/src/com/nowhere/chooser/SimCaseReceiver.java"
PROF="$CH/src/com/nowhere/chooser/ProfileActivity.java"
MAN="$CH/AndroidManifest.xml"
RUN="$CH/tests/foreign-sim-line/run.sh"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its pins and mutants" >&2; exit 2; }
for f in "$ACT" "$FSL" "$RCV" "$PROF" "$MAN" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# count <haystack> <needle> -> how many times needle occurs, literally
count() {
  local h="$1" n="$2" k=0
  [ -n "$n" ] || { echo 0; return; }
  while [[ "$h" == *"$n"* ]]; do h=${h#*"$n"}; k=$((k+1)); done
  echo "$k"
}

# pins <ChooserActivity.java> <ForeignSimLine.java> <SimCaseReceiver.java> <ProfileActivity.java> <AndroidManifest.xml>
# -> 0 all hold, 1 one failed
pins() {
  local act="$1" fsl="$2" rcv="$3" prof="$4" man="$5" b code arm rest next pre
  # P1: no identifier in ForeignSimLine names a SIM's identity or holder. Comments and string literals are stripped
  # first, so the drafted words ("the phone's owner") may say what they say.
  code=$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g; s{"(?:\\.|[^"\\\n])*"}{""}g' "$fsl")
  if printf '%s\n' "$code" | grep -Eiq 'iccid|\bicc|msisdn|imsi|number|label|carrier|owner|bound|binding|profile|subscription|holder|assign'; then
    echo "  PIN P1 ForeignSimLine has an identifier naming an ICCID, number, label or binding owner" >&2; return 1; fi
  [ "$(count "$code" 'static String line(Case c) {')" -eq 1 ] && [ "$(count "$code" 'static String line(')" -eq 1 ] || {
    echo "  PIN P1 ForeignSimLine.line is not exactly line(Case c)" >&2; return 1; }
  [ "$(count "$code" 'Case(boolean ownsAny, int notOwned) {')" -eq 1 ] && [ $(( $(count "$code" 'Case(') - $(count "$code" 'new Case(') )) -eq 1 ] || {
    echo "  PIN P1 ForeignSimLine.Case is not exactly Case(boolean ownsAny, int notOwned)" >&2; return 1; }

  # P2: reapplyLiveTelVerdict sends on the owns-nothing arm, and reaches applyOwnerSimLock on the other
  b=$(body "$act" 'private void reapplyLiveTelVerdict(')
  arm=${b#*'if (owned.isEmpty()) {'}; rest=${arm#*'} else {'}; arm=${arm%%'} else {'*}
  [[ "$arm" != "$b" && "$arm" == *'blockOutboundTelephony(uid);'*'sendSimCase(uid, false, -1);'* ]] || {
    echo "  PIN P2 reapplyLiveTelVerdict's owns-nothing arm does not block and then sendSimCase(uid, false, -1)" >&2; return 1; }
  [[ "$rest" == *'applyOwnerSimLock(uid, owned);'* ]] || {
    echo "  PIN P2 reapplyLiveTelVerdict's owner arm does not call applyOwnerSimLock(uid, owned)" >&2; return 1; }
  pre=${b%%'if (owned.isEmpty()) {'*}
  [[ "$pre" != *'sendSimCase('* ]] || { echo "  PIN P2 reapplyLiveTelVerdict sends before its verdict" >&2; return 1; }

  # P3: the sign-in tail -- one if/else pair, the owns-nothing branch sends after it blocks
  b=$(grep -n -A1 -F 'if (shouldBlockOutbound(name, pw))' "$act" || true)
  [ "$(printf '%s\n' "$b" | grep -c -F 'if (shouldBlockOutbound(name, pw))')" -eq 1 ] || {
    echo "  PIN P3 the sign-in tail's shouldBlockOutbound test is not there exactly once" >&2; return 1; }
  [[ "$b" == *'if (shouldBlockOutbound(name, pw)) { blockOutboundTelephony(uid); sendSimCase(uid, false, -1); }'* ]] || {
    echo "  PIN P3 the sign-in tail's block branch does not sendSimCase(uid, false, -1) after blocking" >&2; return 1; }
  next=$(printf '%s\n' "$b" | sed -n 2p)
  [[ "$next" =~ ^[0-9]+-\ *else\ lockOwnerSimsToBound\(uid,\ name,\ pw\)\; ]] || {
    echo "  PIN P3 the sign-in tail's else is not lockOwnerSimsToBound(uid, name, pw)" >&2; return 1; }

  # P4: lockOwnerSimsToBound's owns-nothing return sends first; its unknown (null) return sends nothing
  b=$(body "$act" 'private void lockOwnerSimsToBound(')
  [[ "$b" == *'if (owned.isEmpty()) { sendSimCase(uid, false, -1); return; }'* ]] || {
    echo "  PIN P4 lockOwnerSimsToBound's owns-nothing return does not sendSimCase(uid, false, -1)" >&2; return 1; }
  [ "$(count "$b" 'sendSimCase(')" -eq 1 ] || { echo "  PIN P4 lockOwnerSimsToBound sends other than on owns-nothing" >&2; return 1; }

  # P5: applyOwnerSimLock counts by target AFTER the SKIP continue, and sends once, after its walk
  b=$(body "$act" 'private void applyOwnerSimLock(')
  printf '%s\n' "$b" | perl -0ne 'exit(/if \(tgt == OwnedSims\.SKIP\) continue;\n\s*if \(ForeignSimLine\.notOwned\(tgt\)\) nForeign\+\+;/ ? 0 : 1)' || {
    echo "  PIN P5 applyOwnerSimLock does not count ForeignSimLine.notOwned(tgt) right after the SKIP continue" >&2; return 1; }
  [ "$(count "$b" 'nForeign++')" -eq 1 ] || { echo "  PIN P5 applyOwnerSimLock counts nForeign other than once" >&2; return 1; }
  [ "$(count "$b" 'sendSimCase(')" -eq 1 ] || { echo "  PIN P5 applyOwnerSimLock does not send exactly once" >&2; return 1; }
  pre=${b#*' verified");'}
  [[ "$pre" != "$b" && "$pre" == *'sendSimCase(uid, true, nForeign);'* ]] || {
    echo "  PIN P5 applyOwnerSimLock does not sendSimCase(uid, true, nForeign) after its walk" >&2; return 1; }

  # P6: the send -- counted by the same rule, explicit to SimCaseReceiver, stopped packages included, to user uid
  b=$(body "$act" 'private void sendSimCase(')
  [ -n "$b" ] || { echo "  PIN P6 ChooserActivity has no sendSimCase" >&2; return 1; }
  [[ "$b" == *'if (ForeignSimLine.notOwned(OwnedSims.target(java.util.Collections.<String>emptySet(), iccid))) n++;'* ]] || {
    echo "  PIN P6 sendSimCase does not count each SIM by ForeignSimLine.notOwned(OwnedSims.target(empty, iccid))" >&2; return 1; }
  [ "$(count "$b" 'n++')" -eq 1 ] || { echo "  PIN P6 sendSimCase counts other than by the rule" >&2; return 1; }
  [[ "$b" == *'new Intent(app, SimCaseReceiver.class)'* ]] || { echo "  PIN P6 sendSimCase does not target SimCaseReceiver" >&2; return 1; }
  [[ "$b" == *'.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)'* ]] || {
    echo "  PIN P6 sendSimCase does not add FLAG_INCLUDE_STOPPED_PACKAGES" >&2; return 1; }
  [[ "$b" == *'.putExtra(SimCaseReceiver.EXTRA_CASE, ForeignSimLine.encode(new ForeignSimLine.Case(ownsAny, n)))'* ]] || {
    echo "  PIN P6 sendSimCase does not put the encoded case in SimCaseReceiver.EXTRA_CASE" >&2; return 1; }
  [[ "$b" == *'sendBroadcastAsUser('*'android.os.UserHandle.of(uid));'* ]] || {
    echo "  PIN P6 sendSimCase does not sendBroadcastAsUser to UserHandle.of(uid)" >&2; return 1; }
  if printf '%s\n' "$b" | grep 'Log\.' | grep -Eq 'iccid|name|pw'; then
    echo "  PIN P6 a log line in sendSimCase carries an ICCID or a profile credential" >&2; return 1; fi

  # P7: the receiver is declared once, not exported, with no intent-filter
  [ "$(grep -c -F 'android:name=".SimCaseReceiver"' "$man")" -eq 1 ] || {
    echo "  PIN P7 the manifest does not declare SimCaseReceiver exactly once" >&2; return 1; }
  grep -q -F '<receiver android:name=".SimCaseReceiver" android:exported="false"/>' "$man" || {
    echo "  PIN P7 SimCaseReceiver is not <receiver ... android:exported=\"false\"/>" >&2; return 1; }

  # P8: the receiver stores the decoded case (a malformed extra -> null -> no line)
  grep -q -F 'stored = ForeignSimLine.decode(intent.getStringExtra(EXTRA_CASE));' "$rcv" || {
    echo "  PIN P8 SimCaseReceiver does not store ForeignSimLine.decode of EXTRA_CASE" >&2; return 1; }

  # P9: showPreferences draws the line after the throwaway return and the rows card, before the Google card
  b=$(body "$prof" 'private void showPreferences(')
  pre=${b#*'finishMenuScreen(ll);'*'return;'}
  [[ "$pre" != "$b" ]] || { echo "  PIN P9 showPreferences has no throwaway return" >&2; return 1; }
  [ "$(count "$b" 'ForeignSimLine.line(SimCaseReceiver.stored())')" -eq 1 ] || {
    echo "  PIN P9 showPreferences does not read ForeignSimLine.line(SimCaseReceiver.stored()) exactly once" >&2; return 1; }
  printf '%s\n' "$pre" | perl -0ne 'exit(/sectionCard\(ll, null, rows\.toArray[^\n]*\n\s*\}\n(?:\s*\/\/[^\n]*\n)*\s*String simLine = ForeignSimLine\.line\(SimCaseReceiver\.stored\(\)\);\n\s*if \(simLine != null\) \{.*?ll\.addView\(note, nlp\);\n\s*\}\n\s*addGoogleSignOutCard\(ll\);/s ? 0 : 1)' || {
    echo "  PIN P9 showPreferences does not draw the line directly under the rows card, before addGoogleSignOutCard" >&2; return 1; }
  return 0
}

# suite <act> <fsl> <rcv> <prof> <man> -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 it did not
# compile. Only 1 may convict a mutant.
suite() {
  pins "$1" "$2" "$3" "$4" "$5" || return 1
  bash "$RUN" "$2" "$W"
}

echo "== $FSL and its wiring"
suite "$ACT" "$FSL" "$RCV" "$PROF" "$MAN" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not apply or compile proves nothing)"
# mut <label> <which: fsl|act|rcv|prof|man> <perl-expr>
mut() {
  local d m rc src a="$ACT" f="$FSL" r="$RCV" p="$PROF" n="$MAN"
  d=$(mktemp -d -p "$W")
  case "$2" in
    fsl)  src="$FSL";  m="$d/ForeignSimLine.java";   f="$m" ;;
    act)  src="$ACT";  m="$d/ChooserActivity.java";  a="$m" ;;
    rcv)  src="$RCV";  m="$d/SimCaseReceiver.java";  r="$m" ;;
    prof) src="$PROF"; m="$d/ProfileActivity.java";  p="$m" ;;
    man)  src="$MAN";  m="$d/AndroidManifest.xml";   n="$m" ;;
    *) echo "  ERROR     $1 -- unknown target $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$a" "$f" "$r" "$p" "$n" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not apply or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "L1 two SIMs get the singular words"            fsl  's/boolean many = c\.notOwned >= 2;/boolean many = c.notOwned >= 3;/' || fails=$((fails+1))
mut "L2 owns-none never takes the plural"           fsl  's/return many \? NONE_MANY : NONE_ONE;/return NONE_ONE;/' || fails=$((fails+1))
mut "L3 the line is shown when notOwned is 0"       fsl  's/if \(c == null \|\| c\.notOwned == 0\) return null;/if (c == null) return null;/' || fails=$((fails+1))
mut "L4 a SKIP SIM is counted"                      fsl  's/return target == OwnedSims\.HIDE;/return target != OwnedSims.VISIBLE;/' || fails=$((fails+1))
mut "L5 decode takes any digit for the flag"        fsl  's/compile\("\[01\] /compile("[0-9] /' || fails=$((fails+1))
mut "L6 decode takes a trailing space"              fsl  's/\{0,3\}\)"\)/{0,3}) ?")/' || fails=$((fails+1))
mut "L7 line takes the SIM's ICCID"                 fsl  's/(    static String line\(Case c\) \{)/    static String line(Case c, String iccid) { return line(c); }\n\n$1/' || fails=$((fails+1))
mut "A1 reapplyLiveTelVerdict without the send"     act  's/(                blockOutboundTelephony\(uid\);\n)                sendSimCase\(uid, false, -1\);\n/$1/' || fails=$((fails+1))
mut "A2 the owns-nothing sign-in branch, no send"   act  's/if \(shouldBlockOutbound\(name, pw\)\) \{ blockOutboundTelephony\(uid\); sendSimCase\(uid, false, -1\); \}/if (shouldBlockOutbound(name, pw)) { blockOutboundTelephony(uid); }/' || fails=$((fails+1))
mut "A3 lockOwnerSimsToBound owns-nothing, no send" act  's/if \(owned\.isEmpty\(\)\) \{ sendSimCase\(uid, false, -1\); return; \}/if (owned.isEmpty()) return;/' || fails=$((fails+1))
mut "A4 applyOwnerSimLock without the send"         act  's/\n            sendSimCase\(uid, true, nForeign\);//' || fails=$((fails+1))
mut "A5 applyOwnerSimLock counts before the SKIP"   act  's/(                if \(tgt == OwnedSims\.SKIP\) continue;\n)(                if \(ForeignSimLine\.notOwned\(tgt\)\) nForeign\+\+;[^\n]*\n)/$2$1/' || fails=$((fails+1))
mut "A6 sendSimCase counts every SIM"               act  's/if \(ForeignSimLine\.notOwned\(OwnedSims\.target\(java\.util\.Collections\.<String>emptySet\(\), iccid\)\)\) n\+\+;/n++;/' || fails=$((fails+1))
mut "A7 FLAG_INCLUDE_STOPPED_PACKAGES dropped"      act  's/(new Intent\(app, SimCaseReceiver\.class\))\n\s*\.addFlags\(Intent\.FLAG_INCLUDE_STOPPED_PACKAGES\)/$1/' || fails=$((fails+1))
mut "A8 the send targets another receiver"          act  's/new Intent\(app, SimCaseReceiver\.class\)/new Intent(app, PrefsLiveReceiver.class)/' || fails=$((fails+1))
mut "M1 the receiver is exported"                   man  's/(<receiver android:name="\.SimCaseReceiver" android:exported=)"false"/$1"true"/' || fails=$((fails+1))
mut "R1 the receiver keeps the raw extra unread"    rcv  's/stored = ForeignSimLine\.decode\(intent\.getStringExtra\(EXTRA_CASE\)\);/stored = new ForeignSimLine.Case(false, 1);/' || fails=$((fails+1))
mut "P1 showPreferences draws no line"              prof 's/        String simLine = ForeignSimLine\.line\(SimCaseReceiver\.stored\(\)\);\n/        String simLine = null;\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
