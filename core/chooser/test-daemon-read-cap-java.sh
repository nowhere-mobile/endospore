#!/usr/bin/env bash
# test-daemon-read-cap-java.sh [--root <repo>] [--mutate] -- NWP-20261210-14: the chooser's five daemon reads take
# their read cap from DaemonReadCap, by verb. Backlog row: "The chooser's daemon reads still wait 90 s when the
# connect lands in a wedged daemon's backlog that is not yet full: only the connect is bounded" (section B).
#
# WHY THIS IS COMMITTED. DaemonSocket.connect bounds only the connect. A connect that lands in a stopped daemon's
# listen backlog succeeds, and every read then waited 90 s, so Your data showed its failure copy after 195 s. A
# short cap is safe only for a verb that never waits on sessionMu (concurrentSafeCmd in core/agent/main.go) and does
# no store or network I/O: a short cap on a verb that can wait behind a seal turns a slow answer into a wrong one.
#
#   C1 each expected QUICK verb -> 10000 ms, also with payload lines after it and with surrounding spaces
#   C2 CREATE, CREATE-CODE, BACKUP, LOGOFF, DELETE, ROLLBACK, END-UNSAVED, EXPECT-SHRINK, an unknown verb, "" and
#      null -> 90000 ms
#   C3 the match is case-sensitive: "get-seal-landed" -> 90000 ms
#   C4 every QUICK verb is in concurrentSafeCmd's case list (extracted by anchors; SEAL-STATUS is the control that
#      must match, LOGOFF the control that must not)
#   C5 the five reader bodies use DaemonReadCap.forRequest(msg) and hold no literal 90000
#   C6 the Your data poll verbs (GET-SEAL-LANDED, GET-SYNC-INTERVAL, SEAL-STATUS) are QUICK
#
# The driver loads DaemonReadCap by reflection, so it compiles against a tree without the class and every check
# fails there one by one. It needs a JDK and FAILS when there is none: javac/java come from PATH, then the build
# VM's prebuilt JDK 21. --root runs the checks over another checkout (core/chooser and core/agent/main.go).
# --mutate re-runs the checks against broken copies; each must FAIL its named check (CONVICTED). A mutant that does
# not apply (INERT) or does not compile (BROKEN) is a failure. One control mutant (a comment) must SURVIVE.
set -uo pipefail
MUTATE=no
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --root) shift; [ $# -gt 0 ] || { echo "usage: $0 [--root <repo>] [--mutate]" >&2; exit 2; }; ROOT=$1 ;;
    *) echo "usage: $0 [--root <repo>] [--mutate]" >&2; exit 2 ;;
  esac
  shift
done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-daemon-read-cap-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CSRC="$ROOT/core/chooser/src/com/nowhere/chooser"
CAP="$CSRC/DaemonReadCap.java"
PA="$CSRC/ProfileActivity.java"
CA="$CSRC/ChooserActivity.java"
MAINGO="$ROOT/core/agent/main.go"
for f in "$PA" "$CA" "$MAINGO"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

CASES="$W/DaemonReadCapCases.java"
cat > "$CASES" <<'JAVA'
package com.nowhere.chooser;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class DaemonReadCapCases {
    // Independent of DaemonReadCap.QUICK, so removing a verb there cannot remove its case here.
    static final List<String> EXPECT_QUICK = Arrays.asList("SEAL-STATUS", "GET-SYNC-INTERVAL", "GET-SEAL-LANDED");
    static final List<String> YOUR_DATA_POLL = Arrays.asList("GET-SEAL-LANDED", "GET-SYNC-INTERVAL", "SEAL-STATUS");
    static int fails = 0, n = 0;
    static Method forRequest;
    static Set<?> quick;
    static String loadErr = "";

    static void check(String id, boolean ok, String detail) {
        n++;
        if (ok) System.out.println("PASS " + id);
        else { fails++; System.out.println("FAIL " + id + " -- " + detail); }
    }

    static Integer cap(String msg) {
        if (forRequest == null) return null;
        try { return (Integer) forRequest.invoke(null, msg); } catch (Throwable t) { return null; }
    }

    static String show(String s) { return s == null ? "null" : "\"" + s.replace("\n", "\\n") + "\""; }

    static void caps(String id, List<String> msgs, int want) {
        List<String> bad = new ArrayList<>();
        for (String m : msgs) {
            Integer got = cap(m);
            if (got == null || got != want) bad.add(show(m) + " -> " + got);
        }
        check(id, forRequest != null && bad.isEmpty(), forRequest == null ? "no DaemonReadCap.forRequest" + loadErr
                : "want " + want + ": " + bad);
    }

    static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    /** The text of the method whose signature is {@code sig}, through its balanced closing brace; null if absent. */
    static String body(String src, String sig) {
        int i = src.indexOf(sig);
        if (i < 0) return null;
        int b = src.indexOf('{', i), depth = 0;
        for (int k = b; k < src.length(); k++) {
            char c = src.charAt(k);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return src.substring(i, k + 1);
        }
        return null;
    }

    public static void main(String[] a) throws Exception {
        try {
            Class<?> c = Class.forName("com.nowhere.chooser.DaemonReadCap");
            forRequest = c.getDeclaredMethod("forRequest", String.class);
            forRequest.setAccessible(true);
            Field q = c.getDeclaredField("QUICK");
            q.setAccessible(true);
            quick = (Set<?>) q.get(null);
        } catch (Throwable t) {
            forRequest = null;
            loadErr = " (" + t + ")";
        }

        List<String> c1 = new ArrayList<>();
        for (String v : EXPECT_QUICK) {
            c1.add(v + "\n");
            c1.add(v);
            c1.add(v + "\nx\n");
            c1.add("  " + v + "  \nx\n");
        }
        caps("C1 each QUICK verb reads for 10000 ms", c1, 10000);
        caps("C2 every other request reads for 90000 ms", Arrays.asList("CREATE\nn\np\n", "CREATE-CODE\nn\np\nc\n",
                "BACKUP\n", "LOGOFF\n", "DELETE\nn\np\n", "ROLLBACK\nv\n", "END-UNSAVED\n", "EXPECT-SHRINK\n",
                "NO-SUCH-VERB\n", "", "\n", null), 90000);
        caps("C3 the verb match is case-sensitive", Arrays.asList("get-seal-landed\n", "Seal-Status\n",
                "get-sync-interval\n"), 90000);

        String go = read(a[2]);
        int s = go.indexOf("func concurrentSafeCmd(name string) bool {");
        int e = s < 0 ? -1 : go.indexOf("\n\treturn false\n}", s);
        List<String> cases = new ArrayList<>();
        if (e > s) {
            for (String line : go.substring(s, e).split("\n")) {
                int cm = line.indexOf("//");
                if (cm >= 0) line = line.substring(0, cm);
                Matcher m = Pattern.compile("\"([A-Z0-9-]+)\"").matcher(line);
                while (m.find()) cases.add(m.group(1));
            }
        }
        List<String> outside = new ArrayList<>();
        if (quick != null) for (Object v : quick) if (!cases.contains(String.valueOf(v))) outside.add(String.valueOf(v));
        check("C4 every QUICK verb is in concurrentSafeCmd",
                quick != null && !quick.isEmpty() && cases.contains("SEAL-STATUS") && !cases.contains("LOGOFF")
                        && outside.isEmpty(),
                quick == null ? "no DaemonReadCap.QUICK" + loadErr
                        : !cases.contains("SEAL-STATUS") || cases.contains("LOGOFF")
                        ? "the concurrentSafeCmd extraction failed its controls (" + cases.size() + " verbs)"
                        : "QUICK verbs concurrentSafeCmd does not list: " + outside);

        String pa = read(a[0]), ca = read(a[1]);
        Map<String, String[]> readers = new LinkedHashMap<>();
        readers.put("ProfileActivity.sendDaemon", new String[]{pa, "private String sendDaemon(String msg) {",
                "s.setSoTimeout(DaemonReadCap.forRequest(msg));"});
        readers.put("ProfileActivity.sendDaemonMulti", new String[]{pa, "private String sendDaemonMulti(String msg) {",
                "s.setSoTimeout(DaemonReadCap.forRequest(msg));"});
        readers.put("ProfileActivity.sendDaemonReply", new String[]{pa,
                "private DaemonReply sendDaemonReply(String msg, String[] second) {",
                "final int cap = DaemonReadCap.forRequest(msg);", "s.setSoTimeout(cap);", "TIMED OUT after \" + (cap / 1000) + \"s\""});
        readers.put("ChooserActivity.sendDaemon", new String[]{ca, "private String sendDaemon(String msg) {",
                "return DaemonSocket.roundTrip(msg, DaemonReadCap.forRequest(msg));"});
        readers.put("ChooserActivity.createStreaming", new String[]{ca, "private String createStreaming(String msg) {",
                "s.setSoTimeout(DaemonReadCap.forRequest(msg));"});
        List<String> bad = new ArrayList<>();
        for (Map.Entry<String, String[]> r : readers.entrySet()) {
            String[] v = r.getValue();
            String b = body(v[0], v[1]);
            if (b == null) { bad.add(r.getKey() + ": not found"); continue; }
            if (b.contains("90000")) bad.add(r.getKey() + ": holds a literal 90000");
            for (int k = 2; k < v.length; k++) if (!b.contains(v[k])) bad.add(r.getKey() + ": no " + v[k]);
        }
        check("C5 the five readers take their cap from DaemonReadCap", bad.isEmpty(), bad.toString());

        List<String> c6 = new ArrayList<>();
        for (String v : YOUR_DATA_POLL) {
            Integer got = cap(v + "\n");
            if (quick == null || !quick.contains(v) || got == null || got != 10000) c6.add(v);
        }
        check("C6 the Your data poll verbs are QUICK", forRequest != null && c6.isEmpty(),
                forRequest == null ? "no DaemonReadCap" + loadErr : "not QUICK: " + c6);

        if (fails > 0) { System.out.println(fails + " of " + n + " FAILED"); System.exit(1); }
        System.out.println("ALL " + n + " PASS");
    }
}
JAVA

run() { # run <DaemonReadCap.java|-> <ProfileActivity.java> <ChooserActivity.java> <main.go>; 3 = did not compile
  local d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src" "$d/out"
  cp "$CASES" "$d/src/DaemonReadCapCases.java"
  if [ -f "$1" ]; then cp "$1" "$d/src/DaemonReadCap.java"; fi
  "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d"/src/*.java || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.DaemonReadCapCases "$2" "$3" "$4"
}
echo "== $ROOT"
run "$CAP" "$PA" "$CA" "$MAINGO" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named check; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> cap|pa|ca <perl-expr> <check the mutant must fail, or SURVIVE for the control>
  local d f out rc orig
  d=$(mktemp -d -p "$W")
  case "$2" in cap) orig=$CAP ;; pa) orig=$PA ;; ca) orig=$CA ;; *) echo "  ERROR     $1 -- bad target $2"; return 1 ;; esac
  f="$d/$(basename "$orig")"
  cp "$orig" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$orig" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in
    cap) out=$(run "$f" "$PA" "$CA" "$MAINGO" 2>&1); rc=$? ;;
    pa) out=$(run "$CAP" "$f" "$CA" "$MAINGO" 2>&1); rc=$? ;;
    ca) out=$(run "$CAP" "$PA" "$f" "$MAINGO" 2>&1); rc=$? ;;
  esac
  if [ "$4" = SURVIVE ]; then
    if [ "$rc" -eq 0 ]; then echo "  survived  $1 (control)"; return 0; fi
    echo "  CONVICTED $1 -- a control mutant must survive (rc=$rc)"; return 1
  fi
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- the mutant did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "m1 GET-SEAL-LANDED removed from QUICK" cap 's/,\n\s*"GET-SEAL-LANDED"\)/)/' \
  "C1 each QUICK verb reads for 10000 ms" || fails=$((fails+1))
mut "m1b GET-SEAL-LANDED removed from QUICK (Your data)" cap 's/,\n\s*"GET-SEAL-LANDED"\)/)/' \
  "C6 the Your data poll verbs are QUICK" || fails=$((fails+1))
mut "m2 CREATE added to QUICK" cap 's/"SEAL-STATUS",/"SEAL-STATUS", "CREATE",/' \
  "C2 every other request reads for 90000 ms" || fails=$((fails+1))
mut "m3 the default flipped to SHORT_MS" cap 's/\? SHORT_MS : LONG_MS;/? SHORT_MS : SHORT_MS;/' \
  "C2 every other request reads for 90000 ms" || fails=$((fails+1))
mut "m4 the first line is not trimmed" cap 's/msg\.split\("\\n", 2\)\[0\]\.trim\(\);/msg.split("\\n", 2)[0];/' \
  "C1 each QUICK verb reads for 10000 ms" || fails=$((fails+1))
mut "m5 the match ignores case" cap 's/QUICK\.contains\(verb\)/QUICK.stream().anyMatch(verb::equalsIgnoreCase)/' \
  "C3 the verb match is case-sensitive" || fails=$((fails+1))
mut "m6 LOGOFF (not in concurrentSafeCmd) added to QUICK" cap 's/"SEAL-STATUS",/"SEAL-STATUS", "LOGOFF",/' \
  "C4 every QUICK verb is in concurrentSafeCmd" || fails=$((fails+1))
mut "m7 ProfileActivity.sendDaemon back to 90000" pa \
  's/(private String sendDaemon\(String msg\) \{.*?)s\.setSoTimeout\(DaemonReadCap\.forRequest\(msg\)\);/${1}s.setSoTimeout(90000);/s' \
  "C5 the five readers take their cap from DaemonReadCap" || fails=$((fails+1))
mut "m8 ProfileActivity.sendDaemonMulti back to 90000" pa \
  's/(private String sendDaemonMulti\(String msg\) \{.*?)s\.setSoTimeout\(DaemonReadCap\.forRequest\(msg\)\);/${1}s.setSoTimeout(90000);/s' \
  "C5 the five readers take their cap from DaemonReadCap" || fails=$((fails+1))
mut "m9 ProfileActivity.sendDaemonReply back to 90000" pa 's/s\.setSoTimeout\(cap\);/s.setSoTimeout(90000);/' \
  "C5 the five readers take their cap from DaemonReadCap" || fails=$((fails+1))
mut "m10 ChooserActivity.sendDaemon back to 90000" ca \
  's/return DaemonSocket\.roundTrip\(msg, DaemonReadCap\.forRequest\(msg\)\);/return DaemonSocket.roundTrip(msg, 90000);/' \
  "C5 the five readers take their cap from DaemonReadCap" || fails=$((fails+1))
mut "m11 ChooserActivity.createStreaming back to 90000" ca \
  's/(private String createStreaming\(String msg\) \{.*?)s\.setSoTimeout\(DaemonReadCap\.forRequest\(msg\)\);/${1}s.setSoTimeout(90000);/s' \
  "C5 the five readers take their cap from DaemonReadCap" || fails=$((fails+1))
mut "control: a comment's wording" cap 's/the cap every daemon read had before/the read cap every daemon read had before/' \
  SURVIVE || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted, the control survived" || { echo "== $fails mutation(s) not as required"; exit 1; }
