#!/usr/bin/env bash
# NWP-20261210-01: the chooser's EXPECT-SHRINK-ANDROID sender (backlog row "A SHRUNKEN `#de` SCOPE WEDGES LOGOFF
# PERMANENTLY", decision 2026-11-05 h59 #5).
#   A/P/R: ShrinkAndroidArm (java.* only) compiled with a JDK and driven case by case.
#   S:     source pins over NowhereApp.java, AppInstallReceiver.java and ShrinkAndroidSender.java (Android classes,
#          which a JDK cannot compile; the merger's build-host javac covers them).
# Usage: test-shrink-android-sender-java.sh [--mutate]
# Each assertion prints "FAIL <id>: ..."; a mutant must be CONVICTED by the id it names. Nothing is left behind.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/core/chooser/src/com/nowhere/chooser"
MAIN_GO="$ROOT/core/agent/main.go"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
FILES="ShrinkAndroidArm.java ShrinkAndroidSender.java NowhereApp.java AppInstallReceiver.java"

PRISTINE="$W/pristine"
mkdir -p "$PRISTINE"
for f in $FILES; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$PRISTINE/"
done

# The verb the agent dispatches: the literal on main.go's `if name == "EXPECT-SHRINK-ANDROID" {` line. A control:
# exactly one such line must match, or the suite fails before any case runs.
VERB_LINES=$(grep -cE '^[[:space:]]*if name == "EXPECT-SHRINK-ANDROID" \{$' "$MAIN_GO")
if [ "$VERB_LINES" != 1 ]; then
    echo "FAIL control: main.go has $VERB_LINES EXPECT-SHRINK-ANDROID dispatch line(s), want 1" >&2
    exit 1
fi
AGENT_VERB=$(sed -nE 's/^[[:space:]]*if name == "(EXPECT-SHRINK-ANDROID)" \{$/\1/p' "$MAIN_GO")

DRIVER="$W/ArmCases.java"
cat > "$DRIVER" <<'JAVA'
package com.nowhere.chooser;
import java.util.*;
final class ArmCases {
    static final String C = "android.intent.action.PACKAGE_DATA_CLEARED", R = "android.intent.action.PACKAGE_REMOVED";
    static final String SELF = "com.nowhere.chooser", P = "com.example.app";
    static int fails;
    static void ok(boolean b, String id) { if (!b) { fails++; System.out.println("FAIL " + id); } }
    static String arm(String a, String p, int u, boolean rep, boolean arch, Boolean removed) {
        return ShrinkAndroidArm.armed(a, p, SELF, u, rep, arch, removed);
    }
    public static void main(String[] args) {
        String agentVerb = args[0];
        ok(P.equals(arm(C, P, 10, false, false, null)), "A1: DATA_CLEARED in user 10 arms");
        ok(arm(C, P, 0, false, false, null) == null, "A2: DATA_CLEARED in user 0 does not arm");
        ok(arm(R, P, 0, false, false, null) == null, "A2: REMOVED in user 0 does not arm");
        ok(arm(R, P, 10, true, false, null) == null, "A3: REMOVED replacing=true does not arm");
        ok(arm(R, P, 10, false, true, null) == null, "A4: REMOVED archival=true does not arm");
        ok(arm(R, P, 10, false, false, Boolean.FALSE) == null, "A5: REMOVED dataRemoved=FALSE does not arm");
        ok(P.equals(arm(R, P, 10, false, false, null)), "A5: REMOVED dataRemoved absent arms");
        ok(P.equals(arm(R, P, 10, false, false, Boolean.TRUE)), "A5: REMOVED dataRemoved=TRUE arms");
        char[] longName = new char[256]; Arrays.fill(longName, 'a'); longName[3] = '.';
        for (String p : new String[]{SELF, "a..b", "1abc.def", "1abc", new String(longName), "com.exämple.app",
                "com.example.", ".com.example", "com/example", null, ""})
            ok(arm(C, p, 10, false, false, null) == null, "A6: own or invalid name does not arm: " + p);
        ok("a.b".equals(arm(C, "a.b", 10, false, false, null)), "A6: a valid two-segment name arms");
        ok(arm("android.intent.action.PACKAGE_ADDED", P, 10, false, false, null) == null, "A7: PACKAGE_ADDED does not arm");
        ok(arm("android.intent.action.PACKAGE_REPLACED", P, 10, false, false, null) == null, "A7: PACKAGE_REPLACED does not arm");
        ok(arm(null, P, 10, false, false, null) == null, "A7: a null action does not arm");

        List<String> names = new ArrayList<>(Arrays.asList("com.a.one", "bad..name", "com.a.one", "com.a.two"));
        for (int i = 0; i < 70; i++) names.add("com.pkg.p" + i);
        String p = ShrinkAndroidArm.payload(names);
        ok(p != null && p.startsWith(agentVerb + "\n"), "P1: the payload's verb line is main.go's verb");
        ok(agentVerb.equals(ShrinkAndroidArm.VERB), "P1: ShrinkAndroidArm.VERB is byte-equal to main.go's verb");
        if (p != null) {
            ok(p.endsWith("\n") && !p.endsWith("\n\n") && p.split("\n", -1).length == 3, "P1: two lines, one trailing newline");
            String[] parts = p.split("\n", -1);
            String[] got = parts.length > 1 ? parts[1].split(" ", -1) : new String[0];
            ok(got.length == 64, "P1: capped at 64 names (got " + got.length + ")");
            ok(new LinkedHashSet<>(Arrays.asList(got)).size() == got.length, "P1: deduped");
            ok(got.length > 2 && got[0].equals("com.a.one") && got[1].equals("com.a.two") && got[2].equals("com.pkg.p0")
                    && got[got.length - 1].equals("com.pkg.p61"), "P1: first-seen order, invalid names dropped");
        }
        ok("EXPECT-SHRINK-ANDROID\ncom.x.y\n".equals(ShrinkAndroidArm.payload(Collections.singletonList("com.x.y"))),
                "P1: one name, exact bytes");
        ok(ShrinkAndroidArm.payload(Collections.<String>emptyList()) == null, "P2: no names -> null");
        ok(ShrinkAndroidArm.payload(Arrays.asList("bad..name", "1x.y")) == null, "P2: only invalid names -> null");
        ok(ShrinkAndroidArm.payload(null) == null, "P2: null -> null");
        for (int i = 1; i <= 20; i++) ok(ShrinkAndroidArm.retryDelayMs(i) == 30000L, "R1: retryDelayMs(" + i + ") == 30000");
        ok(ShrinkAndroidArm.retryDelayMs(21) == -1L, "R1: retryDelayMs(21) == -1");
        ok(ShrinkAndroidArm.retryDelayMs(0) == -1L, "R1: retryDelayMs(0) == -1");
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA

PINS="$W/pins.py"
cat > "$PINS" <<'PY'
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
fails = 0
def ok(b, msg):
    global fails
    if not b:
        fails += 1
        print("FAIL " + msg)
def read(name):
    p = d / name
    return p.read_text() if p.exists() else ""
def code(text):
    # drop // comments and /* */ blocks so a pin never matches prose
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", l) for l in text.splitlines())

app = code(read("NowhereApp.java"))
m = re.search(r"new android\.content\.IntentFilter\(\s*android\.content\.Intent\.ACTION_PACKAGE_ADDED\);(.*?)"
              r"f\.addDataScheme\(\"package\"\);(.*?)registerReceiver\(new AppInstallReceiver\(\)", app, re.S)
ok(m is not None and "f.addAction(android.content.Intent.ACTION_PACKAGE_DATA_CLEARED);" in m.group(1),
   "S1: NowhereApp's install filter adds ACTION_PACKAGE_DATA_CLEARED")

rcv = code(read("AppInstallReceiver.java"))
lines = [l.strip() for l in rcv.splitlines() if l.strip()]
s2 = False
try:
    i = lines.index("WORKER.execute(() -> {")
    s2 = (lines[i + 1] == "try {" and lines[i + 2] == "try {"
          and lines[i + 3] == "ShrinkAndroidSender.onBroadcast(context, intent);"
          and lines[i + 4].startswith("} catch (Throwable"))
    hook = rcv.find("ShrinkAndroidSender.onBroadcast(context, intent);")
    ret = rcv.find("EXTRA_REPLACING, false)) return;")
    s2 = s2 and rcv.count("ShrinkAndroidSender.onBroadcast(") == 1 and 0 <= hook < ret
except ValueError:
    pass
ok(s2, "S2: onBroadcast is the first statement in the WORKER try, in its own try/catch, before the REPLACING return")

snd = code(read("ShrinkAndroidSender.java"))
ok(snd != "" and "WORKER" not in snd, "S3: ShrinkAndroidSender never uses AppInstallReceiver's WORKER")
ok("Executors.newSingleThreadScheduledExecutor(" in snd and "setDaemon(true)" in snd,
   "S3: the sender owns one daemon ScheduledExecutorService")
ok(re.search(r"EXECUTOR\.execute\(\(\) -> \{", snd) is not None, "S3: an armed name goes to the sender's own executor")
ok("String payload = ShrinkAndroidArm.payload(QUEUED);" in snd and "DaemonSocket.roundTrip(payload, 90000)" in snd,
   "S3: the send is roundTrip(payload, 90000) over the queued names")
ok("ShrinkAndroidArm.armed(action, pkg, context.getPackageName(), UserHandle.myUserId()," in snd
   and "intent.hasExtra(Intent.EXTRA_DATA_REMOVED)" in snd and '"android.intent.extra.ARCHIVAL"' in snd,
   "S3: onBroadcast feeds the arm rule the user id, ARCHIVAL by name and DATA_REMOVED only when present")

logs = re.findall(r"\bLog\.[a-z]+\((.*?)\);", snd, re.S)
ok(len(logs) >= 1, "S4: the sender logs its sends")
bad = [l for l in logs if re.search(r"\b(pkg|armed|payload|reply|QUEUED|intent|data|names?)\b|String\.join|\bt\b",
                                    re.sub(r'"(?:[^"\\]|\\.)*"', '""', l))]
ok(not bad, "S4: no Log call in ShrinkAndroidSender prints a package, the payload or the raw reply")
ok('"shrink-android: " + n + " package(s) sent, reply " + replyClass + " (NWP-20261210-01)"' in snd,
   "S4: the log line is the fixed count-only format")

m = re.search(r"private static void send\(\) \{(.*?)\n    \}", snd, re.S)
send = m.group(1) if m else ""
okidx = send.find('"NONE".equals(replyClass)')
ok(okidx >= 0 and "QUEUED.clear();" in send and send.rfind("scheduleRetry();") > okidx,
   "S5: OK/NONE clears the queue, any other reply schedules the retry")
m = re.search(r"private static void scheduleRetry\(\) \{(.*?)\n    \}", snd, re.S)
sr = m.group(1) if m else ""
ok("ShrinkAndroidArm.retryDelayMs(++attempts)" in sr and "if (delay < 0) return;" in sr
   and "EXECUTOR.schedule(" in sr and "!retry.isDone()) return;" in sr,
   "S5: the retry goes through retryDelayMs on the sender's executor, one at a time, and stops at -1")
m = re.search(r"EXECUTOR\.execute\(\(\) -> \{(.*?)\}\);", snd, re.S)
ok(m is not None and "cancelRetry();" in m.group(1) and "attempts = 0;" in m.group(1),
   "S5: a new event's send resets the retry count")
sys.exit(1 if fails else 0)
PY

# check DIR: every assertion over the sources in DIR. Prints FAIL lines; returns non-zero on any failure.
check() {
    local dir="$1" cls rc=0
    cls=$(mktemp -d -p "$W") || return 2
    if [ ! -f "$dir/ShrinkAndroidArm.java" ]; then
        echo "FAIL A1-R1: ShrinkAndroidArm.java is absent"; rc=1
    elif ! javac -d "$cls" "$dir/ShrinkAndroidArm.java" "$DRIVER" 2>&1; then
        echo "FAIL A1-R1: ShrinkAndroidArm.java does not compile"; rc=1
    elif ! java -Djava.io.tmpdir="$W" -cp "$cls" com.nowhere.chooser.ArmCases "$AGENT_VERB"; then
        rc=1
    fi
    python3 -I "$PINS" "$dir" || rc=1
    rm -rf "$cls"
    return "$rc"
}

out=$(check "$PRISTINE"); rc=$?
if [ "$rc" != 0 ]; then
    printf '%s\n' "$out"
    echo "shrink-android sender: FAIL"
    exit 1
fi
echo "shrink-android sender: all A/P/R/S assertions PASS (verb $AGENT_VERB from main.go)"
[ "${1:-}" = "--mutate" ] || exit 0

# mutant LABEL ID FILE OLD NEW [OLD NEW ...]: replace each OLD (which must occur) by its NEW, in order, in a copy,
# then require FAIL <ID>. ID SURVIVE is the control: it must pass every assertion.
MUTANT_FAILS=0
mutant() {
    local label="$1" id="$2" file="$3" dir mout
    shift 3
    dir=$(mktemp -d -p "$W") || exit 2
    cp "$PRISTINE"/* "$dir/"
    if ! python3 -I - "$dir/$file" "$@" <<'PY'
import sys
p, pairs = sys.argv[1], sys.argv[2:]
s = open(p).read()
t = s
for old, new in zip(pairs[0::2], pairs[1::2]):
    if old not in t:
        sys.exit(1)
    t = t.replace(old, new, 1)
if len(pairs) % 2 or t == s:
    sys.exit(1)
open(p, "w").write(t)
PY
    then
        echo "MUTANT DID NOT APPLY: $label"; MUTANT_FAILS=$((MUTANT_FAILS + 1)); return
    fi
    mout=$(check "$dir")
    if [ "$id" = SURVIVE ]; then
        if [ -z "$mout" ]; then echo "SURVIVED (control): $label"
        else echo "CONTROL MUTANT CONVICTED (it must survive): $label"; printf '%s\n' "$mout"; MUTANT_FAILS=$((MUTANT_FAILS + 1)); fi
    else
        case "$mout" in
            *"FAIL $id"*) echo "CONVICTED by $id: $label" ;;
            *) echo "MUTANT SURVIVED ($id expected): $label"; printf '%s\n' "$mout"; MUTANT_FAILS=$((MUTANT_FAILS + 1)) ;;
        esac
    fi
    rm -rf "$dir"
}

A=ShrinkAndroidArm.java; S=ShrinkAndroidSender.java
mutant "user-0 guard removed" A2 "$A" 'if (userId == 0 || pkg == null' 'if (pkg == null'
mutant "replacing ignored" A3 "$A" '&& !replacing && !archival' '&& !archival'
mutant "archival ignored" A4 "$A" '&& !archival && !Boolean' '&& !Boolean'
mutant "dataRemoved ignored" A5 "$A" ' && !Boolean.FALSE.equals(dataRemoved)) return pkg;' ') return pkg;'
mutant "DATA_CLEARED dropped" A1 "$A" '        if (DATA_CLEARED.equals(action)) return pkg;
' ''
mutant "dedupe removed, cap 65" P1 "$A" 'LinkedHashSet<String> unique = new LinkedHashSet<>();' 'java.util.ArrayList<String> unique = new java.util.ArrayList<>();'
mutant "cap 65" P1 "$A" 'if (unique.size() == MAX_PKGS) break;' 'if (unique.size() == MAX_PKGS + 1) break;'
mutant "verb typo" P1 "$A" 'static final String VERB = "EXPECT-SHRINK-ANDROID";' 'static final String VERB = "EXPECT-SHRINK-ANDRIOD";'
mutant "retryDelayMs never returns -1" R1 "$A" '? RETRY_MS : -1L;' '? RETRY_MS : RETRY_MS;'
mutant "the retry schedule removed" S5 "$S" '        scheduleRetry();
    }' '    }'
mutant "filter line removed" S1 NowhereApp.java '            f.addAction(android.content.Intent.ACTION_PACKAGE_DATA_CLEARED);
' ''
mutant "hook moved after the REPLACING return" S2 AppInstallReceiver.java \
    'ShrinkAndroidSender.onBroadcast(context, intent); // NWP-20261210-01: FIRST, before any return below' '' \
    'if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return;' 'if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return;
                    ShrinkAndroidSender.onBroadcast(context, intent);'
mutant "send on WORKER" S3 "$S" 'EXECUTOR.execute(() -> {' 'AppInstallReceiver.WORKER.execute(() -> {'
mutant "log names the package" S4 "$S" '"shrink-android: " + n + " package(s) sent' '"shrink-android: " + QUEUED + " package(s) sent'
mutant "a comment's wording" SURVIVE "$S" 'never on AppInstallReceiver' 'not ever on AppInstallReceiver'

if [ "$MUTANT_FAILS" != 0 ]; then
    echo "shrink-android sender --mutate: $MUTANT_FAILS mutant(s) not handled: FAIL"
    exit 1
fi
echo "shrink-android sender --mutate: every mutant CONVICTED, control survived: PASS"
