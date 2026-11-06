#!/usr/bin/env bash
# test-build-warning-notice-java.sh [--mutate] -- the gate's build-warning notice (NWP-20261120-03, Q098 in
# docs/product-decisions.md), run under javac.
#
# WHY THIS IS COMMITTED. The daemon caches a signed warning that names a bad build, and GET-BUILD-WARNING answers
# WARN. Without this, the gate showed nothing, so the next person signed in on the affected build unwarned. The rule
# lives in BuildWarningNotice, a pure class compiled here with its cases. Source pins check that
# ChooserActivity.refreshBuildWarningNotice asks the verb through DaemonSocket.roundTrip with a short bound on its own
# "nowhere-build-warning" thread (never sendDaemon's 90 s bound: a blocking daemon call cost IdleLogoffReceiver a 60 s
# ANR), that it asks BuildWarningNotice.due, that onResume and the ACTION_SCREEN_ON branch both call it (onResume does
# not re-fire on a wake, DIA-20260624-11), and that the screen-off path clears the dismissed flag for the next person.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-build-warning-notice-java.sh            # the cases + source pins
#   bash test-build-warning-notice-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
NOTICE="$SRC/BuildWarningNotice.java"
ACT="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/build-warning-notice/BuildWarningNoticeCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: this suite needs python3, and there is none" >&2; exit 2; }
[ -f "$NOTICE" ] && [ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $NOTICE, $ACT or $CASES" >&2; exit 2; }

cat >"$W/pins.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

def strip(t):
    # drop comments, keeping string literals (a "//" inside a string is not a comment)
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == '\\' else 1
            out.append(t[i:j + 1]); i = j + 1
        elif t.startswith("//", i):
            j = t.find("\n", i); i = n if j < 0 else j
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return "".join(out)

def close(t, o):
    # index of the brace that closes the one at o, skipping string literals
    d, i, n = 0, o, len(t)
    while i < n:
        c = t[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == '\\' else 1
            i = j + 1; continue
        if c == '{': d += 1
        elif c == '}':
            d -= 1
            if d == 0: return i
        i += 1
    return -1

def block(t, head):
    a = t.find(head)
    if a < 0: return None
    o = t.find("{", a + len(head) - 1 if head.endswith("{") else a)
    if o < 0: return None
    c = close(t, o)
    return None if c < 0 else (a, c + 1)

s = strip(src)
fails = []
def ok(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond: fails.append(what)

CALL = re.compile(r"(?<![\w.])refreshBuildWarningNotice\(\);")

# P1/P2: the reader
rb = block(s, "private void refreshBuildWarningNotice()")
if rb is None:
    ok(False, "refreshBuildWarningNotice's body is found")
else:
    b = s[rb[0]:rb[1]]
    rt = re.search(r'DaemonSocket\.roundTrip\("GET-BUILD-WARNING\\n",\s*([0-9_]+)\s*\)', b)
    ok(rt is not None, 'it sends GET-BUILD-WARNING through DaemonSocket.roundTrip')
    if rt is not None:
        bound = int(rt.group(1).replace("_", ""))
        ok(0 < bound <= 10000, "the read bound is at most 10000 ms (got %d)" % bound)
        th = b.find("new Thread(")
        name = b.find('"nowhere-build-warning"')
        ui = b.find("runOnUiThread(")
        ok(0 <= th < rt.start() < name and (ui < 0 or ui > rt.start()),
           'the read runs inside the "nowhere-build-warning" thread, before runOnUiThread')
    ok("sendDaemon(" not in b, "it never reads through sendDaemon")
    ok(b.count("roundTrip(") == 1, "it makes exactly one daemon read")
    ok(re.search(r"BuildWarningNotice\.due\(reply,\s*showing,\s*buildWarningDismissed,", b) is not None,
       "it asks BuildWarningNotice.due with the reply, showing and buildWarningDismissed")
    ok("buildWarningDialog != null && buildWarningDialog.isShowing()" in b, "showing reads the dialog field")
    for t in ("setCancelable(false)", "BuildWarningNotice.TITLE", "BuildWarningNotice.TEXT",
              "BuildWarningNotice.BUTTON", "buildWarningDismissed = true"):
        ok(t in b, "the notice holds " + t)
    g = re.search(r"if \(sOwnerSession \|\| switchingIn\) return;", b)
    ok(g is not None and g.start() < b.find("new Thread("), "it stands down for an owner session or a switch-in")
ok(s.count("private boolean buildWarningDismissed;") == 1, "buildWarningDismissed is an instance field")

# P3: onResume
ob = block(s, "protected void onResume()")
if ob is None:
    ok(False, "onResume's body is found")
else:
    o = s[ob[0]:ob[1]]
    ok("refreshCreditLostNotice();" in o, "control: onResume holds refreshCreditLostNotice()")
    rx = block(o, "screenOffRx = new android.content.BroadcastReceiver()")
    outside = o if rx is None else o[:rx[0]] + o[rx[1]:]
    ok(len(CALL.findall(outside)) == 1, "onResume calls refreshBuildWarningNotice() once, outside the receiver")

# P4/P5: the screen-off receiver
rb2 = block(s, "screenOffRx = new android.content.BroadcastReceiver()")
if rb2 is None:
    ok(False, "screenOffRx's receiver block is found")
else:
    r = s[rb2[0]:rb2[1]]
    on = block(r, "if (Intent.ACTION_SCREEN_ON.equals(i.getAction()))")
    if on is None:
        ok(False, "the receiver's ACTION_SCREEN_ON branch is found")
    else:
        br = r[on[0]:on[1]]
        ok("nudgeGateKeyboard();" in br, "control: the ACTION_SCREEN_ON branch holds nudgeGateKeyboard()")
        ok(re.search(r"if \(sLiveGate == ChooserActivity\.this\)\s*(\{\s*)?(nudgeGateKeyboard\(\);\s*)?refreshBuildWarningNotice\(\);", br)
           is not None, "the ACTION_SCREEN_ON branch calls refreshBuildWarningNotice() for the live gate only")
        off = r[on[1]:]
        c = off.find("clearSignInFields();")
        ok(c >= 0, "control: the screen-off path holds clearSignInFields()")
        th = off.find("new Thread(")
        d = off.find("buildWarningDismissed = false;")
        ok(c >= 0 and c < d < th, "the screen-off path clears buildWarningDismissed after clearSignInFields(), before its thread")
sys.exit(1 if fails else 0)
PY

# suite <BuildWarningNotice.java> <ChooserActivity.java> -> 0 pass, 1 a case or a pin failed, 3 did not compile
suite() {
  local notice="$1" act="$2" d rc=0
  d=$(mktemp -d -p "$W") || return 3
  "$JAVAC" -d "$d" "$notice" "$CASES" >"$d/javac.log" 2>&1 || { cat "$d/javac.log"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.BuildWarningNoticeCases || rc=1
  python3 "$W/pins.py" "$act" || rc=1
  return "$rc"
}

echo "== $NOTICE + $ACT"
suite "$NOTICE" "$ACT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "PASS"
[ "$MUTATE" = yes ] || exit 0

echo "== --mutate"
fails=0
mutant() { # mutant <label> <notice|act> <perl-expr>: the copy must FAIL its cases or pins (rc 1)
  local label="$1" which="$2" expr="$3" d n a rc f orig
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  mkdir -p "$d/src"; n="$d/src/BuildWarningNotice.java"; a="$d/src/ChooserActivity.java"
  cp "$NOTICE" "$n"; cp "$ACT" "$a"
  if [ "$which" = notice ]; then f="$n"; orig="$NOTICE"; else f="$a"; orig="$ACT"; fi
  if ! perl -0pi -e "$expr" "$f"; then echo "  ERROR     $label -- perl failed"; fails=$((fails+1)); return; fi
  if [ ! -s "$f" ] || cmp -s "$orig" "$f"; then echo "  INERT     $label -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  suite "$n" "$a" >"$d/out" 2>&1; rc=$?
  case "$rc" in
    1) echo "  convicted $label" ;;
    0) echo "  SURVIVED  $label"; fails=$((fails+1)) ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; tail -5 "$d/out"; fails=$((fails+1)) ;;
  esac
}
mutant "N1 due() ignores dismissed" notice 's/ && !dismissed//'
mutant "N2 due() accepts any non-empty reply" notice 's/reply != null && "WARN"\.equals\(reply\.trim\(\)\)/reply != null \&\& !reply.trim().isEmpty()/'
mutant "N3 the read moved to sendDaemon" act 's/DaemonSocket\.roundTrip\("GET-BUILD-WARNING\\n", 5000\)/sendDaemon("GET-BUILD-WARNING\\n")/'
mutant "N4 the screen-off clear removed" act 's/\n[ \t]*buildWarningDismissed = false;[^\n]*//'
mutant "N5 the onResume call removed" act 's/\n[ \t]*refreshBuildWarningNotice\(\); \/\/ NWP-20261120-03[^\n]*//'
mutant "N6 the screen-on call removed" act 's/\n[ \t]*if \(sLiveGate == ChooserActivity\.this\) refreshBuildWarningNotice\(\);//'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
