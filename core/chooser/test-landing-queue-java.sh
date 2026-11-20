#!/usr/bin/env bash
# test-landing-queue-java.sh [--mutate] -- the landing card's notice queue, run under javac (NWP-20261208-24).
#
# WHY THIS IS COMMITTED. Backlog row "Up to four separate pop-ups can land together right after sign-in: the Auto sweep
# card, the last-save notice, the passphrase-change skip notice and the Google Play setup card". UnarchiveService starts
# the last-save, skip-notice and Play checks on their own threads BEFORE sweepAuto decides its card, and nothing tied
# them together, so all four could open at once. The design (approved by Chester 2026-11-17, NWP-20261116-48): the
# one-line notices fold into the landing card as an amber line under its headline, in their existing words; the
# Google Play setup card shows only after the landing card closes; nothing else stacks. With no landing card the
# notices show alone, as before.
#
# WHAT RUNS. LandingQueue (pure, java.* only) is compiled with core/chooser/tests/landing-queue/LandingQueueCases ALONE
# and run with short times: C1 no decision within maxMs is ALONE; C2 decided(0) is ALONE at once; C3 an open card is
# CARD; C4 a card whose sweep is done holds place() until it is gone, then ALONE; C5 a gone card is ALONE; C6 a card
# never shown frees awaitGone after showMs; C6b a shown card holds it past showMs; C7 the first decision wins; C8 a
# report for another id is ignored; C9 the lines keep their order; C10 each skip time is taken once; C11 and C12 a
# shown or gone report that comes before the decision counts; C13 the decision releases a waiting place().
# WHAT IS PINNED BY ANCHOR (the chooser cannot be compiled off the build host; comments are stripped first):
#   N1 LastSaveNoticeActivity.check and SkipNoticeActivity.check each ask LandingQueue.place once, after the stamp write
#      (last save) or the parse's NONE return (skip notice), and start their own card only after the CARD arm, which
#      returns.
#   N2 each CARD arm adds its line (LastSaveCopy.LINE, 0 / SkipNoticeCopy.words(n.phone, when(n.time)), n.time) before
#      a package-local ACTION_NOTICE broadcast, and starts no card.
#   N3 PlayFinishActivity.check's SHOW arm waits (awaitDecided(DECIDE_MS), then awaitGone(SHOW_MS)) before it starts
#      the card; the SETTLE arm does not touch the queue.
#   N4 LandingNoticeActivity registers ACTION_NOTICE before its one registration and syncs on it; sync() takes the
#      skip times before it reads the lines, draws them in look.warn into the GONE notice box and marks each taken
#      time shown on its own thread; onCreate reports the card shown (after reading its sweep id), onDestroy reports it
#      gone only under isFinishing().
#   N5 UnarchiveService.sweepAuto calls LandingQueue.decided(card) after the landing card block and before PASS_CARD;
#      the landing arm's finally calls LandingQueue.decided(0) before workerDone().
# The merger's full javac / `m NowhereChooser` covers the activities and UnarchiveService themselves.
#
# What this does NOT prove: the lynx run (a sign-in that triggers all four shows them one after another, never
# stacked) stays on the backlog row.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-landing-queue-java.sh            # the cases and the pins
#   bash test-landing-queue-java.sh --mutate   # ... plus mutants M1-M16 that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
Q="$SRC/LandingQueue.java"
LS="$SRC/LastSaveNoticeActivity.java"
SK="$SRC/SkipNoticeActivity.java"
PF="$SRC/PlayFinishActivity.java"
LA="$SRC/LandingNoticeActivity.java"
SVC="$SRC/UnarchiveService.java"
CASES="$root/core/chooser/tests/landing-queue/LandingQueueCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "test-landing-queue-java: FAIL -- no javac/java on PATH or in $HOST_JDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /'

missing=0
for f in "$Q" "$LS" "$SK" "$PF" "$LA" "$SVC" "$CASES"; do
  [ -f "$f" ] || { echo "test-landing-queue-java: FAIL -- $f is missing"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

# cases <LandingQueue.java> [quiet]: 0 pass, 1 a case failed, 3 did not compile.
cases() {
  local src=$1 quiet=${2:-} d out rc=0
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src" "$d/out"
  cp "$src" "$d/src/LandingQueue.java"
  cp "$CASES" "$d/src/LandingQueueCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d/src/LandingQueue.java" \
      "$d/src/LandingQueueCases.java" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.LandingQueueCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pin <N1..N5> <file>: 0 the pin holds, 1 it does not, 2 could not extract.
pin() {
  python3 -I - "$1" "$2" <<'PY'
import io, os, re, sys
which, path = sys.argv[1], sys.argv[2]
raw = io.open(path, encoding='utf-8').read()
name = os.path.basename(path)

def fail(why):
    print("FAIL %s (%s): %s" % (which, name, why)); sys.exit(1)

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

def body(sig):
    """[open, close] of the one method whose 4-space-indent declaration matches sig."""
    hits = [x for x in re.finditer(sig, m, re.M)]
    if len(hits) != 1:
        print("EXTRACTION FAILED: %r matches %d times in %s" % (sig, len(hits), name)); sys.exit(2)
    o = m.index('{', hits[0].end() - 1)
    return o, close_of(o)

PLACE = 'if (LandingQueue.place(LandingQueue.DECIDE_MS, id -> !LandingLine.Sweep.done(id)) == LandingQueue.Place.CARD) {'
BCAST = 'app.sendBroadcast(new Intent(LandingNoticeActivity.ACTION_NOTICE).setPackage(app.getPackageName()));'

def notice_check():
    """N1/N2 for the last-save and skip-notice checks: (body text, before, arm text, after) of the place arm."""
    if name == 'LastSaveNoticeActivity.java':
        co, ce = body(r'^    static void check\(Context app, String serial, File stamp\)')
        gate = 'StoreInstaller.writeAtomic(stamp, serial);'
        line = 'LandingQueue.addLine(LastSaveCopy.LINE, 0);'
    elif name == 'SkipNoticeActivity.java':
        co, ce = body(r'^    static void check\(Context app\)')
        gate = None
        line = 'LandingQueue.addLine(SkipNoticeCopy.words(n.phone, when(n.time)), n.time);'
    else:
        print("EXTRACTION FAILED: N1/N2 do not know %s" % name); sys.exit(2)
    cb, cm = src[co:ce + 1], m[co:ce + 1]
    if cm.count('LandingQueue.place(') != 1: fail("check() asks LandingQueue.place %d times, want 1" % cm.count('LandingQueue.place('))
    p = cb.find(PLACE)
    if p < 0: fail("check() has no `%s`" % PLACE)
    if gate is not None:
        g = cb.find(gate)
        if g < 0 or not g < p: fail("check() does not write the stamp before it asks the queue")
    else:
        nn = re.search(r'if \(n == null\) \{', cm)
        if not nn: fail("check() has no if (n == null) { return")
        nc = close_of(co + nn.end() - 1) - co
        if 'return;' not in cm[nn.end():nc]: fail("the n == null block does not return")
        if not cm.find('SkipNoticeCopy.parse(r)') < nn.start() < nc < p: fail("check() asks the queue before the parse's NONE return")
    ao = p + len(PLACE) - 1
    ac = close_of(co + ao) - co
    return cb, cm, cb[ao:ac + 1], cm[ao:ac + 1], cm[ac + 1:], line

if which == 'N1':
    cb, cm, arm, armm, after, line = notice_check()
    if not re.search(r'\breturn;\s*\}$', armm): fail("the CARD arm does not end with return;")
    if cm.count('startActivity(') != 1: fail("check() calls startActivity( %d times, want 1" % cm.count('startActivity('))
    if 'startActivity(' not in after: fail("check() does not start its own card after the CARD arm (the ALONE path)")
    print("PASS N1 %s check() asks the queue after its gate and starts its own card only on ALONE" % name)
elif which == 'N2':
    cb, cm, arm, armm, after, line = notice_check()
    a = arm.find(line)
    b = arm.find(BCAST)
    if a < 0: fail("the CARD arm does not add `%s`" % line)
    if b < 0: fail("the CARD arm's broadcast is not `%s` (package-local ACTION_NOTICE)" % BCAST)
    if not a < b: fail("the CARD arm broadcasts before it adds the line")
    if 'startActivity(' in armm: fail("the CARD arm starts a card")
    if armm.count('sendBroadcast(') != 1 or cm.count('sendBroadcast(') != 1: fail("check() sends more than one broadcast")
    print("PASS N2 %s the CARD arm adds its line, then sends a package-local ACTION_NOTICE, and starts no card" % name)
elif which == 'N3':
    co, ce = body(r'^    static void check\(Context app\)')
    cm = m[co:ce + 1]
    st = cm.find('if (v == PlayFinishPrompt.Verdict.SETTLE) {')
    sh = cm.find('} else if (v == PlayFinishPrompt.Verdict.SHOW) {')
    if st < 0 or sh < 0 or not st < sh: fail("check() has no SETTLE arm then SHOW arm")
    shc = close_of(co + sh + len('} else if (v == PlayFinishPrompt.Verdict.SHOW) {') - 1) - co
    settle, show = cm[st:sh], cm[sh:shc + 1]
    if 'LandingQueue.' in settle: fail("the SETTLE arm touches the queue")
    d = show.find('LandingQueue.awaitDecided(LandingQueue.DECIDE_MS);')
    g = show.find('LandingQueue.awaitGone(LandingQueue.SHOW_MS);')
    s = show.find('app.startActivity(')
    if d < 0 or g < 0: fail("the SHOW arm does not wait (awaitDecided(DECIDE_MS), awaitGone(SHOW_MS))")
    if s < 0: fail("the SHOW arm does not start the card")
    if not d < g < s: fail("the SHOW arm starts the card before it waits, or waits out of order")
    qc = len(re.findall(r'LandingQueue\.\w+\(', cm))
    if qc != 2: fail("check() calls the queue %d times, want the two waits" % qc)
    print("PASS N3 Play's SHOW arm waits for the decision and for the card to close before it starts; SETTLE does not wait")
elif which == 'N4':
    if not re.search(r'static final String ACTION_NOTICE = "com\.nowhere\.chooser\.action\.LANDING_NOTICE";', src):
        fail("ACTION_NOTICE is not com.nowhere.chooser.action.LANDING_NOTICE")
    regs = [x.start() for x in re.finditer(r'(?<!un)registerReceiver\(receiver, f, Context\.RECEIVER_NOT_EXPORTED\);', m)]
    if len(regs) != 1: fail("the receiver is registered %d times, want 1" % len(regs))
    adds = [x.start() for x in re.finditer(r'\bf\.addAction\(ACTION_NOTICE\);', m)]
    if len(adds) != 1 or not adds[0] < regs[0]: fail("f.addAction(ACTION_NOTICE); is not added once before the registration")
    if 'if (ACTION_NOTICE.equals(a)) sync();' not in src: fail("the receiver does not sync() on ACTION_NOTICE")
    yo, yc = body(r'^    private void sync\(\)')
    y = src[yo:yc + 1]
    tk = re.search(r'long\[\] (\w+) = LandingQueue\.takeSkipTimes\(\);', y)
    ln = y.find('LandingQueue.lines()')
    if not tk or y.count('takeSkipTimes(') != 1: fail("sync() does not take the skip times once into a long[]")
    if ln < 0 or not tk.start() < ln: fail("sync() does not take the skip times before it reads the lines")
    if 'setTextColor(look.warn);' not in y: fail("sync() does not draw the lines in look.warn")
    if 'noticeBox.addView(' not in y: fail("sync() does not add the lines to the notice box")
    if 'noticeBox.setVisibility(View.VISIBLE);' not in y: fail("sync() does not show the notice box")
    lp = re.search(r'for \(long (\w+) : ' + re.escape(tk.group(1)) + r'\) \{', y)
    if not lp: fail("sync() does not loop over the taken skip times")
    lc = close_of(yo + lp.end() - 1) - yo
    loop = y[lp.end():lc]
    if not re.search(r'new Thread\(\(\) -> SkipNoticeActivity\.markShown\(' + lp.group(1) + r'\), "nowhere-skip-notice-shown"\);', loop):
        fail("the loop does not mark each taken time shown on its own thread")
    if 'setDaemon(true);' not in loop or '.start();' not in loop: fail("the mark thread is not a started daemon thread")
    if src.count('SkipNoticeActivity.markShown(') != 1: fail("SkipNoticeActivity.markShown( occurs more than once")
    bo, bc = body(r'^    private void addNoticeBox\(LinearLayout card\)')
    if 'noticeBox.setVisibility(View.GONE);' not in src[bo:bc]: fail("the notice box does not start GONE")
    oo, oc = body(r'^    @Override protected void onCreate\(Bundle b\)')
    ob = src[oo:oc]
    if ob.count('addNoticeBox(card);') != 2: fail("onCreate does not add the notice box in both sizes")
    sw = ob.find('sweep = getIntent().getLongExtra(EXTRA_SWEEP, 0L);')
    cs = ob.find('LandingQueue.cardShown(sweep);')
    if cs < 0 or sw < 0 or not sw < cs or src.count('LandingQueue.cardShown(') != 1:
        fail("onCreate does not report the card shown once, after it reads its sweep id")
    do, dc = body(r'^    @Override protected void onDestroy\(\)')
    if 'if (isFinishing()) LandingQueue.cardGone(sweep);' not in src[do:dc] or src.count('LandingQueue.cardGone(') != 1:
        fail("onDestroy does not report the card gone only under isFinishing()")
    print("PASS N4 the card syncs on ACTION_NOTICE, draws the lines in look.warn, marks each skip time once, reports shown and gone")
elif which == 'N5':
    qc = len(re.findall(r'LandingQueue\.\w+\(', m))
    if qc != 2: fail("UnarchiveService calls LandingQueue %d times, want 2" % qc)
    so, sc = body(r'^    private void sweepAuto\(boolean byHand\)')
    sb = src[so:sc]
    c = sb.find('"landing line", t);')   # NWP-20261208-23's catch is a block
    d = sb.find('LandingQueue.decided(card);')
    p = sb.find('PASS_CARD = card;')
    if c < 0 or p < 0: fail("sweepAuto has no landing card block or no PASS_CARD = card;")
    if d < 0: fail("sweepAuto does not call LandingQueue.decided(card)")
    if not c < d < p: fail("decided(card) is not between the card block and PASS_CARD = card;")
    oo, oc = body(r'^    public int onStartCommand\(')
    ob = src[oo:oc]
    # NWP-20261208-23's finally is a block: decided(0) is its last statement before workerDone()
    if not re.search(r'try \{ sweepAutoJoined\(byHand\); \}\s*catch \(Throwable \w+\) \{[^}]*\}\s*finally \{(?:(?!finally|sweepAuto).)*?LandingQueue\.decided\(0\);[^;{}]*?workerDone\(\);\s*\}', ob, re.S):
        fail("the landing arm's finally does not call LandingQueue.decided(0) before workerDone()")
    print("PASS N5 sweepAuto decides after the card block, before PASS_CARD; the landing arm's finally decides 0")
else:
    print("EXTRACTION FAILED: no pin %s" % which); sys.exit(2)
PY
}

fails=0
if cases "$Q"; then echo "PASS cases C1-C13"; else echo "FAIL cases"; fails=$((fails + 1)); fi
pin N1 "$LS" || fails=$((fails + 1))
pin N1 "$SK" || fails=$((fails + 1))
pin N2 "$LS" || fails=$((fails + 1))
pin N2 "$SK" || fails=$((fails + 1))
pin N3 "$PF" || fails=$((fails + 1))
pin N4 "$LA" || fails=$((fails + 1))
pin N5 "$SVC" || fails=$((fails + 1))
if [ "$fails" -ne 0 ]; then echo "test-landing-queue-java: FAIL ($fails check(s))"; exit 1; fi
echo "test-landing-queue-java: PASS"
[ "$MUTATE" = yes ] || exit 0

# --mutate: each mutant edits a COPY of one file and must make its check fail. A mutant that does not apply fails.
MFAILS=0
# mutate <Mn> <file> <out>: apply mutant Mn to <file>, write <out>; non-zero when it did not apply.
mutate() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, sys
mid, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(src, encoding='utf-8').read()
def rep(t, old, new):
    if t.count(old) != 1:
        print("MUTANT %s DID NOT APPLY: %r occurs %d times" % (mid, old, t.count(old))); sys.exit(1)
    return t.replace(old, new)
if mid == 'M1':
    t = rep(s, '        if (decided) return;\n', '')
elif mid == 'M2':
    t = rep(s, ' && sweepOpen.test(card)) return Place.CARD;', ') return Place.CARD;')
elif mid == 'M3':
    t = rep(s, '                wait = showMs - (now() - decidedAt);\n                if (wait <= 0) return;\n', '')
elif mid == 'M4':
    t = rep(s, '        skipTaken = SKIP.size();\n', '')
elif mid == 'M5':
    t = rep(s, '                android.util.Log.i("NowhereChooser", "last save line: folded");\n',
            '                android.util.Log.i("NowhereChooser", "last save line: folded");\n'
            '                app.startActivity(new Intent(app, LastSaveNoticeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));\n')
elif mid == 'M6':
    t = rep(s, 'new Intent(LandingNoticeActivity.ACTION_NOTICE).setPackage(app.getPackageName())',
            'new Intent(LandingNoticeActivity.ACTION_NOTICE)')
elif mid == 'M7':
    t = rep(s, '                LandingQueue.awaitDecided(LandingQueue.DECIDE_MS);\n                LandingQueue.awaitGone(LandingQueue.SHOW_MS);\n', '')
elif mid == 'M8':
    t = rep(s, '            t.setTextColor(look.warn);\n', '            t.setTextColor(look.ink);\n')
elif mid == 'M9':
    t = rep(s, 'if (isFinishing()) LandingQueue.cardGone(sweep);', 'LandingQueue.cardGone(sweep);')
elif mid == 'M10':
    t = rep(s, '        LandingQueue.decided(card);', '       ')
elif mid == 'M11':
    t = rep(s, '                    LandingQueue.decided(0); // NWP-20261208-24: no card decided: free the notices\n', '')
elif mid == 'M12':
    t = rep(s, '        if (id == 0) return;\n        SHOWN.add(id);', '        if (id == 0 || !decided || id != card) return;\n        SHOWN.add(id);')
elif mid == 'M13':
    t = rep(s, '        if (id == 0) return;\n        GONE.add(id);', '        if (id == 0 || !decided || id != card) return;\n        GONE.add(id);')
elif mid == 'M14':
    t = rep(s, '''            return;
        }
        try {
            app.startActivity(new Intent(app, SkipNoticeActivity.class)''', '''        }
        try {
            app.startActivity(new Intent(app, SkipNoticeActivity.class)''')
elif mid == 'M15':
    t = rep(s, '        f.addAction(ACTION_NOTICE);\n', '')
elif mid == 'M16':
    t = rep(s, '        long[] skipShown = LandingQueue.takeSkipTimes();\n        java.util.List<String> notices = LandingQueue.lines();\n',
            '        java.util.List<String> notices = LandingQueue.lines();\n        long[] skipShown = LandingQueue.takeSkipTimes();\n')
else:
    print("no mutant %s" % mid); sys.exit(2)
if t == s:
    print("MUTANT %s DID NOT APPLY: no change" % mid); sys.exit(1)
io.open(dst, 'w', encoding='utf-8').write(t)
PY
}

# convict <Mn> <cases|N1..N5> <file> <what>
convict() {
  local id=$1 check=$2 file=$3 what=$4 d dst rc
  d=$(mktemp -d -p "$W") || { echo "FAIL $id: no temp"; MFAILS=$((MFAILS + 1)); return; }
  dst="$d/$(basename "$file")"
  if ! mutate "$id" "$file" "$dst"; then echo "FAIL $id ($what): the mutant did not apply"; MFAILS=$((MFAILS + 1)); rm -rf "$d"; return; fi
  if [ "$check" = cases ]; then
    cases "$dst" quiet; rc=$?
  else
    pin "$check" "$dst" >/dev/null; rc=$?
  fi
  if [ "$rc" -eq 1 ]; then echo "CONVICTED $id by $check ($what)"
  elif [ "$rc" -eq 0 ]; then echo "SURVIVED $id ($what)"; MFAILS=$((MFAILS + 1))
  else echo "FAIL $id ($what): the check could not run (rc $rc)"; MFAILS=$((MFAILS + 1)); fi
  rm -rf "$d"
}

convict M1 cases "$Q" "the last decision wins (C7)"
convict M2 cases "$Q" "place() folds into a closed sweep (C4)"
convict M3 cases "$Q" "awaitGone ignores showMs (C6)"
convict M4 cases "$Q" "a skip time is taken twice (C10)"
convict M5 N2 "$LS" "the fold arm also starts the alone card (N2)"
convict M6 N2 "$SK" "the ACTION_NOTICE broadcast is not package-local (N2)"
convict M7 N3 "$PF" "Play shows without waiting (N3)"
convict M8 N4 "$LA" "the folded lines in look.ink (N4)"
convict M9 N4 "$LA" "cardGone on a recreate, not only under isFinishing (N4)"
convict M10 N5 "$SVC" "decided(card) removed (N5)"
convict M11 N5 "$SVC" "decided(0) removed from the landing finally (N5)"
convict M12 cases "$Q" "a shown report before the decision is dropped (C11)"
convict M13 cases "$Q" "a gone report before the decision is dropped (C12)"
convict M14 N1 "$SK" "the CARD arm falls through to the alone card (N1)"
convict M15 N4 "$LA" "ACTION_NOTICE not registered (N4)"
convict M16 N4 "$LA" "sync() takes the skip times after it reads the lines (N4)"

if [ "$MFAILS" -ne 0 ]; then echo "FAIL: $MFAILS mutant check(s) failed"; exit 1; fi
echo "OK: all 16 mutants convicted"
