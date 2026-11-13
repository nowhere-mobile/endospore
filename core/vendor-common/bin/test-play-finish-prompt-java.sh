#!/usr/bin/env bash
# test-play-finish-prompt-java.sh [--mutate] -- the one-time "Finish setting up Google Play" card, under javac
# (NWP-20261202-22).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-10 ("Create offers to finish setting up Google Play after
# the first switch-in, ...", item 1): "after the first switch-in of a profile created with Play on, the session shows
# one prompt that opens the GrapheneOS App Store at its Play entry. It is shown once per profile and is not shown when
# Play is already installed." PlayFinishPrompt (pure java) holds the rule and the words; it is compiled as-is with
# PlayChoice and PlayFinishPromptCases: decide over every marker x state x Play Store on the phone, the decided TITLE
# verbatim, the key and its values, and the popup rules (no "&", no OK or Cancel button). The PINS check the wiring
# the cases cannot see, on the sources with comments stripped:
#   Q1  PlayAtCreateReceiver.onReceive returns unless PlayAtCreate.accepts(v), then writes play.wanted, then the
#       pending marker (PlayFinishPrompt.CFG_KEY = PENDING), once.
#   Q2  UnarchiveService.onStartCommand starts PlayFinishActivity.check once, on its own daemon thread with the
#       application context, after the netRekick block returns, and the first if (...) around it is if (!byHand).
#   Q3  PlayFinishActivity.check decides from cfgStatic(play.finish), PlayChoice.effective(PlayChoice.parse(cfgStatic(
#       play.wanted)), gosStorePresent(app)) and playStoreOnPhone(app); SETTLE writes DONE; SHOW starts the card with
#       FLAG_ACTIVITY_NEW_TASK; playStoreOnPhone asks PM for Play Store, archived placeholders included.
#   Q4  the card writes DONE only from markDone, and calls markDone only from onResume behind a once-flag (doneSent)
#       that onCreate restores and onSaveInstanceState saves; it shows TITLE and the three DRAFT words; its open button
#       starts ProfileActivity with EXTRA_OPEN = OPEN_PLAY and FLAG_ACTIVITY_NEW_TASK, then finishes; every log line is
#       a fixed string.
#   Q5  ProfileActivity.openYourAppsIfAsked honours OPEN_PLAY with OPEN_YOUR_APPS: removeExtra, then showYourApps()
#       once, then openGosStore() once, under if (PlayFinishPrompt.OPEN_PLAY.equals(open)).
#   Q6  the manifest declares PlayFinishActivity once, exported="false", excluded from recents.
# The merger's full javac / `m NowhereChooser` covers PlayFinishActivity and the edited files themselves.
#
# What it does NOT prove: the handset run (lynx: Create with Play on shows the card once after switch-in, logcat
# `play finish: showing`; Open App Store reaches the store; the next sign-in shows nothing). That is the backlog row's
# CLOSES WHEN.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-play-finish-prompt-java.sh            # the cases and the pins
#   bash test-play-finish-prompt-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
CLS="$SRCDIR/PlayFinishPrompt.java"
PCH="$SRCDIR/PlayChoice.java"
RCV="$SRCDIR/PlayAtCreateReceiver.java"
SVC="$SRCDIR/UnarchiveService.java"
ACT="$SRCDIR/PlayFinishActivity.java"
PRO="$SRCDIR/ProfileActivity.java"
MAN="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/play-finish-prompt/PlayFinishPromptCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: this suite needs python3" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }

# pins <PlayAtCreateReceiver.java> <UnarchiveService.java> <PlayFinishActivity.java> <ProfileActivity.java> <manifest>
#   -> 0 ok, 1 a pin failed, 2 a control failed. A missing file reads as empty, so its pins fail (rc 1).
pins() {
  python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import io, os, re, sys
rcv_path, svc_path, act_path, pro_path, man_path = sys.argv[1:6]

def read(p):
    return io.open(p, encoding='utf-8').read() if os.path.exists(p) else ''

def strip_comments(src):
    """Drop line and block comments; keep string and char literals. Whitespace is kept."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1]); i = j + 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(' '); continue
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

def close_of(m, o):
    """Index of the } that closes the { at o in the masked text m, or -1."""
    d = 0
    for k in range(o, len(m)):
        if m[k] == '{': d += 1
        elif m[k] == '}':
            d -= 1
            if d == 0: return k
    return -1

def method(code, sig):
    """The member from sig to its closing brace (literals masked), or '' when sig is not there exactly once."""
    if code.count(sig) != 1: return ''
    m = mask(code); i = code.index(sig); o = code.index('{', i); c = close_of(m, o)
    return code[i:c + 1] if c >= 0 else ''

flat = lambda s: re.sub(r'\s+', '', s or '')
fails = []
def pin(name, ok, why):
    if ok: print('  ok    ' + name)
    else: print('  PIN   ' + name + ': ' + why); fails.append(name)

rcv = strip_comments(read(rcv_path))
svc = strip_comments(read(svc_path))
act = strip_comments(read(act_path))
pro = strip_comments(read(pro_path))
man = read(man_path)

# Controls: the files this suite reads that exist before this slice.
for label, code, sig in [
    ('PlayAtCreateReceiver.onReceive', rcv, 'public void onReceive(Context ctx, Intent intent) {'),
    ('UnarchiveService.onStartCommand', svc, 'public int onStartCommand('),
    ('ProfileActivity.openYourAppsIfAsked', pro, 'private void openYourAppsIfAsked() {'),
]:
    if method(code, sig) == '':
        print('  CONTROL %s not found exactly once (or its braces do not balance)' % label); sys.exit(2)
if '<application' not in man:
    print('  CONTROL the manifest has no <application'); sys.exit(2)

# Q1: the receiver
orc = flat(method(rcv, 'public void onReceive(Context ctx, Intent intent) {'))
gate = orc.find('if(!PlayAtCreate.accepts(v))return;')
put = orc.find('ProfileActivity.cfgPutStatic(ctx,PlayChoice.CFG_KEY,v);')
MK = 'ProfileActivity.cfgPutStatic(ctx,PlayFinishPrompt.CFG_KEY,PlayFinishPrompt.PENDING);'
mk = orc.find(MK)
pin('Q1 onReceive writes the pending marker once', orc.count(MK) == 1, 'marker writes=%d' % orc.count(MK))
pin('Q1 the marker is written after the accepts return and after play.wanted',
    0 <= gate < put < mk, 'accepts at %d, play.wanted at %d, marker at %d' % (gate, put, mk))

# Q2: the switch-landing start
msvc = mask(svc)
calls = [x.start() for x in re.finditer(r'PlayFinishActivity\.check\(', msvc)]
pin('Q2 UnarchiveService starts PlayFinishActivity.check exactly once', len(calls) == 1, 'calls=%d' % len(calls))
if len(calls) == 1:
    c = calls[0]
    so = msvc.find('{', svc.index('public int onStartCommand(')); sc = close_of(msvc, so)
    nr = re.search(r'if \(netRekick\) \{', msvc[so:sc])
    nc = close_of(msvc, so + nr.end() - 1) if nr else -1
    pin('Q2 the check is inside onStartCommand, after the netRekick block (which returns)',
        so < c < sc and nr is not None and re.search(r'\breturn;', msvc[so + nr.end():nc]) is not None and nc < c,
        'onStartCommand %d-%d, netRekick close %d, check %d' % (so, sc, nc, c))
    opens, d = [], 0
    for k in range(c, so, -1):
        if msvc[k] == '}': d += 1
        elif msvc[k] == '{':
            if d == 0: opens.append(k)
            else: d -= 1
    guard = None
    for o in opens:
        k = o - 1
        while k >= 0 and msvc[k] not in ';{}': k -= 1
        h = ' '.join(svc[k + 1:o].split())
        if h.startswith('if'):
            guard = (o, h); break
    pin('Q2 the first if (...) around the check is if (!byHand)', guard is not None and guard[1] == 'if (!byHand)',
        'guard=%r' % (guard[1] if guard else None))
    blk = svc[guard[0]:close_of(msvc, guard[0]) + 1] if guard else ''
    fb = flat(blk)
    th = re.search(r'Thread(\w+)=newThread\(\(\)->PlayFinishActivity\.check\((\w+)\),"nowhere-play-finish"\);', fb)
    pin('Q2 the check runs on its own new Thread', th is not None, 'no new Thread(() -> PlayFinishActivity.check(..))')
    if th:
        pin('Q2 that thread is a daemon thread and is started',
            (th.group(1) + '.setDaemon(true);') in fb and (th.group(1) + '.start();') in fb, 'setDaemon/start missing')
        pin('Q2 the check gets the application context',
            ('finalandroid.content.Context' + th.group(2) + '=getApplicationContext();') in fb, 'no application context')
else:
    pin('Q2 the check is placed', False, 'not exactly one call')

# Q3: check() and playStoreOnPhone
chk = flat(method(act, 'static void check(Context app) {'))
DEC = ('PlayFinishPrompt.Verdictv=PlayFinishPrompt.decide(ProfileActivity.cfgStatic(app,PlayFinishPrompt.CFG_KEY),'
       'PlayChoice.effective(PlayChoice.parse(ProfileActivity.cfgStatic(app,PlayChoice.CFG_KEY)),'
       'ProfileActivity.gosStorePresent(app)),playStoreOnPhone(app));')
pin('Q3 check decides once from the marker, the effective play.wanted and Play Store on the phone',
    chk.count(DEC) == 1 and chk.count('decide(') == 1, 'want exactly ' + DEC)
st = chk.find('if(v==PlayFinishPrompt.Verdict.SETTLE){')
sh = chk.find('}elseif(v==PlayFinishPrompt.Verdict.SHOW){')
settle = chk[st:sh] if 0 <= st < sh else ''
show = chk[sh:] if sh >= 0 else ''
pin('Q3 SETTLE writes DONE', settle.count('ProfileActivity.cfgPutStatic(app,PlayFinishPrompt.CFG_KEY,PlayFinishPrompt.DONE);') == 1,
    'SETTLE branch: ' + settle[:200])
pin('Q3 SHOW starts the card with FLAG_ACTIVITY_NEW_TASK, and writes nothing',
    'app.startActivity(newIntent(app,PlayFinishActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));' in show
    and 'cfgPut' not in show, 'SHOW branch: ' + show[:200])
pin('Q3 check writes only on SETTLE', chk.count('cfgPutStatic(') == 1, 'cfgPutStatic=%d' % chk.count('cfgPutStatic('))
psp = flat(method(act, 'static boolean playStoreOnPhone(Context ctx) {'))
pin('Q3 playStoreOnPhone asks PM for Play Store, installed then archived',
    psp.count('pm.getApplicationInfo(PlayChoice.VENDING,0);returntrue;') == 1
    and 'pm.getApplicationInfo(PlayChoice.VENDING,PackageManager.ApplicationInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES));returntrue;' in psp,
    psp[:300])

# Q4: the card
mact = mask(act)
def span(sig):
    hits = [x for x in re.finditer(sig, mact, re.M)]
    if len(hits) != 1: return (-1, -1)
    o = mact.index('{', hits[0].end() - 1)
    return (o, close_of(mact, o))
meth = {
    'onCreate': span(r'^    @Override protected void onCreate\('),
    'onResume': span(r'^    @Override protected void onResume\('),
    'onSaveInstanceState': span(r'^    @Override protected void onSaveInstanceState\('),
    'markDone': span(r'^    private static void markDone\('),
    'check': span(r'^    static void check\('),
}
def inside(pos):
    return [k for k, (o, e) in meth.items() if o < pos < e]
done = [x.start() for x in re.finditer(r'PlayFinishPrompt\.DONE\b', mact)]
pin('Q4 DONE is written only from check (SETTLE) and markDone',
    sorted(sum((inside(p) for p in done), [])) == ['check', 'markDone'], 'DONE in %r' % [inside(p) for p in done])
decl = re.search(r'^    private static void markDone\(', mact, re.M)
md = [x.start() for x in re.finditer(r'\bmarkDone\(', mact) if not decl or x.start() != decl.start() + len('    private static void ')]
pin('Q4 markDone is called, and only from onResume', len(md) == 1 and inside(md[0]) == ['onResume'],
    'calls in %r' % [inside(p) for p in md])
ro, re_ = meth['onResume']
rb = flat(act[ro:re_ + 1]) if ro >= 0 else ''
g = rb.find('if(!doneSent){'); s = rb.find('doneSent=true;'); t = rb.find('newThread(()->markDone(')
pin('Q4 onResume tests !doneSent, sets it, then starts markDone on a new daemon thread',
    0 <= g < s < t and '.setDaemon(true);' in rb and '.start();' in rb, rb[:300])
co, ce = meth['onCreate']
cb = flat(act[co:ce + 1]) if co >= 0 else ''
oo, oe = meth['onSaveInstanceState']
ob = flat(act[oo:oe + 1]) if oo >= 0 else ''
pin('Q4 onCreate restores the flag and onSaveInstanceState saves it',
    'doneSent=b!=null&&b.getBoolean(STATE_DONE_SENT,false);' in cb and 'out.putBoolean(STATE_DONE_SENT,doneSent);' in ob,
    'restore/save missing')
for w in ('TITLE', 'DRAFT_BODY', 'DRAFT_OPEN', 'DRAFT_LATER'):
    pin('Q4 the card shows PlayFinishPrompt.' + w, cb.count('.setText(PlayFinishPrompt.%s);' % w) == 1, 'not once in onCreate')
pin('Q4 the open button runs openStore and Not now only finishes',
    'open.setOnClickListener(v->openStore());' in cb and 'later.setOnClickListener(v->finish());' in cb, 'listeners')
osb = flat(method(act, 'private void openStore() {'))
OPEN = ('startActivity(newIntent(this,ProfileActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)'
        '.putExtra(LandingLine.EXTRA_OPEN,PlayFinishPrompt.OPEN_PLAY));')
pin('Q4 openStore starts ProfileActivity with EXTRA_OPEN = OPEN_PLAY, then finishes',
    osb.count(OPEN) == 1 and osb.find(OPEN) < osb.rfind('finish();'), osb[:300])
logs = re.findall(r'Log\.[iwed]\(([^;]*)\);', act)
bad = [l for l in logs if not re.fullmatch(r'\s*"NowhereChooser",\s*"[^"]*"(,\s*t)?\s*', l)]
pin('Q4 every log line in PlayFinishActivity is a fixed string', logs != [] and bad == [], 'not fixed: %r' % bad)

# Q5: ProfileActivity.openYourAppsIfAsked
oy = flat(method(pro, 'private void openYourAppsIfAsked() {'))
GUARD = '||!(LandingLine.OPEN_YOUR_APPS.equals(open)||PlayFinishPrompt.OPEN_PLAY.equals(open)))return;'
rx = oy.find('in.removeExtra(LandingLine.EXTRA_OPEN);'); sy = oy.find('showYourApps();')
GO = 'if(PlayFinishPrompt.OPEN_PLAY.equals(open))openGosStore();'
pin('Q5 openYourAppsIfAsked reads EXTRA_OPEN once and honours OPEN_PLAY with OPEN_YOUR_APPS',
    oy.count('Stringopen=in==null?null:in.getStringExtra(LandingLine.EXTRA_OPEN);') == 1 and oy.count(GUARD) == 1, oy[:400])
pin('Q5 removeExtra, then showYourApps() once, then openGosStore() once, only for OPEN_PLAY',
    oy.count('showYourApps();') == 1 and oy.count('openGosStore();') == 1 and oy.count(GO) == 1
    and 0 <= rx < sy < oy.find(GO), 'removeExtra %d, showYourApps %d, openGosStore %d' % (rx, sy, oy.find(GO)))

# Q6: the manifest
ents = re.findall(r'<activity\b[^>]*android:name="\.PlayFinishActivity"[^>]*>', man)
pin('Q6 the manifest declares PlayFinishActivity once', man.count('".PlayFinishActivity"') == 1 and len(ents) == 1,
    'declarations=%d' % man.count('".PlayFinishActivity"'))
pin('Q6 PlayFinishActivity is exported="false" and excluded from recents',
    len(ents) == 1 and 'android:exported="false"' in ents[0] and 'android:excludeFromRecents="true"' in ents[0]
    and ents[0].count('android:exported=') == 1, ents[0] if ents else 'absent')

if fails:
    print('  %d pin(s) failed' % len(fails)); sys.exit(1)
print('  pins ok')
PY
}

# suite <PlayFinishPrompt.java> <receiver> <service> <PlayFinishActivity.java> <ProfileActivity.java> <manifest>
#   -> 0 ok, 1 a case or pin failed, 2 the suite could not run (a control, or a copy that does not compile)
suite() {
  local cls="$1" rcv="$2" svc="$3" act="$4" pro="$5" man="$6" d rc_c=0 rc_p
  d=$(mktemp -d -p "$W")
  if [ ! -f "$cls" ]; then
    echo "  FAIL  cases: PlayFinishPrompt.java is absent"; rc_c=1
  else
    mkdir -p "$d/src" "$d/out"
    cp "$cls" "$d/src/PlayFinishPrompt.java"; cp "$PCH" "$d/src/PlayChoice.java"
    cp "$CASES" "$d/src/PlayFinishPromptCases.java"
    if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/PlayFinishPrompt.java" "$d/src/PlayChoice.java" \
        "$d/src/PlayFinishPromptCases.java" >"$d/javac.out" 2>&1; then
      echo "  BROKEN: the cases do not compile"; sed 's/^/      /' "$d/javac.out" | head -10; return 2
    fi
    "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.PlayFinishPromptCases || rc_c=1
  fi
  pins "$rcv" "$svc" "$act" "$pro" "$man"; rc_p=$?
  [ "$rc_p" = 2 ] && return 2
  [ "$rc_c" = 0 ] && [ "$rc_p" = 0 ] && return 0
  return 1
}

echo "== $CLS + $RCV + $SVC + $ACT + $PRO + $MAN"
suite "$CLS" "$RCV" "$SVC" "$ACT" "$PRO" "$MAN"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc=$rc)"; [ "$rc" = 1 ] && exit 1 || exit 2; }
echo "  cases and pins ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only; one that does not apply or compile fails)"
fails=0
# mut <label> <target: cls|rcv|svc|act|pro|man> <perl-expr> [expect: convict|pass]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-convict}" d rc c r s a p m t orig
  d=$(mktemp -d -p "$W"); c="$d/PlayFinishPrompt.java"; r="$d/PlayAtCreateReceiver.java"; s="$d/UnarchiveService.java"
  a="$d/PlayFinishActivity.java"; p="$d/ProfileActivity.java"; m="$d/AndroidManifest.xml"
  cp "$CLS" "$c"; cp "$RCV" "$r"; cp "$SVC" "$s"; cp "$ACT" "$a"; cp "$PRO" "$p"; cp "$MAN" "$m"
  case "$target" in cls) t="$c"; orig="$CLS" ;; rcv) t="$r"; orig="$RCV" ;; svc) t="$s"; orig="$SVC" ;;
    act) t="$a"; orig="$ACT" ;; pro) t="$p"; orig="$PRO" ;; man) t="$m"; orig="$MAN" ;; esac
  if ! perl -0pi -e "$expr" "$t"; then echo "  ERROR     $label -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$t" "$orig"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  suite "$c" "$r" "$s" "$a" "$p" "$m" >"$d/out" 2>&1; rc=$?
  if [ "$expect" = pass ]; then
    if [ "$rc" = 0 ]; then echo "  passes    $label (a correct rewrite, as it must)"
    else echo "  FALSE     $label convicted a correct rewrite (rc $rc)"; grep -E 'PIN|FAIL' "$d/out" | head -5; fails=$((fails+1)); fi
    return
  fi
  case "$rc" in
    1) echo "  CONVICTED $label" ;;
    0) echo "  SURVIVED  $label"; fails=$((fails+1)) ;;
    *) echo "  BROKEN    $label -- the mutant did not compile or extract (rc $rc)"; tail -3 "$d/out" | sed 's/^/      /'; fails=$((fails+1)) ;;
  esac
}
mut 'M1 decide shows on any marker (cases C1/C2)' cls 's/\n\s*if \(!PENDING\.equals\(marker\)\) return Verdict\.NONE;//'
mut 'M2 decide shows with Play Store on the phone (cases C1/C2)' cls 's/\n\s*if \(playStoreOnPhone\) return Verdict\.SETTLE;//'
mut 'M3 decide shows with Play absent (cases C1/C2)' cls 's/effective != PlayChoice\.State\.ON/effective == PlayChoice.State.OFF/'
mut 'M3b decide shows with Play off or absent (cases C1/C2)' cls 's/\n\s*if \(effective != PlayChoice\.State\.ON\) return Verdict\.SETTLE;//'
mut 'M4 the receiver writes no marker (Q1)' rcv 's/\n\s*ProfileActivity\.cfgPutStatic\(ctx, PlayFinishPrompt\.CFG_KEY, PlayFinishPrompt\.PENDING\);//'
mut 'M5 the marker written before the accepts check (Q1)' rcv 's/(\n\s*if \(!PlayAtCreate\.accepts\(v\)\) return;)(.*?)(\n\s*ProfileActivity\.cfgPutStatic\(ctx, PlayFinishPrompt\.CFG_KEY, PlayFinishPrompt\.PENDING\);)/$3$1$2/s'
mut 'M6 SETTLE writes nothing (Q3, Q4)' act 's/\n\s*ProfileActivity\.cfgPutStatic\(app, PlayFinishPrompt\.CFG_KEY, PlayFinishPrompt\.DONE\);\n(\s*android\.util\.Log\.i\("NowhereChooser", "play finish: settled"\);)/\n$1/'
mut 'M7 onResume records nothing (Q4)' act 's/Thread th = new Thread\(\(\) -> markDone\(app\), "nowhere-play-finish-done"\);/Thread th = new Thread(() -> { }, "nowhere-play-finish-done");/'
mut 'M7b the once-flag is not restored (Q4)' act 's/doneSent = b != null && b\.getBoolean\(STATE_DONE_SENT, false\);/doneSent = false;/'
mut 'M8 check() moved out of if (!byHand) (Q2)' svc 's/(\n(\s*)if \(!byHand\) \{\n)(\s*\/\/ NWP-20261202-22[^\n]*\n[^\n]*\n\s*try \{\n\s*final android\.content\.Context playCtx.*?"play finish start", t\); \}\n)/\n$3$1/s'
mut 'M8b check() run on the sweep thread, not its own (Q2)' svc 's/Thread pf = new Thread\(\(\) -> PlayFinishActivity\.check\(playCtx\), "nowhere-play-finish"\);\n\s*pf\.setDaemon\(true\);\n\s*pf\.start\(\);/PlayFinishActivity.check(playCtx);/'
mut 'M9 OPEN_PLAY ignored: no openGosStore (Q5)' pro 's/\n\s*if \(PlayFinishPrompt\.OPEN_PLAY\.equals\(open\)\) openGosStore\(\);//'
mut 'M9b OPEN_PLAY dropped from the guard (Q5)' pro 's/!\(LandingLine\.OPEN_YOUR_APPS\.equals\(open\) \|\| PlayFinishPrompt\.OPEN_PLAY\.equals\(open\)\)/!LandingLine.OPEN_YOUR_APPS.equals(open)/'
mut 'M9c openGosStore for every open extra (Q5)' pro 's/if \(PlayFinishPrompt\.OPEN_PLAY\.equals\(open\)\) openGosStore\(\);/openGosStore();/'
mut 'M10 manifest exported="true" (Q6)' man 's/(<activity android:name="\.PlayFinishActivity") android:exported="false"/$1 android:exported="true"/'
mut 'M11 TITLE changed (cases C3)' cls 's/TITLE = "Finish setting up Google Play";/TITLE = "Set up Google Play";/'
mut 'M12 the open button sends OPEN_YOUR_APPS (Q4)' act 's/putExtra\(LandingLine\.EXTRA_OPEN, PlayFinishPrompt\.OPEN_PLAY\)/putExtra(LandingLine.EXTRA_OPEN, LandingLine.OPEN_YOUR_APPS)/'
mut 'M13 SHOW also writes DONE (Q3)' act 's/(\n(\s*)android\.util\.Log\.i\("NowhereChooser", "play finish: showing"\);)/\n$2ProfileActivity.cfgPutStatic(app, PlayFinishPrompt.CFG_KEY, PlayFinishPrompt.DONE);$1/'
mut 'M14 a log line names a variable (Q4)' act 's/"play finish: settled"\)/"play finish: settled " + app)/'
mut 'M15 check reads play.wanted raw, not effective (Q3)' act 's/PlayChoice\.effective\(PlayChoice\.parse\(ProfileActivity\.cfgStatic\(app, PlayChoice\.CFG_KEY\)\),\n\s*ProfileActivity\.gosStorePresent\(app\)\)/PlayChoice.parse(ProfileActivity.cfgStatic(app, PlayChoice.CFG_KEY))/'
mut 'M16 playStoreOnPhone ignores archived placeholders (Q3)' act 's/PackageManager\.ApplicationInfoFlags\.of\(PackageManager\.MATCH_ARCHIVED_PACKAGES\)/PackageManager.ApplicationInfoFlags.of(0)/'
mut 'probe: a comment line inside the if (!byHand) block (must pass)' svc 's/(\n(\s*)if \(!byHand\) \{\n)(\s*\/\/ NWP-20261202-22)/$1$2    \/\/ probe\n$3/' pass
mut 'probe: the open start split over more lines (must pass)' act 's/\.putExtra\(LandingLine\.EXTRA_OPEN, PlayFinishPrompt\.OPEN_PLAY\)\);/.putExtra(LandingLine.EXTRA_OPEN,\n                            PlayFinishPrompt.OPEN_PLAY));/' pass
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
