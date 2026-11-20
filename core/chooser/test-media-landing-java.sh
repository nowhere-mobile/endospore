#!/usr/bin/env bash
# test-media-landing-java.sh [--mutate] -- the media half of the landing line, run under javac (NWP-20261207-12).
#
# WHY THIS IS COMMITTED. Backlog row "A 179-second login, 95% of it bulk media restored INLINE before the gate opens",
# Q106 slice S6 (docs/media-after-gate.md §8 row S6), the decision of 2026-11-02, O3: the landing line mentions media
# only for a large set, over 200 files or 50 MB; a smaller set shows only the notification. A sign-in whose background
# set is large says so once: a sentence in the Auto sweep's card when it is open, else a one-line card with Got it.
# The words are drafts (MediaLanding's javadoc).
#
# WHAT RUNS. MediaLanding (pure, java.* only) is compiled with MediaStatus, LandingLine, AppDeps and
# core/chooser/tests/media-landing/MediaLandingCases and run: C1-C5 large() at 201 / 200 files, 50 MiB + 1 byte /
# exactly 50 MiB / 50 MB of 1000, null and a short array; C6 show() once per user serial (a cold-lock resume is the
# same serial); C7 the words; C8 LandingLine.Sweep.open(); C9 the process-static record; C10 a daemon reply end to
# end through MediaStatus.route and restoring; C11 the constants; C12 firstRestoring's 30-second deadline on a
# simulated clock (a timely reply is read; no ask starts at or after 30 s; a reply that arrives after 30 s is
# discarded; each ask and sleep is bounded by the time left; an interrupt ends the wait).
# WHAT IS PINNED BY ANCHOR (the chooser cannot be compiled off the build host; comments are stripped first):
#   P1 UnarchiveService starts MediaLandingNoticeActivity.check on its own daemon thread, with the application
#      context, the landing serial and the media-landing-shown stamp, inside if (!byHand), once.
#   P2 check() writes the stamp before it marks the record, before sendBroadcast and before startActivity; it marks
#      the record once, only in the Sweep.open() arm and before the broadcast; the else arm starts the card. And
#      (NWP-20261119-37) it waits once, LandingQueue.awaitDecided(LandingQueue.DECIDE_MS), after the stamp and before
#      the open() branch, so a card the sweep begins after the media read still takes the sentence.
#   P3 the manifest's MediaLandingNoticeActivity entry is exported="false", excluded from recents, a dialog.
#   P4 LandingNoticeActivity adds ACTION_MEDIA to the filter before its one RECEIVER_NOT_EXPORTED registration, its
#      receiver and sync() show the sentence, which reads the record and starts hidden.
#   P5 the activity's one DaemonSocket call is roundTripLines("GET-MEDIA-STATUS\n", (int) cap) inside check()'s
#      MediaLanding.firstRestoring ask, read through MediaStatus slot 3, with the elapsed-realtime clock; check()
#      decides with MediaLanding.large and show.
#   P6 the alone card shows MediaLanding.ALONE and LandingLine.GOT_IT only, at the bottom, closed by a tap outside.
#   P7 the ACTION_MEDIA broadcast is package-local.
#   P8 no log line of the activity carries a variable in its message.
# The merger's full javac / `m NowhereChooser` covers MediaLandingNoticeActivity, LandingNoticeActivity and
# UnarchiveService themselves.
#
# What this does NOT prove: the handset check (a sign-in of a photo-heavy profile shows the sentence once, a small set
# does not) is S7's.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-media-landing-java.sh            # the cases and the pins
#   bash test-media-landing-java.sh --mutate   # ... plus mutants X1-X18 that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
ML="$SRC/MediaLanding.java"
MS="$SRC/MediaStatus.java"
LL="$SRC/LandingLine.java"
AD="$SRC/AppDeps.java"
ACT="$SRC/MediaLandingNoticeActivity.java"
LA="$SRC/LandingNoticeActivity.java"
SVC="$SRC/UnarchiveService.java"
MAN="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/media-landing/MediaLandingCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "test-media-landing-java: FAIL -- no javac/java on PATH or in $HOST_JDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /'

missing=0
for f in "$ML" "$MS" "$LL" "$AD" "$ACT" "$LA" "$SVC" "$MAN" "$CASES"; do
  [ -f "$f" ] || { echo "test-media-landing-java: FAIL -- $f is missing"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

# cases <MediaLanding.java> <LandingLine.java> [quiet]: 0 pass, 1 a case failed, 3 did not compile.
cases() {
  local ml=$1 ll=$2 quiet=${3:-} d out rc=0
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src" "$d/out"
  cp "$ml" "$d/src/MediaLanding.java"
  cp "$ll" "$d/src/LandingLine.java"
  cp "$MS" "$d/src/MediaStatus.java"
  cp "$AD" "$d/src/AppDeps.java"
  cp "$CASES" "$d/src/MediaLandingCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/*.java 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.MediaLandingCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pin <P1..P8> <file>: 0 the pin holds, 1 it does not, 2 could not extract.
pin() {
  python3 -I - "$1" "$2" <<'PY'
import io, re, sys
which, path = sys.argv[1], sys.argv[2]
raw = io.open(path, encoding='utf-8').read()

def fail(why):
    print("FAIL %s: %s" % (which, why)); sys.exit(1)

if which == 'P3':
    xml = re.sub(r'<!--.*?-->', '', raw, flags=re.S)
    els = [e for e in re.findall(r'<activity\b[^>]*>', xml) if re.search(r'android:name="\.MediaLandingNoticeActivity"', e)]
    if len(els) != 1: fail("the MediaLandingNoticeActivity entry occurs %d times, want 1" % len(els))
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
    """[open, close] of the one method whose declaration matches sig."""
    hits = [x for x in re.finditer(sig, m, re.M)]
    if len(hits) != 1:
        print("EXTRACTION FAILED: %r matches %d times" % (sig, len(hits))); sys.exit(2)
    o = m.index('{', hits[0].end() - 1)
    return o, close_of(o)

def literals(s):
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
    calls = [x.start() for x in re.finditer(r'MediaLandingNoticeActivity\.check\(', m)]
    if len(calls) != 1: fail("MediaLandingNoticeActivity.check( occurs %d times, want 1" % len(calls))
    c = calls[0]
    so, sc = body(r'^    public int onStartCommand\(')
    if not (so < c < sc): fail("the check is not started inside onStartCommand")
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
    # The try block that holds the start.
    t = [o for o in opens if header(o) == 'try']
    if not t: fail("the start is not inside a try")
    blk = src[t[0]:close_of(t[0]) + 1]
    if not re.search(r'new Thread\(\(\) -> MediaLandingNoticeActivity\.check\(mlCtx, mlSerial, mlStamp\), "nowhere-media-landing"\)', blk):
        fail("the check does not run on its own new Thread named nowhere-media-landing")
    if not re.search(r'\bml\.setDaemon\(true\);\s*ml\.start\(\);', blk): fail("the check's thread is not a started daemon thread")
    for need in ('getApplicationContext()', 'landingSerial()', '"media-landing-shown"', 'getNoBackupFilesDir()'):
        if need not in blk: fail("the start does not use %s" % need)
    print("PASS P1 the check starts once, on its own daemon thread, inside if (!byHand)")
elif which == 'P2':
    co, ce = body(r'^    static void check\(Context app, String serial, File stamp\)')
    cb = m[co:ce]
    w = cb.find('StoreInstaller.writeAtomic(stamp, serial)')
    if w < 0 or cb.count('StoreInstaller.writeAtomic(') != 1: fail("check() does not write the stamp exactly once")
    op = re.search(r'if \(LandingLine\.Sweep\.open\(\)\) \{', cb)
    if not op: fail("check() has no if (LandingLine.Sweep.open()) { branch")
    to = op.end() - 1
    tc = close_of(co + to) - co
    el = re.match(r'\s*else\s*\{', cb[tc + 1:])
    if not el: fail("the open() branch has no else arm")
    eo = tc + 1 + el.end() - 1
    ec = close_of(co + eo) - co
    true_arm, else_arm = cb[to:tc], cb[eo:ec]
    marks = [x.start() for x in re.finditer(r'MediaLanding\.mark\(', m)]
    if len(marks) != 1: fail("MediaLanding.mark( occurs %d times in the file, want 1" % len(marks))
    mk = marks[0] - co
    if not (to < mk < tc): fail("MediaLanding.mark is not inside the Sweep.open() arm")
    if 'MediaLanding.mark(serial)' not in true_arm: fail("the open() arm does not mark this sign-in's serial")
    if 'mark(' in else_arm: fail("the else arm marks the record")
    sb = cb.find('app.sendBroadcast(')
    sa = cb.find('app.startActivity(')
    if sb < 0 or not (to < sb < tc): fail("app.sendBroadcast( is not in the open() arm")
    if sa < 0 or not (eo < sa < ec): fail("app.startActivity( is not in the else arm")
    if cb.count('app.sendBroadcast(') != 1 or cb.count('app.startActivity(') != 1: fail("check() sends or starts more than once")
    if not w < mk: fail("check() marks the record before it writes the stamp")
    if not w < sb: fail("check() broadcasts before it writes the stamp")
    if not w < sa: fail("check() starts the card before it writes the stamp")
    if not mk < sb: fail("check() broadcasts before it marks the record")
    if 'FLAG_ACTIVITY_NEW_TASK' not in else_arm: fail("the card is not started with FLAG_ACTIVITY_NEW_TASK")
    aw = cb.find('LandingQueue.awaitDecided(LandingQueue.DECIDE_MS);')
    if cb.count('LandingQueue.awaitDecided(') != 1 or aw < 0:
        fail("check() does not wait once for the card decision with LandingQueue.awaitDecided(LandingQueue.DECIDE_MS)")
    if not (w < aw < op.start()): fail("check() does not wait for the card decision after the stamp and before the open() branch")
    print("PASS P2 check() writes the stamp first, marks the record only in the open() arm before its broadcast, and starts the card in the else arm")
elif which == 'P4':
    if not re.search(r'static final String ACTION_MEDIA = "com\.nowhere\.chooser\.action\.LANDING_MEDIA";', src):
        fail("ACTION_MEDIA is not com.nowhere.chooser.action.LANDING_MEDIA")
    regs = [x.start() for x in re.finditer(r'registerReceiver\(receiver, f, Context\.RECEIVER_NOT_EXPORTED\);', m)]
    if len(regs) != 1: fail("registerReceiver(receiver, f, RECEIVER_NOT_EXPORTED) occurs %d times, want 1" % len(regs))
    adds = [x.start() for x in re.finditer(r'\bf\.addAction\(ACTION_MEDIA\);', m)]
    if len(adds) != 1: fail("f.addAction(ACTION_MEDIA); occurs %d times, want 1" % len(adds))
    if not adds[0] < regs[0]: fail("ACTION_MEDIA is added after the receiver is registered")
    if 'if (ACTION_MEDIA.equals(a)) showMedia();' not in src: fail("the receiver does not show the sentence on ACTION_MEDIA")
    yo, yc = body(r'^    private void sync\(\)')
    if not re.search(r'\bshowMedia\(\);', src[yo:yc]): fail("sync() does not call showMedia()")
    ho, hc = body(r'^    private void showMedia\(\)')
    if 'MediaLanding.shownFor(' not in src[ho:hc]: fail("showMedia() does not read MediaLanding.shownFor")
    ao, ac = body(r'^    private void addMediaLine\(LinearLayout card\)')
    ab = src[ao:ac]
    if 'setText(MediaLanding.IN_CARD)' not in ab: fail("the media line is not MediaLanding.IN_CARD")
    if 'setVisibility(View.GONE)' not in ab: fail("the media line does not start hidden")
    if len(re.findall(r'\baddMediaLine\(card\);', m)) != 2: fail("addMediaLine(card) is not called in both layouts")
    print("PASS P4 ACTION_MEDIA is in the filter before the one RECEIVER_NOT_EXPORTED registration; the receiver and sync() show the hidden IN_CARD line from the record")
elif which == 'P5':
    ds = [x.start() for x in re.finditer(r'DaemonSocket\.', src)]
    if len(ds) != 1: fail("DaemonSocket. occurs %d times, want 1" % len(ds))
    if not src.startswith('DaemonSocket.roundTripLines("GET-MEDIA-STATUS\\n", ', ds[0]): fail("the one DaemonSocket call is not roundTripLines(\"GET-MEDIA-STATUS\\n\", ...)")
    co, ce = body(r'^    static void check\(Context app, String serial, File stamp\)')
    cb = ' '.join(src[co:ce].split())
    if not (co < ds[0] < ce): fail("the DaemonSocket call is not inside check()")
    ask = ('long[] r = MediaLanding.firstRestoring( cap -> MediaStatus.restoring(MediaStatus.route( '
           'DaemonSocket.roundTripLines("GET-MEDIA-STATUS\\n", (int) cap))[3]),')
    if ask not in cb: fail("check() does not read r from MediaLanding.firstRestoring asking GET-MEDIA-STATUS with its cap")
    for need in ('return android.os.SystemClock.elapsedRealtime();', 'Thread.sleep(ms);',
                 'MediaLanding.large(r)', 'MediaLanding.show(true, readStamp(stamp), serial)'):
        if need not in cb: fail("check() does not use %s" % need)
    if re.search(r'\bwhile\b|\bfor\b', m[co:ce]): fail("check() loops on its own, outside firstRestoring's deadline")
    print("PASS P5 the one DaemonSocket call is GET-MEDIA-STATUS inside MediaLanding.firstRestoring, decided by MediaStatus slot 3 and MediaLanding")
elif which == 'P6':
    st = re.findall(r'\.setText\(([^;]*)\);', src)
    if sorted(st) != ['LandingLine.GOT_IT', 'MediaLanding.ALONE']: fail("setText( arguments are %r, want MediaLanding.ALONE and LandingLine.GOT_IT" % st)
    if re.search(r'\bsetTitle\(', src): fail("the card sets a title")
    if 'wl.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;' not in src: fail("the card is not at the bottom of the screen")
    if 'setFinishOnTouchOutside(true)' not in src: fail("a tap outside does not close the card")
    print("PASS P6 the alone card shows MediaLanding.ALONE and LandingLine.GOT_IT, at the bottom, closed by a tap outside")
elif which == 'P7':
    if 'app.sendBroadcast(new Intent(LandingNoticeActivity.ACTION_MEDIA).setPackage(app.getPackageName()));' not in src:
        fail("the ACTION_MEDIA broadcast is not package-local")
    print("PASS P7 the ACTION_MEDIA broadcast is package-local")
elif which == 'P8':
    calls = re.findall(r'Log\.[iwed]\("NowhereChooser", ([^;]*)\);', src)
    if not calls: fail("no log line found")
    # A fixed text, then at most the Throwable. The look line keeps LastSaveNoticeActivity's shape (text + t).
    ok = re.compile(r'^"[^"\\]*"(, t)?$|^"media landing line look not read, dark: " \+ t$')
    bad = [c for c in calls if not ok.match(c)]
    if bad: fail("log lines carry a variable: %r" % bad)
    print("PASS P8 every log line of the activity is a fixed text (a Throwable may follow)")
else:
    print("EXTRACTION FAILED: no pin %s" % which); sys.exit(2)
PY
}

fails=0
if cases "$ML" "$LL"; then echo "PASS cases C1-C12"; else echo "FAIL cases"; fails=$((fails + 1)); fi
pin P1 "$SVC" || fails=$((fails + 1))
pin P2 "$ACT" || fails=$((fails + 1))
pin P3 "$MAN" || fails=$((fails + 1))
pin P4 "$LA" || fails=$((fails + 1))
pin P5 "$ACT" || fails=$((fails + 1))
pin P6 "$ACT" || fails=$((fails + 1))
pin P7 "$ACT" || fails=$((fails + 1))
pin P8 "$ACT" || fails=$((fails + 1))
if [ "$fails" -ne 0 ]; then echo "test-media-landing-java: FAIL ($fails check(s))"; exit 1; fi
echo "test-media-landing-java: PASS"
[ "$MUTATE" = yes ] || exit 0

# --mutate: each mutant edits a COPY of one file and must make its check fail. A mutant that does not apply fails.
MFAILS=0
# mutate <Xn> <file> <out>: apply mutant Xn to <file>, write <out>; non-zero when it did not apply.
mutate() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, re, sys
mid, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(src, encoding='utf-8').read()
def rep(t, old, new):
    if t.count(old) != 1:
        print("MUTANT %s DID NOT APPLY: %r occurs %d times" % (mid, old, t.count(old))); sys.exit(1)
    return t.replace(old, new)
MARK = '            MediaLanding.mark(serial);\n'
OPEN = '        if (LandingLine.Sweep.open()) {\n'
if mid == 'X1':
    t = rep(s, 'r[2] > FILES_OVER', 'r[2] >= FILES_OVER')
elif mid == 'X2':
    t = rep(s, '50L * 1024 * 1024', '50L * 1000 * 1000')
elif mid == 'X3':
    t = rep(s, 'return large && serial != null && !serial.equals(stamp);', 'return large && serial != null;')
elif mid == 'X4':
    w = '''        try {
            StoreInstaller.writeAtomic(stamp, serial);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "media landing line: stamp not written", t);
            return;
        }
'''
    t = rep(s, w, '')
    end = '                android.util.Log.w("NowhereChooser", "media landing line: card not started", t);\n            }\n        }\n'
    t = rep(t, end, end + w)
elif mid == 'X5':
    a = s.find('                    // NWP-20261207-12 (Q106 S6b, O3)')
    tail = '"media landing line start", t); }\n'
    e = s.find(tail, a)
    if a < 0 or e < 0:
        print("MUTANT X5 DID NOT APPLY: the media landing block not found"); sys.exit(1)
    e += len(tail)
    blk = s[a:e]
    g = s.rfind('                if (!byHand) {\n', 0, a)
    if g < 0:
        print("MUTANT X5 DID NOT APPLY: no if (!byHand) { before the block"); sys.exit(1)
    t = s[:g] + blk + s[g:a] + s[e:]
elif mid == 'X6':
    t = rep(s, '        f.addAction(ACTION_MEDIA);\n', '')
elif mid == 'X7':
    t = rep(s, 'return id != 0 && !done;', 'return id != 0;')
elif mid == 'X8':
    t = rep(s, 'r[1] > BYTES_OVER', 'r[0] > BYTES_OVER')
elif mid == 'X9':
    t = rep(s, MARK, '')
elif mid == 'X10':
    t = rep(s, 'new Intent(LandingNoticeActivity.ACTION_MEDIA).setPackage(app.getPackageName())',
            'new Intent(LandingNoticeActivity.ACTION_MEDIA)')
elif mid == 'X11':
    t = rep(s, '        if (LandingLine.Sweep.done(sweep)) closeSoon();\n        showMedia();\n',
            '        if (LandingLine.Sweep.done(sweep)) closeSoon();\n')
elif mid == 'X12':
    t = rep(s, 'Gravity.BOTTOM', 'Gravity.TOP')
elif mid == 'X13':
    t = rep(s, MARK, '')
    t = rep(t, OPEN, MARK.replace('            ', '        ', 1) + OPEN)
elif mid == 'X15':
    t = rep(s, '            left = end - clock.now();\n            if (left <= 0) return null;\n            if (r != null) return r;\n',
            '            if (r != null) return r;\n            left = end - clock.now();\n            if (left <= 0) return null;\n')
elif mid == 'X16':
    t = rep(s, '            long left = end - clock.now();\n            if (left <= 0) return null;\n',
            '            long left = end - clock.now();\n')
elif mid == 'X17':
    t = rep(s, 'clock.sleep(Math.min(STEP_MS, left));', 'clock.sleep(STEP_MS);')
elif mid == 'X18':
    t = rep(s, 'ask.restoring(Math.min(ASK_MS, left));', 'ask.restoring(ASK_MS);')
elif mid == 'X19':
    t = rep(s, '        LandingQueue.awaitDecided(LandingQueue.DECIDE_MS);\n', '')
elif mid == 'X14':
    t = rep(s, '        } else {\n            try {\n                app.startActivity(',
            '        } else {\n' + MARK + '            try {\n                app.startActivity(')
else:
    print("no mutant %s" % mid); sys.exit(2)
if t == s:
    print("MUTANT %s DID NOT APPLY: no change" % mid); sys.exit(1)
io.open(dst, 'w', encoding='utf-8').write(t)
PY
}

# convict <Xn> <cases|P1..P8> <file> <what>
convict() {
  local id=$1 check=$2 file=$3 what=$4 d dst rc
  d=$(mktemp -d -p "$W") || { echo "FAIL $id: no temp"; MFAILS=$((MFAILS + 1)); return; }
  dst="$d/$(basename "$file")"
  if ! mutate "$id" "$file" "$dst"; then echo "FAIL $id ($what): the mutant did not apply"; MFAILS=$((MFAILS + 1)); rm -rf "$d"; return; fi
  if [ "$check" = cases ]; then
    if [ "$file" = "$LL" ]; then cases "$ML" "$dst" quiet; rc=$?; else cases "$dst" "$LL" quiet; rc=$?; fi
  else
    pin "$check" "$dst" >/dev/null; rc=$?
  fi
  if [ "$rc" -eq 1 ]; then echo "CONVICTED $id by $check ($what)"
  elif [ "$rc" -eq 0 ]; then echo "SURVIVED $id ($what)"; MFAILS=$((MFAILS + 1))
  else echo "FAIL $id ($what): the check could not run or the mutant did not compile (rc $rc)"; MFAILS=$((MFAILS + 1)); fi
  rm -rf "$d"
}

convict X1 cases "$ML" ">= for files (C2 200 files)"
convict X2 cases "$ML" "the bytes threshold in MB of 1000 (C4, C11)"
convict X3 cases "$ML" "show() ignores the stamp (C6 same serial)"
convict X4 P2 "$ACT" "the stamp written after the start and the broadcast"
convict X5 P1 "$SVC" "the thread start moved out of if (!byHand)"
convict X6 P4 "$LA" "ACTION_MEDIA dropped from the filter"
convict X7 cases "$LL" "Sweep.open() ignores done (C8 closed after end)"
convict X8 cases "$ML" "large() reads done bytes for total (C3 done is not total)"
convict X9 P2 "$ACT" "the record never marked"
convict X10 P7 "$ACT" "the broadcast not package-local"
convict X11 P4 "$LA" "sync() never shows the sentence"
convict X12 P6 "$ACT" "the alone card at the top"
convict X13 P2 "$ACT" "the record marked before the open() branch"
convict X14 P2 "$ACT" "the record marked in the alone arm too"
convict X15 cases "$ML" "a RESTORING reply after the deadline accepted (C12 reply crosses the deadline)"
convict X16 cases "$ML" "no deadline check before an ask (C12 no ask after the deadline)"
convict X17 cases "$ML" "a sleep not bounded by the time left (C12 sleep bounded)"
convict X18 cases "$ML" "an ask not bounded by the time left (C12 ask bounded)"
convict X19 P2 "$ACT" "no wait for the card decision before the open() branch (NWP-20261119-37)"

if [ "$MFAILS" -ne 0 ]; then echo "FAIL: $MFAILS mutant check(s) failed"; exit 1; fi
echo "OK: all 19 mutants convicted"
