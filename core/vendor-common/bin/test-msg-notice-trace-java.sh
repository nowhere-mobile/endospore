#!/usr/bin/env bash
# test-msg-notice-trace-java.sh [--mutate] -- NWP-20261128-33: a session text notice reads itself back into login.log.
# Compiles and EXECUTES the pure MsgNoticeTrace.line (T1 the kept, stripped, changed and not-found lines; T2 the line
# holds no letter run but the verb and the key names, so a name or preview passed in never appears), then pins that
# both TelIngest notify sites (postRoamedMessageNotice and syncMessageSummary) schedule the read-back on the next line.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of MsgNoticeTrace.java and TelIngest.java, each of which must FAIL.
# A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-msg-notice-trace-java.sh            # the cases and the pin
#   bash test-msg-notice-trace-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-msg-notice-trace-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "test-msg-notice-trace-java: FAIL -- the pin needs python3, and there is none" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser

cat > "$W/Harness.java" <<'EOF'
package com.nowhere.chooser;

public class Harness {
    static int fails = 0;
    static void eq(String id, String got, String want) {
        if (got.equals(want)) System.out.println("PASS " + id);
        else { System.out.println("FAIL " + id + " got [" + got + "] want [" + want + "]"); fails++; }
    }
    public static void main(String[] a) {
        eq("T1 kept", MsgNoticeTrace.line(true, false, "Messages", "Messages", true, true),
                "smsnotice sum=0 subst=1 pub=1 icon=1");
        eq("T1 stripped", MsgNoticeTrace.line(true, true, null, "Messages", false, false),
                "smsnotice sum=1 subst=0 pub=0 icon=0");
        eq("T1 changed", MsgNoticeTrace.line(true, false, "Profile", "Messages", true, true),
                "smsnotice sum=0 subst=0 pub=1 icon=1");
        eq("T1 nothing posted", MsgNoticeTrace.line(true, false, "Messages", null, true, false),
                "smsnotice sum=0 subst=0 pub=1 icon=0");
        eq("T1 not found", MsgNoticeTrace.line(false, true, "Messages", "Messages", true, true),
                "smsnotice sum=1 subst=-1");
        java.util.Set<String> ok = new java.util.HashSet<>(java.util.Arrays.asList("smsnotice", "sum", "subst", "pub", "icon"));
        String[] leaks = {"Alice Smith", "alicepreview", "+15551234567", "sms:123", "com.android.messaging"};
        for (String s : leaks) {
            for (boolean found : new boolean[]{true, false}) {
                for (String[] p : new String[][]{{s, s}, {s, "Messages"}, {"Messages", s}}) {
                    String l = MsgNoticeTrace.line(found, true, p[0], p[1], true, true);
                    String bad = null;
                    java.util.regex.Matcher m = java.util.regex.Pattern.compile("[A-Za-z]+").matcher(l);
                    while (m.find()) if (!ok.contains(m.group())) { bad = m.group(); break; }
                    if (bad == null && (l.contains("?") || l.contains("+") || l.contains(":"))) bad = "punctuation";
                    String id = "T2 no text from [" + p[0] + "]/[" + p[1] + "] found=" + found;
                    if (bad == null) System.out.println("PASS " + id);
                    else { System.out.println("FAIL " + id + ": [" + bad + "] in [" + l + "]"); fails++; }
                }
            }
        }
        System.exit(fails == 0 ? 0 : 1);
    }
}
EOF

cat > "$W/pin.py" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
fails = 0
def check(id, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + id)
    if not ok: fails += 1
def body(name):
    m = re.search(r'\n    (?:private )?static void ' + name + r'\(.*?\n    \}\n', s, re.S)
    return m.group(0) if m else ""
post = body("postRoamedMessageNotice")
m = re.search(r'\n\s*nm\.notify\(tag, (.+?), b\.build\(\)\);\n([^\n]*)\n', post)
check("P1 postRoamedMessageNotice: the line after nm.notify(tag, ...) schedules the read-back with the same id",
      bool(m) and m.group(2).strip().startswith("traceNoticeReadBack(ctx, tag, " + m.group(1) +
      ", false, named.getString(SmsDeliverReceiver.EXTRA_SUBST_APP_NAME));"))
summ = body("syncMessageSummary")
m = re.search(r'\n\s*nm\.notify\(MessageGroup\.SUMMARY_TAG, MessageGroup\.SUMMARY_ID, summary\);\n([^\n]*)\n', summ)
check("P2 syncMessageSummary: the line after the summary's nm.notify schedules the read-back",
      bool(m) and m.group(1).strip().startswith("traceNoticeReadBack(ctx, MessageGroup.SUMMARY_TAG, MessageGroup.SUMMARY_ID, "
      "true, extras.getString(SmsDeliverReceiver.EXTRA_SUBST_APP_NAME));"))
check("P3 traceNoticeReadBack is called at those two sites only", s.count("traceNoticeReadBack(ctx, ") == 2)
h = body("traceNoticeReadBack")
check("P4 the read-back runs on its own started thread, about 1 s later, and swallows every throwable",
      "new Thread(" in h and "Thread.sleep(1000);" in h and "t.start();" in h and h.count("catch (Throwable ignore) {}") == 2)
check("P5 the read-back reads the active notices and sends MsgNoticeTrace's line through idleTrace",
      "getActiveNotifications()" in h and "ChooserActivity.idleTrace(MsgNoticeTrace.line(" in h)
sys.exit(1 if fails else 0)
EOF

# run <root>: compile the real MsgNoticeTrace.java with the harness and run it, then the pin on TelIngest.java.
run() {
  local d rc=0
  d=$(mktemp -d -p "$W")
  if ! "$JAVAC" -d "$d" "$1/$CH/MsgNoticeTrace.java" "$W/Harness.java" 2>&1; then echo "javac error: no compile"; return 3; fi
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.Harness || rc=1
  python3 "$W/pin.py" "$1/$CH/TelIngest.java" || rc=1
  return "$rc"
}
out=$(run "$ROOT" 2>&1); rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "== $(grep -c '^PASS ' <<<"$out") checks passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file: MsgNoticeTrace.java|TelIngest.java> <python-regex> <replacement>
  local d out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  cp "$ROOT/$CH/MsgNoticeTrace.java" "$ROOT/$CH/TelIngest.java" "$d/$CH/"
  if ! python3 - "$d/$CH/$2" "$3" "$4" <<'PY'; then echo "  INERT     $1 -- the mutation did not apply"; return 1; fi
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1: sys.exit(1)
open(p,'w').write(n)
PY
  out=$(run "$d" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -q '^FAIL ' <<<"$out"; then echo "  BROKEN    $1 -- it failed, but no check reported FAIL (rc=$rc)"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 subst always 1" MsgNoticeTrace.java '" subst=" \+ \(kept \? 1 : 0\)' '" subst=" + 1' || fails=$((fails+1))
mut "M2 the substName text leaked into the line" MsgNoticeTrace.java '(" subst=" \+ \(kept \? 1 : 0\))' '\1 + " " + substName' || fails=$((fails+1))
mut "M3 the notice site's call removed" TelIngest.java '\n[^\n]*traceNoticeReadBack\(ctx, tag, [^\n]*' '' || fails=$((fails+1))
mut "M4 the summary site's call removed" TelIngest.java '\n[^\n]*traceNoticeReadBack\(ctx, MessageGroup\.SUMMARY_TAG, [^\n]*' '' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
