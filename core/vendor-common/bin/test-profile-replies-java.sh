#!/usr/bin/env bash
# test-profile-replies-java.sh [--mutate] -- the Profile screen's reading of GET-SESSION-TYPE, GET-OFFLINE and SET-TZ,
# run under javac (NWP-20261025-09).
#
# WHY THIS IS COMMITTED. sendDaemon returns "" on any failure, and the Profile screen rendered "" as an answer: a stored
# offline-started session (type LOCAL) whose GET-OFFLINE read timed out was shown as "Throwaway" with a Save offer, and
# the time-zone toast said "Time zone: X" before SET-TZ answered, whatever it answered (docs/backlog.md, "every
# user-facing daemon read/write that times out fails SILENTLY"). ProfileReplies.java decides and is pure Java, so this
# compiles it directly; the PINS check that ProfileProbe (the Profile screen's session probe, NWP-20261113-06) and
# setTzAndApply actually ask it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-profile-replies-java.sh            # the cases and the pins
#   bash test-profile-replies-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
RP="$DIR/ProfileReplies.java"
PA="$DIR/ProfileActivity.java"
PP="$DIR/ProfileProbe.java"
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

mkdir -p "$W/cases"
cat > "$W/cases/ProfileRepliesCases.java" <<'JAVA'
package com.nowhere.chooser;

public class ProfileRepliesCases {
    static int n = 0, bad = 0;

    static void eq(String label, Object got, Object want) {
        n++;
        if (!String.valueOf(got).equals(String.valueOf(want))) {
            bad++;
            System.out.println("--- FAIL " + label + ": got [" + got + "] want [" + want + "]");
        }
    }

    public static void main(String[] a) {
        eq("type LOCAL,1", ProfileReplies.sessionType("LOCAL", "1"), "LOCAL");
        eq("type LOCAL,0", ProfileReplies.sessionType("LOCAL", "0"), "LOCAL");
        eq("type LOCAL,empty", ProfileReplies.sessionType("LOCAL", ""), "UNKNOWN");
        eq("type LOCAL,garbage", ProfileReplies.sessionType("LOCAL", "garbage"), "UNKNOWN");
        eq("type STORED,empty", ProfileReplies.sessionType("STORED", ""), "STORED");
        eq("type empty,1", ProfileReplies.sessionType("", "1"), "UNKNOWN");
        eq("type padded LOCAL,0", ProfileReplies.sessionType("  LOCAL \n", "0"), "LOCAL");
        eq("type null,null", ProfileReplies.sessionType(null, null), "UNKNOWN");
        eq("type NONE,empty", ProfileReplies.sessionType("NONE", ""), "NONE");

        eq("offline 1", ProfileReplies.offline("1"), true);
        eq("offline 1 newline", ProfileReplies.offline("1\n"), true);
        eq("offline 0", ProfileReplies.offline("0"), false);
        eq("offline empty", ProfileReplies.offline(""), false);
        eq("offline 10x", ProfileReplies.offline("10x"), false);
        eq("offline null", ProfileReplies.offline(null), false);

        String later = "Saved. It takes effect from your next sign-in.";
        String[] oks = {"OK APPLIED", "OK AUTO", "OK APPLIED\n"};
        String[] notOks = {"", "ERR-TZ", "ERR-WORKER-BUSY", "ERR-TIMEOUT", "OK", "garbage", null};
        String[] olsons = {"", "Europe/Paris"};
        for (String o : olsons) {
            String applied = o.isEmpty() ? "Time zone: Automatic" : "Time zone: " + o;
            for (String r : oks) eq("tz ok [" + r + "] olson [" + o + "]", ProfileReplies.tzToast(true, r, o), applied);
            for (String r : notOks) eq("tz [" + r + "] olson [" + o + "]", ProfileReplies.tzToast(true, r, o), later);
            eq("tz unsaved OK olson [" + o + "]", ProfileReplies.tzToast(false, "OK APPLIED", o),
                    "Couldn't save the time zone. Try again.");
            eq("tz unsaved empty olson [" + o + "]", ProfileReplies.tzToast(false, "", o),
                    "Couldn't save the time zone. Try again.");
        }
        if (bad > 0) { System.out.println(bad + " of " + n + " cases failed"); System.exit(1); }
        System.out.println("ok " + n + " cases");
    }
}
JAVA

strip() { perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"; }
# body <file> <method>: the stripped source of one private method of ProfileActivity.
body() { strip "$1" | perl -0ne "print \$1 if /(private \\w+ $2\\([^)]*\\) \\{.*?\\n    \\})\\n/s"; }
count() { local c; c=$(printf '%s' "$1" | grep -o -F -- "$2" | wc -l); echo "$c"; }

# suite <ProfileReplies.java> <ProfileActivity.java> <ProfileProbe.java> -> 0 pass, 1 a case or a pin failed, 3 compile.
# The session probe's reads moved from ProfileActivity.probeSession into ProfileProbe.run (NWP-20261113-06), so the
# GET-SESSION-TYPE / GET-OFFLINE pins read the whole of ProfileProbe.java.
suite() {
  local rp="$1" pa="$2" pp="$3" probe tz n d
  [ -f "$rp" ] || { echo "  PIN   ProfileReplies.java does not exist"; return 1; }
  [ -f "$pp" ] || { echo "  PIN   ProfileProbe.java does not exist"; return 1; }
  probe=$(strip "$pp")
  tz=$(body "$pa" setTzAndApply)
  [ -n "$probe" ] || { echo "  PIN   ProfileProbe.java is empty"; return 1; }
  [ -n "$tz" ] || { echo "  PIN   setTzAndApply not found"; return 1; }
  n=$(count "$probe" 'ProfileReplies.sessionType(')
  [ "$n" = 1 ] || { echo "  PIN   ProfileProbe calls ProfileReplies.sessionType( $n times, not once"; return 1; }
  n=$(count "$probe" 'ProfileReplies.offline(')
  [ "$n" = 1 ] || { echo "  PIN   ProfileProbe calls ProfileReplies.offline( $n times, not once"; return 1; }
  n=$(count "$probe" '.startsWith("1")')
  [ "$n" = 0 ] || { echo "  PIN   ProfileProbe reads GET-OFFLINE with startsWith(\"1\") again"; return 1; }
  n=$(count "$tz" 'ProfileReplies.tzToast(')
  [ "$n" = 1 ] || { echo "  PIN   setTzAndApply calls ProfileReplies.tzToast( $n times, not once"; return 1; }
  n=$(count "$tz" 'Toast.makeText')
  [ "$n" = 1 ] || { echo "  PIN   setTzAndApply holds $n Toast.makeText, not one"; return 1; }
  n=$(printf '%s' "$tz" | perl -0ne 'print((/runOnUiThread\(\(\) -> android\.widget\.Toast\.makeText\(this,\s*ProfileReplies\.tzToast\(/s) ? 1 : 0)')
  [ "$n" = 1 ] || { echo "  PIN   setTzAndApply's Toast is not posted by runOnUiThread"; return 1; }
  n=$(printf '%s' "$tz" | perl -0ne 'print((index($_,"SET-TZ") >= 0 && index($_,"SET-TZ") < index($_,"Toast.makeText")) ? 1 : 0)')
  [ "$n" = 1 ] || { echo "  PIN   setTzAndApply toasts before it sends SET-TZ"; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/cls"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/cls" "$rp" "$W/cases/ProfileRepliesCases.java" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/cls" com.nowhere.chooser.ProfileRepliesCases || return 1
  return 0
}

suite "$RP" "$PA" "$PP" || { echo FAILED; exit 1; }
[ "$MUTATE" = yes ] || exit 0

fails=0
# mut <label> <rp|pa|pp> <perl-expr>: apply the edit to a copy and require the suite to FAIL on a case or a pin.
mut() {
  local label="$1" which="$2" expr="$3" d rp pa pp rc
  d=$(mktemp -d -p "$W") || { echo "  ERROR $label: no temp dir"; fails=$((fails + 1)); return; }
  rp="$d/ProfileReplies.java"; pa="$d/ProfileActivity.java"; pp="$d/ProfileProbe.java"
  cp "$RP" "$rp"; cp "$PA" "$pa"; cp "$PP" "$pp"
  local target="$rp"; [ "$which" = pa ] && target="$pa"; [ "$which" = pp ] && target="$pp"
  if ! perl -0pi -e "$expr" "$target" || [ ! -s "$target" ]; then
    echo "  ERROR $label: the edit did not apply"; fails=$((fails + 1)); return
  fi
  if { [ "$which" = pa ] && cmp -s "$pa" "$PA"; } || { [ "$which" = rp ] && cmp -s "$rp" "$RP"; } \
     || { [ "$which" = pp ] && cmp -s "$pp" "$PP"; }; then
    echo "  INERT $label: the edit changed nothing"; fails=$((fails + 1)); return
  fi
  suite "$rp" "$pa" "$pp" > "$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -e '--- FAIL' -e '  PIN ' "$d/out"; then
    echo "  convicted $label"
  elif [ "$rc" = 0 ]; then
    echo "  SURVIVED $label"; fails=$((fails + 1))
  else
    echo "  BROKEN $label (rc $rc)"; sed 's/^/    /' "$d/out" | head -5; fails=$((fails + 1))
  fi
}

mut "(a) sessionType ignores the GET-OFFLINE answer" rp \
  's/\n\s*if \("LOCAL"\.equals\(t\) && !"1"\.equals\(off\) && !"0"\.equals\(off\)\) return "UNKNOWN";//'
mut "(b) tzToast treats every saved reply as applied" rp \
  's/if \(r\.startsWith\("OK APPLIED"\) \|\| r\.startsWith\("OK AUTO"\)\)/if (true)/'
mut "(c) tzToast treats an empty reply as applied" rp \
  's/if \(r\.startsWith\("OK APPLIED"\)/if (r.isEmpty() || r.startsWith("OK APPLIED")/'
mut "(d) ProfileProbe reads GET-OFFLINE with startsWith again" pp \
  's/ProfileReplies\.offline\(off\)/off.startsWith("1")/'
mut "(e) setTzAndApply toasts before the reply" pa \
  's/(final boolean saved = writeTzOverride\(olson\);\n)/$1        android.widget.Toast.makeText(this, ProfileReplies.tzToast(saved, "OK APPLIED", olson), android.widget.Toast.LENGTH_SHORT).show();\n/; s/runOnUiThread\(\(\) -> android\.widget\.Toast\.makeText\(this,\s*ProfileReplies\.tzToast\(saved, reply, olson\), android\.widget\.Toast\.LENGTH_SHORT\)\.show\(\)\);/android.util.Log.i("NowhereChooser", "settz " + reply);/'
mut "(f) offline accepts 10x" rp \
  's/return "1"\.equals\(trim\(offlineReply\)\);/return trim(offlineReply).startsWith("1");/'

[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
