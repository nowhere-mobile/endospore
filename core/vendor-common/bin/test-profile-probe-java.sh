#!/usr/bin/env bash
# test-profile-probe-java.sh [--mutate] -- the Profile screen draws its menu before its session probe, each probe read
# waits 5 s at most, and the probe stops at the first request with no answer, run under javac (NWP-20261113-06).
#
# WHY THIS IS COMMITTED. The Profile screen sent GET-SESSION-TYPE, GET-OFFLINE, GET-SESSION-NAME and OTA-AFTER-LOGOFF
# with a 90 s read each, then OTA-STATUS, and only then drew anything. With the login daemon stopped (kill -STOP, lynx
# 2026102201, S2 run) it stayed solid black for 4 min 48 s, so Lock, Log off and Report an issue -- the one report a
# user build can send -- were all out of reach (docs/backlog.md, "The Profile screen stays black for up to about six
# minutes while the login daemon is wedged ..."). ProfileProbe.java holds the order and the stop rule and is pure Java,
# so this compiles it (with ProfileReplies.java, which it asks) and drives it with fake daemons:
#   P1 drawChecking runs before the first request (a Sender blocked on a latch: the menu is drawn while it blocks)
#   P2 the request order, OTA-AFTER-LOGOFF before OTA-STATUS, drawChecking before apply, apply once
#   P3 the first silence ends the probe: nothing more is sent, and no answer is UNKNOWN
#   P4 a full answer set gives STORED / LOCAL / offline as ProfileReplies decides, the name and the OTA lines
#   P5 PINS in ProfileActivity: probeSession hands the reads to ProfileProbe with a 5000 ms cap and no sendDaemon, the
#      menu is redrawn with the answer only while it is still the content view, and CHECKING draws the UNKNOWN layout
#      with its own line and no tap action
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-profile-probe-java.sh            # the cases and the pins
#   bash test-profile-probe-java.sh --mutate   # ... plus broken copies that must each FAIL
# PROFILE_ACTIVITY=<file> / PROFILE_PROBE=<file> point the suite at other copies (to show it fails on an older tree).
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
RP="$DIR/ProfileReplies.java"
PA="${PROFILE_ACTIVITY:-$DIR/ProfileActivity.java}"
PP="${PROFILE_PROBE:-$DIR/ProfileProbe.java}"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$PA" ] || { echo "FAIL: missing $PA" >&2; exit 2; }
[ -f "$RP" ] || { echo "FAIL: missing $RP" >&2; exit 2; }

mkdir -p "$W/cases"
cat > "$W/cases/ProfileProbeCases.java" <<'JAVA'
package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public class ProfileProbeCases {
    static int n = 0, bad = 0;

    static void eq(String label, Object got, Object want) {
        n++;
        if (!String.valueOf(got).equals(String.valueOf(want))) {
            bad++;
            System.out.println("--- FAIL " + label + ": got [" + got + "] want [" + want + "]");
        }
    }

    static final String TYPE = "GET-SESSION-TYPE\n", OFF = "GET-OFFLINE\n", NAME = "GET-SESSION-NAME\n",
            WITHDRAW = "OTA-AFTER-LOGOFF\n0\n", OTA = "OTA-STATUS\n";
    static final List<String> ALL = Arrays.asList(TYPE, OFF, NAME, WITHDRAW, OTA);

    /** A fake daemon: answers[i] is the reply to ALL[i] (null = a null reply); records what was asked. */
    static final class Fake implements ProfileProbe.Sender, ProfileProbe.Ui {
        final String[] answers;
        final List<String> asked = new ArrayList<>();
        final List<String> events = new ArrayList<>();
        ProfileProbe.Result result;

        Fake(String... answers) { this.answers = answers; }

        @Override public String ask(String request) {
            asked.add(request);
            events.add("ask");
            int i = ALL.indexOf(request);
            return i < 0 || i >= answers.length ? "" : answers[i];
        }

        @Override public void drawChecking() { events.add("draw"); }

        @Override public void apply(ProfileProbe.Result r) { events.add("apply"); result = r; }

        int count(String e) { int c = 0; for (String x : events) if (x.equals(e)) c++; return c; }
    }

    static Fake run(String... answers) {
        Fake f = new Fake(answers);
        ProfileProbe.run(f, f);
        return f;
    }

    static String show(List<String> l) {
        return String.valueOf(l).replace("\n", "\\n");
    }

    public static void main(String[] a) throws Exception {
        // P1: the menu is drawn before the first read, and is on screen while that read blocks.
        final AtomicBoolean drawn = new AtomicBoolean(false);
        final AtomicBoolean drawnAtFirstAsk = new AtomicBoolean(false);
        final CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        ProfileProbe.Sender blocked = req -> {
            if (entered.getCount() > 0) {
                drawnAtFirstAsk.set(drawn.get());
                entered.countDown();
                try { release.await(5, TimeUnit.SECONDS); } catch (InterruptedException e) { /* reply "" */ }
            }
            return "";
        };
        ProfileProbe.Ui ui = new ProfileProbe.Ui() {
            @Override public void drawChecking() { drawn.set(true); }
            @Override public void apply(ProfileProbe.Result r) { }
        };
        Thread t = new Thread(() -> ProfileProbe.run(blocked, ui));
        t.start();
        eq("P1 the first read was reached", entered.await(5, TimeUnit.SECONDS), true);
        eq("P1 the menu was drawn before the first read", drawnAtFirstAsk.get(), true);
        eq("P1 the menu is drawn while the first read blocks", drawn.get(), true);
        release.countDown();
        t.join(5000);
        eq("P1 the probe ended after the read gave up", t.isAlive(), false);

        // P2: the order, the withdraw before OTA-STATUS, draw before apply, apply once.
        Fake f = run("STORED", "0", "alice-test", "OK", "AVAIL 1.2.3");
        eq("P2 request order", show(f.asked), show(ALL));
        eq("P2 OTA-AFTER-LOGOFF before OTA-STATUS",
                f.asked.indexOf(WITHDRAW) >= 0 && f.asked.indexOf(WITHDRAW) < f.asked.indexOf(OTA), true);
        eq("P2 drawChecking once", f.count("draw"), 1);
        eq("P2 apply once", f.count("apply"), 1);
        eq("P2 drawChecking first", f.events.get(0), "draw");
        eq("P2 apply last", f.events.get(f.events.size() - 1), "apply");

        // P3: the first silence ends the probe.
        f = run("");
        eq("P3 silent GET-SESSION-TYPE: requests", show(f.asked), show(ALL.subList(0, 1)));
        eq("P3 silent GET-SESSION-TYPE: type", f.result == null ? null : f.result.sessionType, "UNKNOWN");
        eq("P3 silent GET-SESSION-TYPE: offline", f.result == null ? null : f.result.offline, false);
        eq("P3 silent GET-SESSION-TYPE: name", f.result == null ? "?" : f.result.name, null);
        eq("P3 silent GET-SESSION-TYPE: ota", f.result == null ? null : f.result.otaLines.size(), 0);
        eq("P3 silent GET-SESSION-TYPE: apply once", f.count("apply"), 1);
        f = run((String) null);
        eq("P3 null GET-SESSION-TYPE is silence: requests", show(f.asked), show(ALL.subList(0, 1)));
        eq("P3 null GET-SESSION-TYPE: type", f.result == null ? null : f.result.sessionType, "UNKNOWN");
        f = run("LOCAL", "");
        eq("P3 silent GET-OFFLINE: requests", show(f.asked), show(ALL.subList(0, 2)));
        eq("P3 silent GET-OFFLINE after LOCAL: type", f.result == null ? null : f.result.sessionType, "UNKNOWN");
        eq("P3 silent GET-OFFLINE: apply once", f.count("apply"), 1);
        f = run("STORED", "0", "");
        eq("P3 silent GET-SESSION-NAME: requests", show(f.asked), show(ALL.subList(0, 3)));
        eq("P3 silent GET-SESSION-NAME: type", f.result == null ? null : f.result.sessionType, "STORED");
        eq("P3 silent GET-SESSION-NAME: name", f.result == null ? "?" : f.result.name, null);
        f = run("STORED", "0", "alice-test", "");
        eq("P3 silent OTA-AFTER-LOGOFF: requests", show(f.asked), show(ALL.subList(0, 4)));
        eq("P3 silent OTA-AFTER-LOGOFF: no OTA-STATUS", f.asked.contains(OTA), false);
        eq("P3 silent OTA-AFTER-LOGOFF: ota", f.result == null ? null : f.result.otaLines.size(), 0);
        eq("P3 silent OTA-AFTER-LOGOFF: name", f.result == null ? null : f.result.name, "alice-test");
        f = run("STORED", "0", "alice-test", "OK", "");
        eq("P3 silent OTA-STATUS: ota", f.result == null ? null : f.result.otaLines.size(), 0);
        eq("P3 silent OTA-STATUS: apply once", f.count("apply"), 1);

        // P4: a full answer set, decided as ProfileReplies decides it.
        String[][] sets = {{"STORED", "0"}, {"LOCAL", "0"}, {"LOCAL", "1"}, {"  STORED \n", "0\n"}, {"NONE", "0"}};
        for (String[] s : sets) {
            f = run(s[0], s[1], "alice-test", "OK", "NONE");
            String label = "P4 [" + s[0].trim() + "," + s[1].trim() + "]";
            eq(label + " type", f.result == null ? null : f.result.sessionType, ProfileReplies.sessionType(s[0], s[1]));
            eq(label + " offline", f.result == null ? null : f.result.offline, ProfileReplies.offline(s[1]));
        }
        eq("P4 STORED,0 is STORED", run("STORED", "0", "x", "OK", "NONE").result.sessionType, "STORED");
        eq("P4 LOCAL,0 is LOCAL", run("LOCAL", "0", "x", "OK", "NONE").result.sessionType, "LOCAL");
        eq("P4 LOCAL,0 is not offline", run("LOCAL", "0", "x", "OK", "NONE").result.offline, false);
        eq("P4 LOCAL,1 is LOCAL", run("LOCAL", "1", "x", "OK", "NONE").result.sessionType, "LOCAL");
        eq("P4 LOCAL,1 is offline", run("LOCAL", "1", "x", "OK", "NONE").result.offline, true);
        eq("P4 name", run("STORED", "0", " alice-test \n", "OK", "NONE").result.name, "alice-test");
        eq("P4 name NONE is null", run("STORED", "0", "NONE", "OK", "NONE").result.name, null);
        eq("P4 ota lines", run("STORED", "0", "x", "OK", "AVAIL 1.2.3\n\n  mandatory 1 \n").result.otaLines,
                Arrays.asList("AVAIL 1.2.3", "mandatory 1"));

        if (bad > 0) { System.out.println(bad + " of " + n + " cases failed"); System.exit(1); }
        System.out.println("ok " + n + " cases");
    }
}
JAVA

strip() { perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"; }
# body <file> <method>: the stripped source of one method of ProfileActivity, signature to its closing brace.
body() { strip "$1" | perl -0ne "print \$1 if /((?:private|protected|public) \\w+ $2\\([^)]*\\) \\{.*?\\n    \\})\\n/s"; }
count() { local c; c=$(printf '%s' "$1" | grep -o -F -- "$2" | wc -l); echo "$c"; }
# idx <text> <needle>: the offset of the first needle, -1 when absent.
idx() { NEEDLE="$2" perl -0e '$_ = join("", <STDIN>); print index($_, $ENV{NEEDLE})' <<<"$1"; }

# pins <ProfileActivity.java> -> 0 when every P5 pin holds, 1 otherwise (each failure is printed).
pins() {
  local pa="$1" bad=0 oc pr sc scv i j
  oc=$(body "$pa" onCreate)
  pr=$(body "$pa" probeSession)
  sc=$(body "$pa" showConfirm)
  scv=$(body "$pa" setContentView)
  [ -n "$oc" ] || { echo "  PIN   P5 onCreate not found"; return 1; }
  [ -n "$pr" ] || { echo "  PIN   P5 probeSession not found"; return 1; }
  [ -n "$sc" ] || { echo "  PIN   P5 showConfirm not found"; return 1; }
  [ -n "$scv" ] || { echo "  PIN   P5 the setContentView override not found"; return 1; }
  # onCreate reaches the probe, and reads the daemon nowhere before it
  i=$(idx "$oc" 'probeSession();')
  [ "$i" -ge 0 ] || { echo "  PIN   P5 onCreate does not call probeSession()"; bad=1; }
  if [ "$i" -ge 0 ]; then
    case "${oc:0:$i}" in *'sendDaemon('*|*'DaemonSocket.'*)
      echo "  PIN   P5 onCreate reads the daemon before probeSession()"; bad=1 ;; esac
  fi
  # probeSession hands every read to ProfileProbe, through DaemonSocket with a 5 s cap, never sendDaemon
  i=$(idx "$pr" 'ProfileProbe.run(')
  j=$(idx "$pr" 'DaemonSocket.')
  [ "$i" -ge 0 ] || { echo "  PIN   P5 probeSession does not run ProfileProbe"; bad=1; }
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || { echo "  PIN   P5 probeSession reads the daemon outside ProfileProbe.run"; bad=1; }
  [ "$(count "$pr" 'sendDaemon(')" = 0 ] || { echo "  PIN   P5 probeSession still reads through sendDaemon (90 s)"; bad=1; }
  [ "$(count "$pr" '90000')" = 0 ] || { echo "  PIN   P5 probeSession holds a 90000 read cap"; bad=1; }
  [ "$(count "$pr" 'DaemonSocket.roundTrip(msg, 5000)')" = 1 ] || { echo "  PIN   P5 the probe Sender's read cap is not 5000"; bad=1; }
  [ "$(count "$pr" 'DaemonSocket.roundTripLines("OTA-STATUS\n", 5000)')" = 1 ] || {
    echo "  PIN   P5 OTA-STATUS is not read with roundTripLines and a 5000 cap"; bad=1; }
  [ "$(count "$pr" 'DaemonSocket.')" = 2 ] || { echo "  PIN   P5 probeSession has a daemon read besides the two capped ones"; bad=1; }
  # the menu is drawn first, as CHECKING, and redrawn with the answer only while it is still on screen
  [ "$(count "$pr" 'sessionType = "CHECKING";')" = 1 ] || { echo "  PIN   P5 drawChecking does not set CHECKING"; bad=1; }
  [ "$(count "$pr" 'if (shownView == confirmView) showConfirm();')" = 1 ] || {
    echo "  PIN   P5 the answer's redraw is not guarded by the current content view"; bad=1; }
  [ "$(count "$pr" 'showConfirm();')" = 2 ] || { echo "  PIN   P5 probeSession has an unguarded redraw"; bad=1; }
  i=$(idx "$scv" 'shownView = view;'); j=$(idx "$scv" 'super.setContentView(view);')
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || { echo "  PIN   P5 the setContentView override does not record shownView"; bad=1; }
  [ "$(count "$sc" 'confirmView = sc;')" = 1 ] || { echo "  PIN   P5 showConfirm does not record confirmView"; bad=1; }
  i=$(idx "$sc" 'confirmView = sc;'); j=$(idx "$sc" 'setContentView(sc);')
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || { echo "  PIN   P5 confirmView is not recorded before setContentView(sc)"; bad=1; }
  # CHECKING is the UNKNOWN layout with its own line, no tap action, and no SEAL-DELTA read
  [ "$(count "$sc" 'final boolean checking = "CHECKING".equals(sessionType);')" = 1 ] || {
    echo "  PIN   P5 showConfirm does not know CHECKING"; bad=1; }
  [ "$(count "$sc" 'final boolean unknown = checking || "UNKNOWN".equals(sessionType);')" = 1 ] || {
    echo "  PIN   P5 CHECKING does not draw the UNKNOWN layout"; bad=1; }
  [ "$(count "$sc" 'status.setText(checking ? "Checking whether this session is saved…"')" = 1 ] || {
    echo "  PIN   P5 CHECKING does not say it is checking"; bad=1; }
  [ "$(count "$sc" 'if (unknown && !checking && !offline) status.setOnClickListener(v -> probeSession());')" = 1 ] || {
    echo "  PIN   P5 the retry tap is not withheld while CHECKING"; bad=1; }
  [ "$(count "$sc" 'if (!offline && !local && !unknown) {')" = 1 ] || {
    echo "  PIN   P5 the SEAL-DELTA read is not withheld while CHECKING or UNKNOWN"; bad=1; }
  return "$bad"
}

# suite <ProfileProbe.java> <ProfileReplies.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local pp="$1" rp="$2" pa="$3" d bad=0
  pins "$pa" || bad=1
  [ -f "$pp" ] || { echo "  PIN   ProfileProbe.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/cls"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/cls" "$pp" "$rp" "$W/cases/ProfileProbeCases.java" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/cls" com.nowhere.chooser.ProfileProbeCases || bad=1
  return "$bad"
}

echo "== $(basename "$PP") + $(basename "$RP") (+ pins in $(basename "$PA"))"
suite "$PP" "$RP" "$PA"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc $rc)"; exit 1; }
echo "all cases and pins passed"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by a case or a pin; a mutant that does not compile proves nothing)"
fails=0
# mut <label> <pp|pa> <perl-expr>: apply the edit to a copy and require the suite to FAIL on a case or a pin.
mut() {
  local label="$1" which="$2" expr="$3" d pp pa target orig rc
  d=$(mktemp -d -p "$W") || { echo "  ERROR $label: no temp dir"; fails=$((fails + 1)); return; }
  pp="$d/ProfileProbe.java"; pa="$d/ProfileActivity.java"
  cp "$PP" "$pp"; cp "$PA" "$pa"
  if [ "$which" = pa ]; then target="$pa"; orig="$PA"; else target="$pp"; orig="$PP"; fi
  if ! perl -0pi -e "$expr" "$target" || [ ! -s "$target" ]; then
    echo "  ERROR $label: the edit did not apply"; fails=$((fails + 1)); return
  fi
  if cmp -s "$target" "$orig"; then
    echo "  INERT $label: the edit changed nothing"; fails=$((fails + 1)); return
  fi
  suite "$pp" "$RP" "$pa" > "$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -e '--- FAIL' -e '  PIN ' "$d/out"; then
    echo "  convicted $label"
  elif [ "$rc" = 0 ]; then
    echo "  SURVIVED $label"; fails=$((fails + 1))
  else
    echo "  BROKEN $label (rc $rc)"; sed 's/^/    /' "$d/out" | head -5; fails=$((fails + 1))
  fi
}

# \x5c is a backslash: written that way, a mutation survives every layer of quoting unchanged.
mut "M1 drawChecking moved after the first send" pp \
  's/(\n        ui\.drawChecking\(\);)(.*?\n        final String type = reply\(s, "GET-SESSION-TYPE\x5cn"\);)/$2$1/s'
mut "M2 the stop at the first silence removed" pp \
  's/if \(!\w+\.isEmpty\(\)\) (\w+ = reply\()/$1/g'
mut "M3 the read cap back to 90000" pa \
  's/DaemonSocket\.roundTrip\(msg, 5000\)/DaemonSocket.roundTrip(msg, 90000)/'
mut "M4 the redraw guard removed" pa \
  's/if \(shownView == confirmView\) showConfirm\(\);/showConfirm();/'
mut "M5 OTA-STATUS sent before OTA-AFTER-LOGOFF" pp \
  's/"OTA-AFTER-LOGOFF\x5cn0\x5cn"/"\@SWAP\@"/; s/reply\(s, "OTA-STATUS\x5cn"\)/reply(s, "OTA-AFTER-LOGOFF\x5cn0\x5cn")/; s/"\@SWAP\@"/"OTA-STATUS\x5cn"/'

[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
