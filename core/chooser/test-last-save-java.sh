#!/usr/bin/env bash
# test-last-save-java.sh [--mutate] -- the h58 #1 last-save line's chooser half, run under javac (NWP-20261205-02).
#
# WHY THIS IS COMMITTED. Backlog row "The scopes advance INDEPENDENTLY with no consistency rule, so a partial seal
# leaves the stored profile internally skewed". The decision (docs/product-decisions.md 2026-11-04, h58 #1): a restore
# whose last seal round left a scope unsaved says so, in a login.log line and in one line the user sees at sign-in,
# beside the Auto sweep's card: "Your last save did not finish; some of your data is from an earlier save." The agent
# writes the round's verdict (NWP-20261204-01) and the gate verb GET-LASTSAVE serves it (harvest 66's M06 task). This
# suite covers the chooser card that asks for it and shows the line.
#
# WHAT RUNS. LastSaveCopy (pure, java.* only) is compiled with core/chooser/tests/last-save/LastSaveCases ALONE and
# run: C1 LINE is the h58 #1 sentence that THIS SUITE READS from docs/product-decisions.md; C2 a LASTSAVE line (the
# fixture and a five-scope list) reads as unsaved; C3 NONE, ERR, "", null, v=2, a missing or zero t, an unknown or
# repeated scope, a 6-item list, a bad cause and double spaces read as nothing to show; C4 show() is once per user
# serial. P6 runs TestDaemonVerbs on the real tree as a control (the new sender is known and its verb awaits an arm).
# WHAT IS PINNED BY ANCHOR (the chooser cannot be compiled off the build host; comments are stripped first):
#   P1 UnarchiveService.onStartCommand starts LastSaveNoticeActivity.check on its own daemon thread, with the
#      application context, the landing serial and the last-save-line-shown stamp, only on the switch-landing path:
#      after the netRekick block (which returns) and inside if (!byHand).
#   P2 check() writes the stamp (StoreInstaller.writeAtomic) before it calls startActivity.
#   P3 the manifest's LastSaveNoticeActivity entry is exported="false", excluded from recents, a dialog.
#   P4 the card shows LastSaveCopy.LINE and LandingLine.GOT_IT and no other literal text.
#   P5 the activity's one DaemonSocket call is roundTrip with the literal "GET-LASTSAVE\n".
# The merger's full javac / `m NowhereChooser` covers LastSaveNoticeActivity and UnarchiveService themselves.
#
# What this does NOT prove: the lynx run (fail the #de leg of one periodic seal, power off, sign in: the line shows
# once; a cold-lock resume does not show it again) stays on the backlog row.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC OR GO, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-last-save-java.sh            # the cases, the pins and the control
#   bash test-last-save-java.sh --mutate   # ... plus mutants S1-S8 that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
COPY="$SRC/LastSaveCopy.java"
ACT="$SRC/LastSaveNoticeActivity.java"
SVC="$SRC/UnarchiveService.java"
MAN="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/last-save/LastSaveCases.java"
DOC="$root/docs/product-decisions.md"
AGENT="$root/core/agent"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "test-last-save-java: FAIL -- no javac/java on PATH or in $HOST_JDK; this suite did NOT run" >&2
  exit 2
fi
command -v go >/dev/null 2>&1 || { echo "test-last-save-java: FAIL -- no go on PATH; this suite did NOT run" >&2; exit 2; }
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /'

missing=0
for f in "$COPY" "$ACT" "$SVC" "$MAN" "$CASES" "$DOC" "$AGENT/daemon_verbs_test.go"; do
  [ -f "$f" ] || { echo "test-last-save-java: FAIL -- $f is missing"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

# The h58 #1 sentence, read from the decision itself.
SENT="$W/sentence.txt"
python3 -I - "$DOC" "$SENT" <<'PY'
import io, re, sys
doc = io.open(sys.argv[1], encoding='utf-8').read()
head = '## 2026-11-04 — DECIDED: two answers to harvest 58'
if doc.count(head) != 1:
    print("EXTRACTION FAILED: the h58 entry heading occurs %d times" % doc.count(head)); sys.exit(1)
sec = doc[doc.index(head):]
nxt = sec.find('\n## ', 1)
sec = sec if nxt < 0 else sec[:nxt]
m = re.search(r'^- \*\*#1 — (.*)$', sec, re.M)
if not m:
    print("EXTRACTION FAILED: no item #1 in the h58 entry"); sys.exit(1)
w = re.findall(r'\*"(Your last save did not finish[^"]*)"\*', m.group(1))
if len(w) != 1:
    print("EXTRACTION FAILED: h58 #1 quotes the sentence %d times, want 1" % len(w)); sys.exit(1)
io.open(sys.argv[2], 'w', encoding='utf-8').write(w[0] + '\n')
PY
[ $? -eq 0 ] || { echo "test-last-save-java: FAIL -- the h58 #1 sentence"; exit 1; }
echo "ok the h58 #1 sentence read from docs/product-decisions.md"

# cases <LastSaveCopy.java> [quiet]: 0 pass, 1 a case failed, 3 did not compile.
cases() {
  local src=$1 quiet=${2:-} d out rc=0
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src" "$d/out"
  cp "$src" "$d/src/LastSaveCopy.java"
  cp "$CASES" "$d/src/LastSaveCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d/src/LastSaveCopy.java" \
      "$d/src/LastSaveCases.java" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.LastSaveCases \
    "$SENT" 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pin <P1..P5> <file>: 0 the pin holds, 1 it does not, 2 could not extract.
pin() {
  python3 -I - "$1" "$2" <<'PY'
import io, re, sys
which, path = sys.argv[1], sys.argv[2]
raw = io.open(path, encoding='utf-8').read()

def fail(why):
    print("FAIL %s: %s" % (which, why)); sys.exit(1)

if which == 'P3':
    xml = re.sub(r'<!--.*?-->', '', raw, flags=re.S)
    els = [e for e in re.findall(r'<activity\b[^>]*>', xml) if re.search(r'android:name="\.LastSaveNoticeActivity"', e)]
    if len(els) != 1: fail("the LastSaveNoticeActivity entry occurs %d times, want 1" % len(els))
    e = els[0]
    if 'android:exported="false"' not in e: fail("the entry is not exported=\"false\"")
    if 'android:excludeFromRecents="true"' not in e: fail("the entry is not excluded from recents")
    if 'android:theme="@android:style/Theme.Material.Dialog.NoActionBar"' not in e: fail("the entry is not the Dialog.NoActionBar theme")
    print("PASS P3 the manifest entry is not exported, excluded from recents, a dialog")
    sys.exit(0)

def strip(s):
    """Drop // and /* */ comments; keep string and char literals."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        elif s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def mask(s):
    """Blank the inside of every string and char literal, so braces in text never count. Same length."""
    out, i, n = list(s), 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            for k in range(i + 1, min(j, n)): out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)

src = strip(raw)
m = mask(src)

def close_of(o):
    """Index of the } that closes the { at o."""
    d = 0
    for k in range(o, len(m)):
        if m[k] == '{': d += 1
        elif m[k] == '}':
            d -= 1
            if d == 0: return k
    print("EXTRACTION FAILED: unbalanced braces"); sys.exit(2)

def header(o):
    """The text before the { at o, back to the previous ; { or }."""
    k = o - 1
    while k >= 0 and m[k] not in ';{}': k -= 1
    return ' '.join(src[k + 1:o].split())

def body(sig):
    """[open, close] of the one method whose 4-space-indent declaration matches sig."""
    hits = [x for x in re.finditer(sig, m, re.M)]
    if len(hits) != 1:
        print("EXTRACTION FAILED: %r matches %d times" % (sig, len(hits))); sys.exit(2)
    o = m.index('{', hits[0].end() - 1)
    return o, close_of(o)

def literals(s):
    """Every string literal in s, with its quotes."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            if c == '"': out.append(s[i:j + 1])
            i = j + 1
        else:
            i += 1
    return out

if which == 'P1':
    calls = [x.start() for x in re.finditer(r'LastSaveNoticeActivity\.check\(', m)]
    if len(calls) != 1: fail("LastSaveNoticeActivity.check( occurs %d times, want 1" % len(calls))
    c = calls[0]
    so, sc = body(r'^    public int onStartCommand\(')
    if not (so < c < sc): fail("the check is not started inside onStartCommand")
    nr = re.search(r'if \(netRekick\) \{', m[so:sc])
    if not nr: fail("no if (netRekick) { block in onStartCommand")
    no = so + nr.end() - 1
    nc = close_of(no)
    if not re.search(r'\breturn;', m[no:nc]): fail("the netRekick block does not return")
    if c < nc: fail("the check is started before the netRekick block returns")
    # Walk out of the braces around the call; the first if (...) met must be if (!byHand).
    opens, d = [], 0
    for k in range(c, so, -1):
        if m[k] == '}': d += 1
        elif m[k] == '{':
            if d == 0: opens.append(k)
            else: d -= 1
    guard = None
    for o in opens:
        h = header(o)
        if h.startswith('if'):
            guard = (o, h); break
    if guard is None: fail("no if (...) encloses the check")
    if guard[1] != 'if (!byHand)': fail("the first if around the check is %r, want 'if (!byHand)'" % guard[1])
    blk = src[guard[0]:close_of(guard[0]) + 1]
    if not re.search(r'new Thread\(\(\) -> LastSaveNoticeActivity\.check\(', blk): fail("the check does not run on its own new Thread")
    if '"nowhere-last-save"' not in blk: fail("the thread is not named nowhere-last-save")
    if not re.search(r'\bls\.setDaemon\(true\);', blk): fail("the check's thread is not a daemon thread")
    for need in ('getApplicationContext()', 'landingSerial()', '"last-save-line-shown"', 'getNoBackupFilesDir()'):
        if need not in blk: fail("the start does not use %s" % need)
    print("PASS P1 the check starts on its own daemon thread, on the switch-landing path only (after the netRekick return, inside if (!byHand))")
elif which == 'P2':
    co, ce = body(r'^    static void check\(Context app, String serial, File stamp\)')
    cb = m[co:ce]
    w = cb.find('StoreInstaller.writeAtomic(stamp, serial)')
    s = cb.find('startActivity(')
    if w < 0: fail("check() does not write the stamp")
    if s < 0: fail("check() does not start the card")
    if cb.count('startActivity(') != 1: fail("check() starts the card more than once")
    if not w < s: fail("check() starts the card before it writes the stamp")
    if 'FLAG_ACTIVITY_NEW_TASK' not in cb: fail("the card is not started with FLAG_ACTIVITY_NEW_TASK")
    if 'LastSaveCopy.show(LastSaveCopy.unsaved(r), readStamp(stamp), serial)' not in src[co:ce]: fail("check() does not decide with LastSaveCopy.show(unsaved(r), stamp, serial)")
    print("PASS P2 check() writes the stamp before it starts the card")
elif which == 'P4':
    st = re.findall(r'\.setText\(([^;]*)\);', src)
    if sorted(st) != ['LandingLine.GOT_IT', 'LastSaveCopy.LINE']: fail("setText( arguments are %r, want LastSaveCopy.LINE and LandingLine.GOT_IT" % st)
    if re.search(r'\bsetTitle\(', src): fail("the card sets a title")
    bad = [l for l in literals(src) if l not in ('"GET-LASTSAVE\\n"', '"NowhereChooser"') and not l.startswith('"last save line')]
    if bad: fail("literal text other than the verb, the log tag and the log lines: %r" % bad)
    if 'setFinishOnTouchOutside(true)' not in src: fail("a tap outside does not close the card")
    if 'Gravity.TOP' not in src: fail("the card is not at the top of the screen")
    print("PASS P4 the card shows LastSaveCopy.LINE and LandingLine.GOT_IT and no other literal text, at the top")
elif which == 'P5':
    ds = [x.start() for x in re.finditer(r'DaemonSocket\.', src)]
    if len(ds) != 1: fail("DaemonSocket. occurs %d times, want 1" % len(ds))
    if not src.startswith('DaemonSocket.roundTrip("GET-LASTSAVE\\n", ', ds[0]): fail("the one DaemonSocket call is not roundTrip with the literal \"GET-LASTSAVE\\n\"")
    print("PASS P5 the one DaemonSocket call is roundTrip(\"GET-LASTSAVE\\n\", ...)")
else:
    print("EXTRACTION FAILED: no pin %s" % which); sys.exit(2)
PY
}

# verbs [<overlay.json>]: run TestDaemonVerbs on the real tree. 0 pass, 1 the test failed, 3 it did not build or run.
verbs() {
  local ov=${1:-} out rc=0
  if [ -n "$ov" ]; then
    out=$(cd "$AGENT" && env -u NOWHERE_VERBS_AGENT_DIR -u NOWHERE_VERBS_CHOOSER_SRC GOTMPDIR="$W" \
      go test -count=1 -overlay "$ov" -run '^TestDaemonVerbs$' . 2>&1) || rc=$?
  else
    out=$(cd "$AGENT" && env -u NOWHERE_VERBS_AGENT_DIR -u NOWHERE_VERBS_CHOOSER_SRC GOTMPDIR="$W" \
      go test -count=1 -run '^TestDaemonVerbs$' . 2>&1) || rc=$?
  fi
  [ "$rc" -eq 0 ] && return 0
  [[ $out == *"--- FAIL: TestDaemonVerbs"* ]] && return 1
  printf '%s\n' "$out" | tail -20
  return 3
}

fails=0
if cases "$COPY"; then echo "PASS cases C1-C4"; else echo "FAIL cases"; fails=$((fails + 1)); fi
pin P1 "$SVC" || fails=$((fails + 1))
pin P2 "$ACT" || fails=$((fails + 1))
pin P3 "$MAN" || fails=$((fails + 1))
pin P4 "$ACT" || fails=$((fails + 1))
pin P5 "$ACT" || fails=$((fails + 1))
if verbs; then echo "PASS P6 TestDaemonVerbs knows the new sender and its verb"
else echo "FAIL P6 TestDaemonVerbs on the real tree"; fails=$((fails + 1)); fi
if [ "$fails" -ne 0 ]; then echo "test-last-save-java: FAIL ($fails check(s))"; exit 1; fi
echo "test-last-save-java: PASS"
[ "$MUTATE" = yes ] || exit 0

# --mutate: each mutant edits a COPY of one file and must make its check fail. A mutant that does not apply fails.
MFAILS=0
# mutate <Sn> <file> <out>: apply mutant Sn to <file>, write <out>; non-zero when it did not apply.
mutate() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, sys
mid, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(src, encoding='utf-8').read()
def rep(t, old, new):
    if t.count(old) != 1:
        print("MUTANT %s DID NOT APPLY: %r occurs %d times" % (mid, old, t.count(old))); sys.exit(1)
    return t.replace(old, new)
if mid == 'S1':
    t = rep(s, 'some of your data is from an earlier save."', 'some of your data is from an older save."')
elif mid == 'S2':
    sig = '    static boolean unsaved(String reply) {\n'
    t = rep(s, sig, sig + '        if (reply != null && reply.startsWith("LASTSAVE ")) return true;\n')
elif mid == 'S3':
    t = rep(s, '"sys", "apps");', '"sys", "apps", "keys");')
elif mid == 'S4':
    t = rep(s, 'return unsaved && serial != null && !serial.equals(stamp);', 'return unsaved && serial != null;')
elif mid == 'S5':
    a = s.find('                    // NWP-20261205-02 (h58 #1)')
    end = '"last save line start", t); }\n'
    e = s.find(end, a)
    if a < 0 or e < 0:
        print("MUTANT S5 DID NOT APPLY: the last save block not found"); sys.exit(1)
    e += len(end)
    blk = s[a:e]
    g = s.rfind('                if (!byHand) {\n', 0, a)
    if g < 0:
        print("MUTANT S5 DID NOT APPLY: no if (!byHand) { before the block"); sys.exit(1)
    t = s[:g] + blk + s[g:a] + s[e:]
elif mid == 'S6':
    w = '''        try {
            StoreInstaller.writeAtomic(stamp, serial);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "last save line: stamp not written", t);
            return;
        }
'''
    st = '''        try {
            app.startActivity(new Intent(app, LastSaveNoticeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            android.util.Log.i("NowhereChooser", "last save line: showing");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "last save line: card not started", t);
        }
'''
    t = rep(s, w + st, st + w)
elif mid == 'S7':
    t = rep(s, '<activity android:name=".LastSaveNoticeActivity" android:exported="false"',
            '<activity android:name=".LastSaveNoticeActivity" android:exported="true"')
elif mid == 'S8':
    t = rep(s, '"LastSaveNoticeActivity.java": true, ', '')
else:
    print("no mutant %s" % mid); sys.exit(2)
if t == s:
    print("MUTANT %s DID NOT APPLY: no change" % mid); sys.exit(1)
io.open(dst, 'w', encoding='utf-8').write(t)
PY
}

# convict <Sn> <cases|P1..P5|verbs> <file> <what>
convict() {
  local id=$1 check=$2 file=$3 what=$4 d dst ov rc
  d=$(mktemp -d -p "$W") || { echo "FAIL $id: no temp"; MFAILS=$((MFAILS + 1)); return; }
  dst="$d/$(basename "$file")"
  if ! mutate "$id" "$file" "$dst"; then echo "FAIL $id ($what): the mutant did not apply"; MFAILS=$((MFAILS + 1)); rm -rf "$d"; return; fi
  if [ "$check" = cases ]; then
    cases "$dst" quiet; rc=$?
  elif [ "$check" = verbs ]; then
    # The mutated test file replaces the real one through -overlay: the source tree is never edited.
    ov="$d/overlay.json"
    printf '{"Replace":{"%s":"%s"}}\n' "$file" "$dst" >"$ov"
    verbs "$ov"; rc=$?
  else
    pin "$check" "$dst" >/dev/null; rc=$?
  fi
  if [ "$rc" -eq 1 ]; then echo "CONVICTED $id by $check ($what)"
  elif [ "$rc" -eq 0 ]; then echo "SURVIVED $id ($what)"; MFAILS=$((MFAILS + 1))
  else echo "FAIL $id ($what): the check could not run (rc $rc)"; MFAILS=$((MFAILS + 1)); fi
  rm -rf "$d"
}

convict S1 cases "$COPY" "LINE altered by one word (C1)"
convict S2 cases "$COPY" "unsaved() accepts any LASTSAVE prefix (C3)"
convict S3 cases "$COPY" "the scope set gains a word (C3)"
convict S4 cases "$COPY" "show() ignores the stamp (C4)"
convict S5 P1 "$SVC" "the start moved out of if (!byHand)"
convict S6 P2 "$ACT" "startActivity before the stamp write"
convict S7 P3 "$MAN" "the entry exported=\"true\""
convict S8 verbs "$AGENT/daemon_verbs_test.go" "the senderFiles entry removed (TestDaemonVerbs)"

if [ "$MFAILS" -ne 0 ]; then echo "FAIL: $MFAILS mutant check(s) failed"; exit 1; fi
echo "OK: all 8 mutants convicted"
