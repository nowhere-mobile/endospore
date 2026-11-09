#!/usr/bin/env bash
# test-landing-line-java.sh [--mutate] -- NWP-20261122-15, NWP-20261126-05, NWP-20261130-09: the sign-in's Auto sweep
# shows ONE dismissible checklist card, once per sign-in, when it has apps to fetch, and it lists Play services.
#
# WHY. The switch-landing sweep materialises quietly, so a sign-in with 40 Auto apps pending landed on an empty-looking
# home for most of an hour with only a shade notification. DECIDED 2026-11-01 (h50 #5, docs/product-decisions.md
# "twenty-two answers to harvests 50, 51 and 52 ..."): one dismissible notice when the user lands, once per sign-in and
# only when the Auto sweep has apps to fetch. The first build was a bare WRAP_CONTENT dialog that shrank to its text
# and clipped its own second sentence (husky 0.5.52). DECIDED 2026-11-03 ("the Auto sweep's landing notice is a
# checklist card, and Profile Help's cards show where to tap", option D): a rounded card 85 % of the screen wide in the
# gate's look, titled "Welcome back"; up to 4 apps one row each ticking off live, "You can keep using the phone." and
# "Got it"; from 5 a headline count, a bar, 3 rows and "+<n> more" opening Your apps; it closes a few seconds after the
# sweep ends. The words are drafts for Chester. NWP-20261130-09 (Chester, 2026-11-06): the sweep fetches Play services as
# a dep of the first app that needs it, for minutes and outside its work list, so the card read as if nothing installed.
#
# WHAT RUNS. LandingLine and AppDeps (pure Java) are compiled with tests/landing-line/LandingLineCases.java and RUN: show()
# (C1-C7: landing with 1 and 12 to fetch, nothing to fetch, not landing, a resume, another serial, no serial);
# headline() and more() verbatim; the constants verbatim; widthPx(1080) == 918; rows()/moreCount() for 1, 4, 5 and 50
# apps, with landed apps making the rows advance and 2 rows near the end; LandingLine.Sweep, the in-process record the
# card reads (C26-C32): a failed app keeps its row and counts in "+<n> more" (RF-001), outcomes and the end recorded
# before the card reads are all there and a recreated card reads them again (RF-002), another sweep's calls change
# nothing, and an unknown sweep reads as ended so its card closes; cardPkgs() through the real AppDeps rule (C33-C41,
# C47): Play on, ordered first, Play off, code already there, GSF separate and absent, keep-set order, a client that still
# demands gms, plain apps; Sweep.depLanded (C42-C45): the tick, a failed dep, an earlier failed outcome, the from-5 rows;
# depLabel (C46).
# WHAT IS PINNED BY ANCHOR (the activities and the service cannot be compiled off the build host), on comment-stripped
# sources: (P1) sweepAuto reads and removes LANDING and calls LandingLine.show(landing, work.size(), ...) after the
# AutoSweepNet.mayFetch block and before qEnqueue(work); (P2) the stamp is written before startActivity, which starts
# LandingNoticeActivity with FLAG_ACTIVITY_NEW_TASK, the count, EXTRA_PKGS from `cardRows` (LandingLine.cardPkgs, built
# after the stamp) and EXTRA_SWEEP, the id LandingLine.Sweep.begin(cardRows) gave between the stamp and the start, inside
# a try whose catch (Throwable) logs; (P3) LANDING.set(!byHand); is the file's one LANDING.set outside sweepAutoJoined, after the netRekick
# block and before the presence snapshot and `try { sweepAutoJoined(byHand); }`; (P4) the netRekick block holds no LANDING.set; (P5) the sweepAuto
# signature and its two call sites (sweepAutoJoined since NWP-20261126-04) are unchanged, byte for byte; (P6) the manifest declares LandingNoticeActivity
# exported="false" and excludeFromRecents="true"; (P7) the stamp is "landing-line-shown" under getNoBackupFilesDir()
# and the serial is getSerialNumberForUser(Process.myUserHandle()), negative or a throw read as null; (P8) the card
# sets its window width with getWindow().setLayout(LandingLine.widthPx(...)) after setContentView, shows TITLE, KEEP
# and GOT_IT, builds its ProgressBar only in the from-5 arm, registers ACTION_APP and ACTION_SWEEP_DONE
# (RECEIVER_NOT_EXPORTED), ends onCreate by registering and THEN reading the record (sync()), re-reads it on both
# broadcasts, draws its rows and count from the landed flags only, unregisters in onDestroy and finishes CLOSE_AFTER_MS
# after its sweep ends; (P9) sweepAuto records each outcome in LandingLine.Sweep and then sends ACTION_APP once per
# outcome, package-local, after the SweepOutcome.request round trip, never in the RETRY arm, in a try that logs, and
# records the end just before ACTION_SWEEP_DONE; (P10) the "+<n> more" row starts ProfileActivity with EXTRA_OPEN = OPEN_YOUR_APPS and
# FLAG_ACTIVITY_NEW_TASK, then finishes; (P11) ProfileActivity calls showYourApps() under that extra, removes it
# first, from the first drawn menu and from onNewIntent; (P12) cardDepLanded(dep) runs in materializeLocked's dep loop
# after the `if (!dok)` abort and just before qFinish(dep), and first in pendingDeps' AUTO_WHOLE and AUTO_RESTORE_ONLY
# branches, and it records in LandingLine.Sweep.depLanded before one package-local ACTION_APP in a try that logs; (P13) the
# card's label() falls to LandingLine.depLabel after the archived read; (P14) LandingLine's names and words equal
# ProfileActivity's, and the list reads ProfileActivity.appDeps and hasInstalledCode, as pendingDeps does.
# The merger's full javac / `m NowhereChooser` covers UnarchiveService, LandingNoticeActivity and ProfileActivity.
#
# What this does NOT prove: the card on a handset in both looks (sign-ins with 2 and with 12 Auto apps pending: the
# width, the rows ticking off, the bar, "+<n> more" opening Your apps, the close after the sweep) stays the merger's
# device follow-up, and so does a sign-in with Google Play On that shows Play services from the first second.
#
#   bash test-landing-line-java.sh              # the cases and the pins
#   bash test-landing-line-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; fi
done

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-landing-line-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

LL="$SRC/LandingLine.java"; US="$SRC/UnarchiveService.java"; LA="$SRC/LandingNoticeActivity.java"; AD="$SRC/AppDeps.java"
PA="$SRC/ProfileActivity.java"; MF="$HERE/AndroidManifest.xml"; CASES="$HERE/tests/landing-line/LandingLineCases.java"
for f in "$CASES" "$US" "$MF" "$PA" "$AD"; do
  if [ ! -f "$f" ]; then echo "test-landing-line-java: FAIL -- $f is missing"; exit 2; fi
done

cases() { # cases <LandingLine.java> [quiet]: 0 pass, 1 a case failed, 2 did not compile
  local ll=$1 quiet=${2:-} cls out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  if [ ! -f "$ll" ]; then
    [ -z "$quiet" ] && echo "FAIL $ll is missing"
    rm -rf "$cls"; return 1
  fi
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$ll" "$AD" "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.LandingLineCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <UnarchiveService.java> <AndroidManifest.xml> <LandingNoticeActivity.java> <ProfileActivity.java>
  #        <LandingLine.java>: 0 hold, 1 failed, 2 extract
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import io, os, re, sys
us_path, mf_path, la_path, pa_path, ll_path = sys.argv[1:6]
raw = io.open(us_path, encoding='utf-8').read()

def strip(s):
    """Drop // and /* */ comments; string literals are kept."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        elif s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

src = strip(raw)

def block(s, at):
    """The text from the first '{' at or after index `at` to its matching '}'; (start, end) in s."""
    j = s.find('{', at)
    if j < 0:
        print("EXTRACTION FAILED: no '{' after index %d" % at); sys.exit(2)
    d = 0
    for k in range(j, len(s)):
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: return j, k + 1
    print("EXTRACTION FAILED: unbalanced braces after index %d" % at); sys.exit(2)

def one(s, sig, what):
    n = s.count(sig)
    if n != 1:
        print("EXTRACTION FAILED: %r occurs %d times in %s" % (sig, n, what)); sys.exit(2)
    return s.index(sig)

bad = []

# P5 the signature and both call sites, byte for byte, in the raw file
for t in ('    private void sweepAuto(boolean byHand) {\n', 'try { sweepAutoJoined(byHand); }', 'try { sweepAutoJoined(false); }'):
    if raw.count(t) != 1:
        bad.append('(P5) %r occurs %d times in UnarchiveService.java, not once' % (t.strip(), raw.count(t)))
if bad:
    for b in bad: print('PIN FAILED: ' + b)
    sys.exit(1)

sa0, sa1 = block(src, one(src, 'private void sweepAuto(boolean byHand) {', 'UnarchiveService.java'))
sweep = src[sa0:sa1]

# P1 the read, the remove and the show sit after the network gate and before qEnqueue(work)
g = one(sweep, 'if (!work.isEmpty() && !AutoSweepNet.mayFetch(', 'sweepAuto')
_, gend = block(sweep, g)
q = one(sweep, 'qEnqueue(work);', 'sweepAuto')
for t in ('Boolean.TRUE.equals(LANDING.get())', 'LANDING.remove();', 'LandingLine.show(landing, work.size(), '):
    i = sweep.find(t)
    if i < 0 or sweep.count(t) != 1 or not (gend <= i < q):
        bad.append('(P1) %r is not in sweepAuto once, after the mayFetch block and before qEnqueue(work)' % t)
if not (sweep.find('LANDING.get()') < sweep.find('LANDING.remove();') < sweep.find('LandingLine.show(')):
    bad.append('(P1) sweepAuto does not read LANDING, remove it, then ask LandingLine.show, in that order')

# P2 the stamp before the start, both in one try whose catch (Throwable) logs
wr = sweep.find('StoreInstaller.writeAtomic(stamp, serial);')
st = sweep.find('startActivity(')
if wr < 0 or st < 0 or sweep.count('startActivity(') != 1 or not (wr < st):
    bad.append('(P2) the stamp is not written (StoreInstaller.writeAtomic(stamp, serial)) before the one startActivity')
else:
    stmt = sweep[st:sweep.find(';', st)]
    if 'LandingNoticeActivity.class' not in stmt or 'Intent.FLAG_ACTIVITY_NEW_TASK' not in stmt \
            or 'LandingNoticeActivity.EXTRA_COUNT, cardRows.length' not in stmt:
        bad.append('(P2) startActivity does not start LandingNoticeActivity with FLAG_ACTIVITY_NEW_TASK and the count')
    if 'LandingNoticeActivity.EXTRA_PKGS, cardRows' not in stmt:
        bad.append('(P2) startActivity does not give LandingNoticeActivity EXTRA_PKGS from cardRows')
    cr = sweep.find('String[] cardRows = LandingLine.cardPkgs(work, ')
    bg = sweep.find('card = LandingLine.Sweep.begin(cardRows);')
    if sweep.count('LandingLine.cardPkgs(') != 1 or not (wr < cr < bg):
        bad.append('(P2) cardRows is not built once (LandingLine.cardPkgs) between the stamp and begin')
    if sweep.count('LandingLine.Sweep.begin(') != 1 or not (wr < bg < st) or 'long card = 0;' not in sweep:
        bad.append('(P2) the card sweep is not begun once (card = LandingLine.Sweep.begin(cardRows)) between the stamp '
                   'and the start, from long card = 0')
    if 'LandingNoticeActivity.EXTRA_SWEEP, card' not in stmt:
        bad.append('(P2) startActivity does not give LandingNoticeActivity its sweep id (EXTRA_SWEEP, card)')
    ls = sweep.find('LandingLine.show(')
    tr = sweep.rfind('try {', 0, ls)
    if tr < 0 or tr < gend:
        bad.append('(P2) LandingLine.show is not inside a try after the mayFetch block')
    else:
        t0, t1 = block(sweep, tr)
        if not (t0 < wr < t1 and t0 < st < t1) or not re.match(r'\s*catch \(Throwable \w+\) \{ android\.util\.Log\.w\(',
                                                               sweep[t1:]):
            bad.append('(P2) the stamp write and the start are not in one try whose catch (Throwable) logs')

# P3 the one LANDING.set, on the switch-landing path. NWP-20261126-04: sweepAutoJoined sets it again for each pass from
# the start's own landing bit, so its body is left out of the count.
j0, j1 = block(src, one(src, 'private void sweepAutoJoined(boolean byHand) {', 'UnarchiveService.java'))
outj = src[:j0] + src[j1:]
if outj.count('LANDING.set(') != 1 or outj.count('LANDING.set(!byHand);') != 1:
    bad.append('(P3) outside sweepAutoJoined, LANDING.set( occurs %d times and LANDING.set(!byHand); %d times; want each once'
               % (outj.count('LANDING.set('), outj.count('LANDING.set(!byHand);')))
nr = one(src, 'if (netRekick) {', 'UnarchiveService.java')
n0, n1 = block(src, nr)
ls_ = src.find('LANDING.set(!byHand);')
snap = src.find('StoreInstaller.snapshotAppSeen(', n1)
call = src.find('try { sweepAutoJoined(byHand); }')
nb = src[n0:n1]
if 'return;' not in nb:
    bad.append('(P3) the netRekick block has no return;')
if not (n1 <= ls_ < snap < call) or src[n1:ls_].strip() != '':
    bad.append('(P3) LANDING.set(!byHand); is not the first statement after the netRekick block, before the presence '
               'snapshot and try { sweepAutoJoined(byHand); }')

# P4 the network re-kick sets nothing
if 'LANDING' in nb:
    bad.append('(P4) the netRekick block touches LANDING')

# P7 the stamp file and the serial
if sweep.count('new File(getNoBackupFilesDir(), "landing-line-shown")') != 1:
    bad.append('(P7) the stamp is not new File(getNoBackupFilesDir(), "landing-line-shown") in sweepAuto')
if 'readLandingStamp(stamp)' not in sweep or 'landingSerial()' not in sweep:
    bad.append('(P7) sweepAuto does not give LandingLine.show readLandingStamp(stamp) and landingSerial()')
if 'private static final ThreadLocal<Boolean> LANDING = new ThreadLocal<>();' not in src:
    bad.append('(P7) the LANDING field is not a private static final ThreadLocal<Boolean>')
s0, s1 = block(src, one(src, 'private String landingSerial() {', 'UnarchiveService.java'))
ser = src[s0:s1]
if 'getSerialNumberForUser(android.os.Process.myUserHandle())' not in ser or not re.search(r'< 0 \? null', ser) \
        or not re.search(r'catch \(Throwable \w+\) \{[^}]*return null;', ser):
    bad.append('(P7) landingSerial does not read getSerialNumberForUser(Process.myUserHandle()), negative or a throw null')

# P6 the manifest entry
mf = re.sub(r'<!--.*?-->', '', io.open(mf_path, encoding='utf-8').read(), flags=re.S)
acts = re.findall(r'<activity\s[^>]*android:name="\.LandingNoticeActivity"[^>]*>', mf)
if len(acts) != 1:
    bad.append('(P6) the manifest declares .LandingNoticeActivity %d times, not once' % len(acts))
elif 'android:exported="false"' not in acts[0] or 'android:excludeFromRecents="true"' not in acts[0]:
    bad.append('(P6) .LandingNoticeActivity is not exported="false" and excludeFromRecents="true"')

# P9 one ACTION_APP per outcome: after the SweepOutcome round trip, never in the RETRY arm, package-local, in a try
loop = sweep[one(sweep, 'for (int i = 0; i < work.size(); i++) {', 'sweepAuto'):]
lo0, lo1 = block(loop, 0)
loop = loop[lo0:lo1]
bc = 'sendBroadcast(new Intent(LandingNoticeActivity.ACTION_APP)'
if sweep.count(bc) != 1 or loop.count(bc) != 1:
    bad.append('(P9) %r occurs %d times in sweepAuto and %d in its work loop; want once in the loop'
               % (bc, sweep.count(bc), loop.count(bc)))
else:
    b9 = loop.index(bc)
    st9 = loop[b9:loop.find(';', b9)]
    for t in ('.setPackage(getPackageName())', 'LandingNoticeActivity.EXTRA_PKG, pkg', 'LandingNoticeActivity.EXTRA_OK, ok'):
        if t not in st9:
            bad.append('(P9) the ACTION_APP broadcast does not carry %s' % t)
    rt = loop.find('if (req != null) DaemonSocket.roundTrip(req, 5000);')
    if rt < 0 or not rt < b9:
        bad.append('(P9) the ACTION_APP broadcast does not come after the SweepOutcome.request round trip')
    r0, r1 = block(loop, one(loop, 'if (step == SweepBusy.Step.RETRY) {', 'the work loop'))
    if r0 < b9 < r1:
        bad.append('(P9) the ACTION_APP broadcast is inside the SweepBusy RETRY arm')
    tr9 = loop.rfind('try {', 0, b9)
    if tr9 < 0:
        bad.append('(P9) the ACTION_APP broadcast is not in a try')
    else:
        t90, t91 = block(loop, tr9)
        if not (t90 < b9 < t91) or loop[t90 + 1:b9].strip() != '' or not re.match(
                r'\s*catch \(Throwable \w+\) \{ android\.util\.Log\.w\(', loop[t91:]):
            bad.append('(P9) the ACTION_APP broadcast is not alone in a try whose catch (Throwable) logs')
        rc9 = 'LandingLine.Sweep.outcome(card, pkg, ok);'
        if sweep.count(rc9) != 1 or loop.count(rc9) != 1 or not (rt < loop.find(rc9) < tr9) \
                or loop[loop.find(rc9) + len(rc9):tr9].strip() != '':
            bad.append('(P9) %s is not in the work loop once, after the round trip and just before the broadcast try' % rc9)
    sd9 = 'sendBroadcast(new Intent(ACTION_SWEEP_DONE)'
    en9 = 'LandingLine.Sweep.end(card);'
    if sweep.count(en9) != 1 or sweep.count(sd9) != 1 or not (0 <= sweep.find(en9) < sweep.find(sd9)) \
            or not re.fullmatch(r'\s*try \{ ', sweep[sweep.find(en9) + len(en9):sweep.find(sd9)]):
        bad.append('(P9) %s is not recorded once, just before the ACTION_SWEEP_DONE broadcast' % en9)

# P8 the card
if not os.path.isfile(la_path):
    bad.append('(P8) LandingNoticeActivity.java is missing')
else:
    la = strip(io.open(la_path, encoding='utf-8').read())
    sl = 'getWindow().setLayout(LandingLine.widthPx('
    if la.count(sl) != 1 or la.find('setContentView(') < 0 or not la.find('setContentView(') < la.find(sl):
        bad.append('(P8) LandingNoticeActivity does not call %s once, after setContentView' % sl)
    for t in ('LandingLine.TITLE', 'LandingLine.GOT_IT', 'LandingLine.KEEP', 'LandingLine.READY', 'LandingLine.COMING',
              'LandingLine.TICK', 'LandingLine.CLOCK', 'LandingLine.headline(', 'LandingLine.rows(',
              'LandingLine.moreCount(', 'LandingLine.more(', 'getStringArrayExtra(EXTRA_PKGS)'):
        if t not in la:
            bad.append('(P8) LandingNoticeActivity does not use %s' % t)
    if 'gotIt.setOnClickListener(v -> finish());' not in la:
        bad.append('(P8) the GOT_IT button does not finish the card')
    # The bar is built only in the from-5 arm: the one `new ProgressBar(` is inside the else of if (!LandingLine.big(
    if la.count('if (!LandingLine.big(') != 1:
        bad.append('(P8) if (!LandingLine.big( occurs %d times, not once' % la.count('if (!LandingLine.big('))
    else:
        a8 = la.index('if (!LandingLine.big(')
        _, i1 = block(la, a8)
        rest = la[i1:]
        if not rest.lstrip().startswith('else'):
            bad.append('(P8) the LandingLine.big if has no else arm')
        else:
            e0, e1 = block(la, i1 + rest.index('else'))
            k = la.find('new ProgressBar(')
            if la.count('new ProgressBar(') != 1 or not (e0 < k < e1):
                bad.append('(P8) new ProgressBar( occurs %d times, or not inside the else arm of if (!LandingLine.big('
                           % la.count('new ProgressBar('))
    if len(re.findall(r'(?<!un)registerReceiver\(', la)) != 1 or 'Context.RECEIVER_NOT_EXPORTED' not in la \
            or 'new IntentFilter(ACTION_APP)' not in la or 'f.addAction(UnarchiveService.ACTION_SWEEP_DONE);' not in la:
        bad.append('(P8) the card does not register one RECEIVER_NOT_EXPORTED receiver for ACTION_APP and ACTION_SWEEP_DONE')
    od = la.find('protected void onDestroy() {')
    if od < 0:
        bad.append('(P8) the card has no onDestroy')
    else:
        d0, d1 = block(la, od)
        if 'unregisterReceiver(receiver)' not in la[d0:d1]:
            bad.append('(P8) onDestroy does not unregister the receiver')
    cs = la.find('private void closeSoon() {')
    sy8 = la.find('private void sync() {')
    if cs < 0 or sy8 < 0 or la.count('private void sync() {') != 1:
        bad.append('(P8) the card has no closeSoon() or no one sync()')
    else:
        c0, c1 = block(la, cs)
        y0, y1 = block(la, sy8)
        yb = la[y0:y1]
        if 'postDelayed(this::finish, LandingLine.CLOSE_AFTER_MS);' not in la[c0:c1] \
                or 'if (LandingLine.Sweep.done(sweep)) closeSoon();' not in yb:
            bad.append('(P8) sync() does not finish the card CLOSE_AFTER_MS after its sweep ended (closeSoon)')
        if 'LandingLine.Sweep.landed(sweep)' not in yb or 'landed = l;' not in yb:
            bad.append('(P8) sync() does not take the landed flags from LandingLine.Sweep.landed(sweep)')
    # RF-002: the receiver re-reads the record on both actions; onCreate registers it FIRST and reads the record AFTER
    if not re.search(r'if \(ACTION_APP\.equals\(a\) \|\| UnarchiveService\.ACTION_SWEEP_DONE\.equals\(a\)\) sync\(\);', la):
        bad.append('(P8) the receiver does not call sync() on ACTION_APP and on ACTION_SWEEP_DONE')
    if 'sweep = getIntent().getLongExtra(EXTRA_SWEEP, 0L);' not in la:
        bad.append('(P8) the card does not read its sweep id (EXTRA_SWEEP)')
    oc = la.find('protected void onCreate(Bundle b) {')
    if oc < 0:
        bad.append('(P8) the card has no onCreate')
    else:
        o0, o1 = block(la, oc)
        ob = la[o0:o1]
        rr = ob.find('registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED);')
        if rr < 0 or not re.fullmatch(r'registerReceiver\(receiver, f, Context\.RECEIVER_NOT_EXPORTED\);\s*sync\(\);\s*\}',
                                      ob[rr:]):
            bad.append('(P8) onCreate does not end by registering the receiver, then sync()')
        if 'LandingLine.Sweep.' in ob[:max(rr, 0)]:
            bad.append('(P8) onCreate reads LandingLine.Sweep before it registers the receiver')
    # RF-001: the rows and the count follow landed only; a failed app is not landed
    if 'LandingLine.rows(pkgs, landed)' not in la or 'LandingLine.moreCount(pkgs, landed)' not in la \
            or re.search(r'\bsettled\b', la):
        bad.append('(P8) render() does not give LandingLine.rows and moreCount the landed flags (or keeps a settled set)')
    if re.search(r'ScrollView|LockTask|setFinishOnTouchOutside\(false\)', la):
        bad.append('(P8) LandingNoticeActivity scrolls, holds a lock task or a pin')
    if 'GradientDrawable' not in la or 'setCornerRadius(' not in la:
        bad.append('(P8) the card is not a rounded GradientDrawable')
    if 'getArchivedPackage(' not in la:
        bad.append('(P8) the card does not read the archived placeholder label')
    if 'GatePalette.forLook(' not in la or 'Theme_Material_Light_Dialog_NoActionBar' not in la:
        bad.append('(P8) LandingNoticeActivity does not take the gate look as MaterializingActivity does')

    # P10 the "+<n> more" row opens Your apps, then finishes
    mr = la.find('moreRow.setOnClickListener(')
    if mr < 0:
        bad.append('(P10) the more row has no click listener')
    else:
        m0, m1 = block(la, mr)
        body = la[m0:m1]
        sa = body.find('startActivity(')
        stmt = body[sa:body.find(';', sa)] if sa >= 0 else ''
        if body.count('startActivity(') != 1 or 'new Intent(this, ProfileActivity.class)' not in stmt \
                or '.putExtra(LandingLine.EXTRA_OPEN, LandingLine.OPEN_YOUR_APPS)' not in stmt \
                or 'Intent.FLAG_ACTIVITY_NEW_TASK' not in stmt:
            bad.append('(P10) the more row does not start ProfileActivity with EXTRA_OPEN = OPEN_YOUR_APPS and NEW_TASK')
        elif body.find('finish();', sa) < 0:
            bad.append('(P10) the more row does not finish the card after it opens Your apps')
    if 'moreRow.setText(LandingLine.more(' not in la:
        bad.append('(P10) the more row does not show LandingLine.more')

# P11 ProfileActivity honours the extra once, from the first menu and from onNewIntent
if not os.path.isfile(pa_path):
    bad.append('(P11) ProfileActivity.java is missing')
else:
    pa = strip(io.open(pa_path, encoding='utf-8').read())
    h = pa.find('private void openYourAppsIfAsked() {')
    if h < 0 or pa.count('private void openYourAppsIfAsked() {') != 1:
        bad.append('(P11) ProfileActivity has no one openYourAppsIfAsked()')
    else:
        h0, h1 = block(pa, h)
        hb = pa[h0:h1]
        rx, sy = hb.find('removeExtra(LandingLine.EXTRA_OPEN)'), hb.find('showYourApps();')
        if 'LandingLine.OPEN_YOUR_APPS.equals(' not in hb or 'getStringExtra(LandingLine.EXTRA_OPEN)' not in hb \
                or rx < 0 or sy < 0 or not rx < sy:
            bad.append('(P11) openYourAppsIfAsked does not check EXTRA_OPEN = OPEN_YOUR_APPS, remove it, then showYourApps()')
        pr0, pr1 = block(pa, one(pa, 'private void probeSession() {', 'ProfileActivity.java'))
        pb = pa[pr0:pr1]
        ck = pb.find('sessionType = "CHECKING";')
        if ck < 0 or pb.find('openYourAppsIfAsked();', ck) < 0 or pb.count('openYourAppsIfAsked();') != 1:
            bad.append('(P11) probeSession does not call openYourAppsIfAsked() once, after the first menu is drawn')
        else:
            sc = pb.find('showConfirm();', ck)
            if not (0 <= sc < pb.find('openYourAppsIfAsked();', ck)):
                bad.append('(P11) probeSession calls openYourAppsIfAsked() before showConfirm()')
        ni0, ni1 = block(pa, one(pa, 'protected void onNewIntent(Intent intent) {', 'ProfileActivity.java'))
        nb_ = pa[ni0:ni1]
        ag = nb_.find('if (AutoLogoffGate.honoured(')
        if ag < 0:
            bad.append('(P11) onNewIntent has no AutoLogoffGate block')
        else:
            _, ag1 = block(nb_, ag)
            if nb_.count('openYourAppsIfAsked();') != 1 or nb_.find('openYourAppsIfAsked();') < ag1:
                bad.append('(P11) onNewIntent does not call openYourAppsIfAsked() once, after the AutoLogoffGate block')

# P12 a dep's tick: after the abort and before qFinish in the dep loop, first in both pendingDeps branches that find code
ml0, ml1 = block(src, one(src, 'private boolean materializeLocked(String pkg, boolean quiet) {', 'UnarchiveService.java'))
ml = src[ml0:ml1]
dl0, dl1 = block(ml, one(ml, 'for (String dep : deps) {', 'materializeLocked'))
dl = ml[dl0:dl1]
tk = 'cardDepLanded(dep);'
_, ab1 = block(dl, one(dl, 'if (!dok) {', 'the dep loop'))
if dl.count(tk) != 1 or not re.match(r'\s*cardDepLanded\(dep\);\s*qFinish\(dep\);', dl[ab1:]):
    bad.append('(P12) the dep loop does not call %s once, after the if (!dok) block and just before qFinish(dep);' % tk)
pd0, pd1 = block(src, one(src, 'private java.util.List<String> pendingDeps(', 'UnarchiveService.java'))
pd = src[pd0:pd1]
for arm in ('AUTO_WHOLE', 'AUTO_RESTORE_ONLY'):
    a0, a1 = block(pd, one(pd, 'if (action == %s) {' % arm, 'pendingDeps'))
    if not pd[a0 + 1:a1].lstrip().startswith(tk) or pd[a0:a1].count(tk) != 1 or 'continue;' not in pd[a0:a1]:
        bad.append('(P12) the pendingDeps %s branch does not start with %s' % (arm, tk))
if pd.count(tk) != 2:
    bad.append('(P12) pendingDeps calls %s %d times, not twice' % (tk, pd.count(tk)))
h0, h1 = block(src, one(src, 'private void cardDepLanded(String dep) {', 'UnarchiveService.java'))
hl = src[h0:h1]
rec = hl.find('if (!LandingLine.Sweep.depLanded(dep)) return;')
snd = hl.find('sendBroadcast(new Intent(LandingNoticeActivity.ACTION_APP)')
if rec < 0 or snd < 0 or not rec < snd or hl.count('sendBroadcast(') != 1:
    bad.append('(P12) cardDepLanded does not record in LandingLine.Sweep.depLanded first and then send one ACTION_APP')
else:
    st12 = hl[snd:hl.find(';', snd)]
    for t in ('.setPackage(getPackageName())', 'LandingNoticeActivity.EXTRA_PKG, dep', 'LandingNoticeActivity.EXTRA_OK, true'):
        if t not in st12:
            bad.append('(P12) the dep ACTION_APP broadcast does not carry %s' % t)
    tr12 = hl.find('try {')
    if tr12 < 0 or not rec < tr12 < snd or hl[tr12 + 5:snd].strip() != '':
        bad.append('(P12) the dep ACTION_APP broadcast is not alone in a try')
    else:
        _, t12 = block(hl, tr12)
        if not re.match(r'\s*catch \(Throwable \w+\) \{ android\.util\.Log\.w\(', hl[t12:]):
            bad.append('(P12) the dep ACTION_APP broadcast is not in a try whose catch (Throwable) logs')

# P13 the card names a provider: after the archived read, before the package name
if os.path.isfile(la_path):
    la13 = strip(io.open(la_path, encoding='utf-8').read())
    l0, l1 = block(la13, one(la13, 'private String label(int i) {', 'LandingNoticeActivity.java'))
    lb = la13[l0:l1]
    ga, dl13, fin = lb.find('getArchivedPackage('), lb.find('if (got == null) got = LandingLine.depLabel(pkg);'), lb.find('labels[i] = got != null')
    if not (0 <= ga < dl13 < fin):
        bad.append('(P13) label() does not fall to LandingLine.depLabel(pkg) after the archived read and before the package name')

# P14 the names and words equal ProfileActivity's, and the list reads what pendingDeps reads
ll14 = strip(io.open(ll_path, encoding='utf-8').read())
pa14 = strip(io.open(pa_path, encoding='utf-8').read()) if os.path.isfile(pa_path) else ''
for ln, pn in (('GMS', 'GMS_PKG'), ('GSF', 'GSF_PKG')):
    n1 = re.search(r'static final String %s = "([^"]*)";' % ln, ll14)
    n2 = re.search(r'static final String %s = "([^"]*)";' % pn, pa14)
    if not n1 or not n2 or n1.group(1) != n2.group(1):
        bad.append('(P14) LandingLine.%s does not equal ProfileActivity.%s' % (ln, pn))
    w1 = re.search(r'if \(%s\.equals\(pkg\)\)\s*return "([^"]*)";' % ln, ll14)
    w2 = re.search(r'if \(%s\.equals\(pkg\)\)\s*return "([^"]*)";' % pn, pa14)
    if not w1 or not w2 or w1.group(1) != w2.group(1):
        bad.append("(P14) LandingLine.depLabel's word for %s does not equal ProfileActivity.keptLabel's" % ln)
if 'LandingLine.cardPkgs(work, p -> ProfileActivity.appDeps(this, p), p -> hasInstalledCode(p));' not in sweep:
    bad.append('(P14) sweepAuto does not build the card list from ProfileActivity.appDeps and hasInstalledCode')
if 'ProfileActivity.appDeps(this, pkg)' not in pd or 'hasInstalledCode(dep)' not in pd:
    bad.append('(P14) pendingDeps no longer reads ProfileActivity.appDeps and hasInstalledCode, so the row can disagree')

for b in bad: print('PIN FAILED: ' + b)
if not bad: print('ok P1-P14 the LANDING flag, the sweepAuto block, the stamp, the manifest entry, the per-app broadcast, '
                  'the card, the Your apps hook and the Play services row')
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <LandingLine.java> <UnarchiveService.java> <AndroidManifest.xml> <LandingNoticeActivity.java>
  #         <ProfileActivity.java> [quiet]
  local ll=$1 us=$2 mf=$3 la=$4 pa=$5 quiet=${6:-} rc=0 prc=0 pout
  cases "$ll" "$quiet" || rc=$?
  [ "$rc" -eq 2 ] && return 2
  pout=$(pins "$us" "$mf" "$la" "$pa" "$ll" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$LL" "$US" "$MF" "$LA" "$PA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-landing-line-java: FAIL (rc $rc)"; exit 1; fi
echo "test-landing-line-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: ll|us|mf|la|pa> <python-regex> <replacement>
  local name=$1 which=$2 pat=$3 rep=$4 d src orig mll mus mmf mla mpa rc=0
  d=$(mktemp -d -p "$W") || return 1
  mll="$d/LandingLine.java"; mus="$d/UnarchiveService.java"; mmf="$d/AndroidManifest.xml"
  mla="$d/LandingNoticeActivity.java"; mpa="$d/ProfileActivity.java"
  cp "$LL" "$mll"; cp "$US" "$mus"; cp "$MF" "$mmf"; cp "$LA" "$mla"; cp "$PA" "$mpa"
  case "$which" in
    ll) src=$mll; orig=$LL ;;
    us) src=$mus; orig=$US ;;
    mf) src=$mmf; orig=$MF ;;
    la) src=$mla; orig=$LA ;;
    pa) src=$mpa; orig=$PA ;;
    *) echo "  $name: ⚠ unknown file '$which'"; fails=$((fails + 1)); rm -rf "$d"; return ;;
  esac
  python3 - "$src" "$pat" "$rep" <<'PY'
import io, re, sys
p, pat, rep = sys.argv[1:4]
s = io.open(p, encoding='utf-8').read()
io.open(p, 'w', encoding='utf-8').write(re.sub(pat, rep, s, count=1, flags=re.S))
PY
  if cmp -s "$src" "$orig"; then
    echo "  $name: ⚠ NOT APPLIED"; fails=$((fails + 1)); rm -rf "$d"; return
  fi
  suite "$mll" "$mus" "$mmf" "$mla" "$mpa" quiet; rc=$?
  if [ "$rc" -eq 1 ]; then echo "  $name: convicted"
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

echo "mutants:"
mutant "M1 show ignores landing" ll 'return landing && toFetch > 0' 'return toFetch > 0'
mutant "M2 show ignores the stamp" ll ' && !thisSignIn\.equals\(shownFor\);' ';'
mutant "M3 toFetch >= 0" ll 'toFetch > 0' 'toFetch >= 0'
mutant "M4 the netRekick block sets LANDING" us '(\n(\s*)try \{ sweepAutoJoined\(false\); \})' '\n\2LANDING.set(true);\1'
mutant "M5 the switch-landing set is LANDING.set(true)" us 'LANDING\.set\(!byHand\);' 'LANDING.set(true);'
mutant "M6 the stamp written after the start" us '(\n[^\n]*StoreInstaller\.writeAtomic\(stamp, serial\);[^\n]*)(\n[^\n]*String\[\] cardRows = [^\n]*\n[^\n]*card = LandingLine\.Sweep\.begin\([^\n]*\n[^\n]*startActivity\(.*?\)\);)' '\2\1'
mutant "M7 the manifest entry removed" mf '\n[^\n]*<activity android:name="\.LandingNoticeActivity".*?/>' ''
mutant "M8 rows shows 4 rows at total 5" ll 'ROWS_BIG = 3;' 'ROWS_BIG = 4;'
mutant "M9 rows ignores landed" ll 'if \(!landed\[i\]\) pick\[k\+\+\] = i;' 'if (true) pick[k++] = i;'
mutant "M10 moreCount counts landed apps" ll 'if \(!landed\[i\]\) left\+\+;' 'if (true) left++;'
mutant "M11 headline never says All" ll 'if \(landed == total\) return' 'if (false) return'
mutant "M12 widthPx returns the screen width" ll 'return Math\.round\(screenPx \* WIDTH_SHARE\);' 'return screenPx;'
mutant "M13 the setLayout call dropped" la '\n[^\n]*getWindow\(\)\.setLayout\(LandingLine\.widthPx\([^;]*;' ''
mutant "M14 the ACTION_APP broadcast moved into the RETRY arm" us '(\n[^\n]*i--;\n[^\n]*continue;)(.*?)(\n[^\n]*try \{\n[^\n]*sendBroadcast\(new Intent\(LandingNoticeActivity\.ACTION_APP\).*?\n[^\n]*\} catch \(Throwable t\) \{[^\n]*)' '\3\1\2'
mutant "M15 the +more row opens nothing" la '\n[^\n]*startActivity\(new Intent\(this, ProfileActivity\.class\)[^;]*;' ''
mutant "M16 ProfileActivity ignores the extra" pa '(private void openYourAppsIfAsked\(\) \{.*?)\n[^\n]*showYourApps\(\);' '\1'
mutant "M17 the first menu never honours the extra" pa '(\n[^\n]*showConfirm\(\);)\n[^\n]*openYourAppsIfAsked\(\);' '\1'
mutant "M18 the bar built outside the from-5 arm" la '(\n[^\n]*if \(!LandingLine\.big\(n\)\) \{)(.*?)(\n[^\n]*bar = new ProgressBar\(this, null, android\.R\.attr\.progressBarStyleHorizontal\);)' '\3\1\2'
mutant "M19 the card never closes after the sweep" la '\n[^\n]*handler\.postDelayed\(this::finish, LandingLine\.CLOSE_AFTER_MS\);' ''
mutant "M20 the start carries no work list" us '\n[^\n]*\.putExtra\(LandingNoticeActivity\.EXTRA_PKGS, cardRows\)' ''
mutant "M21 a failed outcome lands the app" ll 'landed\[i\] = ok;' 'landed[i] = true;'
mutant "M22 Sweep.done ignores the end" ll 'return sweep == 0 \|\| sweep != id \|\| done;' 'return sweep == 0 || sweep != id;'
mutant "M23 the card rows follow a settled set" la 'LandingLine\.rows\(pkgs, landed\)' 'LandingLine.rows(pkgs, settled)'
mutant "M24 the card count follows a settled set" la 'LandingLine\.moreCount\(pkgs, landed\)' 'LandingLine.moreCount(pkgs, settled)'
mutant "M25 the card reads the record before it registers" la '(\n[^\n]*registerReceiver\(receiver, f, Context\.RECEIVER_NOT_EXPORTED\);)(\n[^\n]*// AFTER[^\n]*)?\n([^\n]*sync\(\);)' '\n\3\1'
mutant "M26 the card never reads the record at start" la '(\n[^\n]*registerReceiver\(receiver, f, Context\.RECEIVER_NOT_EXPORTED\);)(\n[^\n]*// AFTER[^\n]*)?\n[^\n]*sync\(\);' '\1'
mutant "M27 the receiver ignores ACTION_SWEEP_DONE" la ' \|\| UnarchiveService\.ACTION_SWEEP_DONE\.equals\(a\)\) sync\(\);' ') sync();'
mutant "M28 sync never closes the card" la '\n[^\n]*if \(LandingLine\.Sweep\.done\(sweep\)\) closeSoon\(\);' ''
mutant "M29 the service broadcasts before it records" us '(\n[^\n]*LandingLine\.Sweep\.outcome\(card, pkg, ok\);)(\n[^\n]*try \{\n[^\n]*sendBroadcast\(new Intent\(LandingNoticeActivity\.ACTION_APP\).*?\n[^\n]*\} catch \(Throwable t\) \{[^\n]*)' '\2\1'
mutant "M30 the end is never recorded" us '\n[^\n]*LandingLine\.Sweep\.end\(card\);[^\n]*' ''
mutant "M31 the start carries no sweep id" us '\n[^\n]*\.putExtra\(LandingNoticeActivity\.EXTRA_SWEEP, card\)\);' ');'
# NWP-20261130-09. Each names the assertion that convicts it.
mutant "M32 no services row (C33)" ll 'new String\[\] \{GMS, GSF\}' 'new String[] {GSF}'
mutant "M33 the rows after the work list (C34)" ll '(List<String> out = new ArrayList<>\(\);)(.*?)\n[^\n]*out\.addAll\(work\);' '\1\n        out.addAll(work);\2'
mutant "M34 the list ignores hasCode (C36)" ll 'work\.contains\(dep\) \|\| hasCode\.test\(dep\)' 'work.contains(dep)'
mutant "M35 the list ignores depsOf (C35, C41)" ll 'if \(depsOf\.apply\(p\)\.contains\(dep\)\) \{' 'if (true) {'
mutant "M36 no GSF row (C37)" ll 'new String\[\] \{GMS, GSF\}' 'new String[] {GMS}'
mutant "M37 gsf before gms (C37, C39)" ll 'new String\[\] \{GMS, GSF\}' 'new String[] {GSF, GMS}'
mutant "M38 depLanded lands nothing (C42)" ll '(settled\[i\] = true;)\n[^\n]*landed\[i\] = true;' '\1'
mutant "M39 depLanded stops at a settled row (C44)" ll '!pkg\.equals\(pkgs\[i\]\) \|\| landed\[i\]' '!pkg.equals(pkgs[i]) || settled[i] || landed[i]'
mutant "M40 depLanded leaves the row unsettled (C44)" ll '\n[^\n]*settled\[i\] = true;(\n[^\n]*landed\[i\] = true;)' '\1'
mutant "M41 depLabel gives no name (C46)" ll 'if \(GMS\.equals\(pkg\)\) return "Google Play services";' 'if (GMS.equals(pkg)) return null;'
mutant "M42 the card starts with the work list (P2)" us 'EXTRA_PKGS, cardRows' 'EXTRA_PKGS, work.toArray(new String[0])'
mutant "M43 begin takes the work list (P2)" us 'Sweep\.begin\(cardRows\)' 'Sweep.begin(work.toArray(new String[0]))'
mutant "M44 the list built before the stamp (P2)" us '(\n[^\n]*StoreInstaller\.writeAtomic\(stamp, serial\);)(\n[^\n]*String\[\] cardRows = [^\n]*)' '\2\1'
mutant "M45 no tick after a dep install (P12)" us '\n[^\n]*cardDepLanded\(dep\);(\n[^\n]*qFinish\(dep\);)' '\1'
mutant "M46 the tick before the abort (P12)" us '(\n[^\n]*if \(!dok\) \{.*?)\n[^\n]*cardDepLanded\(dep\);' '\n            cardDepLanded(dep);\1'
mutant "M47 no tick in the WHOLE branch (P12)" us '(if \(action == AUTO_WHOLE\) \{)\n[^\n]*cardDepLanded\(dep\);[^\n]*' '\1'
mutant "M48 no tick in the RESTORE_ONLY branch (P12)" us '(if \(action == AUTO_RESTORE_ONLY\) \{)\n[^\n]*cardDepLanded\(dep\);[^\n]*' '\1'
mutant "M49 the helper does not broadcast (P12)" us '\n[^\n]*sendBroadcast\(new Intent\(LandingNoticeActivity\.ACTION_APP\)\.setPackage\(getPackageName\(\)\)\n[^\n]*EXTRA_PKG, dep\)[^\n]*' ''
mutant "M50 the card has no depLabel (P13)" la '\n[^\n]*if \(got == null\) got = LandingLine\.depLabel\(pkg\);' ''
mutant "M51 the label drifts from Your apps (C46, P14)" ll 'return "Google Play services";' 'return "Play Services";'
mutant "M52 gms in the work list gets a second row (C47)" ll 'if \(work\.contains\(dep\) \|\| hasCode' 'if (hasCode'
mutant "M53 the helper broadcasts for a package with no row (P12)" us 'if \(!LandingLine\.Sweep\.depLanded\(dep\)\) return;' 'LandingLine.Sweep.depLanded(dep);'
mutant "M54 the helper broadcast is not package-local (P12)" us '(ACTION_APP\))\.setPackage\(getPackageName\(\)\)(\n[^\n]*EXTRA_PKG, dep\))' '\1\2'
mutant "M55 the list reads another dep source (P14)" us 'p -> ProfileActivity\.appDeps\(this, p\)' 'p -> ProfileActivity.groupDeps(this, p)'
mutant "M56 ProfileActivity's word for gms drifts from the card's (P14)" pa 'return "Google Play services";' 'return "Play services";'
if [ "$fails" -ne 0 ]; then echo "test-landing-line-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-landing-line-java: all mutants convicted"
