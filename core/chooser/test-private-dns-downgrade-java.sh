#!/usr/bin/env bash
# test-private-dns-downgrade-java.sh [--mutate] -- NWP-20261122-07: the gate's blocked-encrypted-DNS prompt, its
# marker and the restore (Q028 2026-10-20; h49 #2 2026-10-31, draft A and rule (ii); h50 #4 2026-11-01, A1 and B1).
#
# WHY. Provision sets strict private DNS (hostname mode). On a network that blocks DoT every lookup fails, the network
# never validates, and the gate and every session stay offline there with no way out. The gate now asks; "Continue
# without encryption" writes the marker, then private DNS Off (never the opportunistic mode); at every start and every
# network change strict mode comes back only when the marker is there, then the marker goes.
#
# WHAT RUNS. PrivateDnsDowngrade (pure Java) is compiled with tests/private-dns-downgrade/PrivateDnsDowngradeCases.java
# ALONE and RUN: blocked, prompt (the gate in front, the declined network, a new network), the downgrade's order and
# value, the restore with and without the marker, a downgrade then a restart, the Gate's callback sequences (RF-001),
# and the decided words. The words are read from h49 #2 in docs/product-decisions.md by this suite AND held here as literals, so a drift in either fails.
# WHAT IS PINNED BY ANCHOR (PrivateDnsWatch, ChooserActivity and NowhereApp need the Android SDK): (P1) start returns
# outside user 0 first; (P2) start restores before it registers the network callback; (P3/P4) onAvailable and onLost
# restore; (P5) no opportunistic literal in either new file; (P6) the reflection fallback is false; (P7)
# ChooserActivity.onCreate starts the watcher after its user-0 guard; (P8) the marker path, Settings.Global.putString,
# and no mode literal in the watcher; (P9) the buttons and the dismissal go through the Gate by token; (P10)
# NowhereApp.onCreate starts the watcher; (P11) start takes a Context and watches the gate through the Application;
# (P12) every network and gate callback feeds PrivateDnsDowngrade.Gate. The merger's full javac covers them.
# RF-001: the Gate (pure) runs callback SEQUENCES in the cases: a new default network, a lost one, the signal clearing
# and the gate leaving the front each close the dialog, and a closed dialog's Continue writes nothing.
#
# NWP-20261127-07 (h50 #4 A1): the session half. The prompt has ONE surface: the resumed gate, the roamed user in front
# (its uid), or none. The cases run surface() and the sequences S1-S8: (S1) blocked with a session in front shows there;
# (S2) session -> gate dismisses and shows on the gate with a new token; (S3) the old token's Continue and Stay do
# nothing after S2; (S4) Continue from the session token writes the marker, then off, and the next network restores;
# (S5) Stay private from the session holds on that network only; (S6) session A -> session B moves the prompt; (S7) NONE
# shows nothing; (S8) a Gate first fed a session (a process born mid-session) shows there. Pinned by anchor (Android
# SDK classes): (P13) the manifest declares PrivateDnsPromptActivity and PrivateDnsChoiceReceiver exported="false";
# (P14) start feeds the current user after the restore and before it registers the ACTION_USER_SWITCHED receiver, which
# feeds each switch; (P15) the receiver's user-0 guard is its first statement, before PrivateDnsWatch.onChoice, and
# onChoice refuses an unstarted watch and goes through the Gate by token; (P16) the notification's PendingIntent is
# FLAG_IMMUTABLE and built from the session user's context, carrying the token to PrivateDnsPromptActivity; (P17) the
# notification and the session dialog use the decided words through PrivateDnsDowngrade (no literal copy); (P18) no new
# file path (P8's marker stays the only one), and the session dialog sends only from its buttons; (P19) a closed prompt
# cancels the notification in the user it went to, and a choice cancels only its own token's.
# RF-001 (review of NWP-20261127-07): the session dialog lives in another user's process and can outlive user 0's
# process. (R1) a Gate born after a restart issues no token an earlier Gate gave out: a retained dialog's Continue on a
# new network writes nothing, and the new prompt still works. (P20) the token is a long end to end and each Gate seeds
# it at random, in RAM.
#
# What this does NOT prove: the broken signal on a DoT-blocking network, the dialog on the gate, validation after
# "Continue", the notification in a real session's shade, the tap opening the dialog there, the broadcast reaching
# user 0, and both handset runs (at the gate, and joining a DoT-blocking network while signed in). Those stay on the
# backlog row.
#
#   bash test-private-dns-downgrade-java.sh              # the cases and the pins
#   bash test-private-dns-downgrade-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
DOC="$HERE/../../docs/product-decisions.md"
CASES="$HERE/tests/private-dns-downgrade/PrivateDnsDowngradeCases.java"
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
  echo "test-private-dns-downgrade-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

DG="$SRC/PrivateDnsDowngrade.java"; PW="$SRC/PrivateDnsWatch.java"
CA="$SRC/ChooserActivity.java"; NAPP="${NAPP:-$SRC/NowhereApp.java}"
MF="$HERE/AndroidManifest.xml"; PA="$SRC/PrivateDnsPromptActivity.java"; PR="$SRC/PrivateDnsChoiceReceiver.java"
for f in "$DG" "$PW" "$CA" "$NAPP" "$MF" "$PA" "$PR" "$CASES" "$DOC"; do
  if [ ! -f "$f" ]; then echo "test-private-dns-downgrade-java: FAIL -- $f is missing"; exit 2; fi
done

# The expected words, one per line (UTF-8): title, body, continue, stay. Read from h49 #2 and checked against the
# literals below; a file, not argv, so the locale cannot mangle them.
EXP="$W/expected.txt"
python3 - "$DOC" "$EXP" <<'PY'
import io, re, sys
doc = io.open(sys.argv[1], encoding='utf-8').read()
head = '## 2026-10-31 — DECIDED: thirteen answers to harvest 49'
if doc.count(head) != 1:
    print("EXTRACTION FAILED: the h49 entry heading occurs %d times" % doc.count(head)); sys.exit(2)
sec = doc[doc.index(head):]
nxt = sec.find('\n## ', 1)
sec = sec if nxt < 0 else sec[:nxt]
m = re.search(r'^2\. (.*)$', sec, re.M)
if not m:
    print("EXTRACTION FAILED: no item 2. in the h49 entry"); sys.exit(2)
item = m.group(1)
title = re.search(r'Title \*"([^"]*)"\*', item)
body = re.search(r'body \*"([^"]*)"\*', item)
btns = re.search(r'buttons \*"([^"]*)"\* and \*"([^"]*)"\*', item)
if not (title and body and btns):
    print("EXTRACTION FAILED: could not extract the title, the body or the buttons from h49 #2"); sys.exit(2)
got = [title.group(1), body.group(1), btns.group(1), btns.group(2)]
lit = [
    'This network blocks encrypted DNS',
    'Nothing can connect here while lookups stay private. If you continue, whoever runs this network (at work, your '
    'employer) can see the name of every site and service this phone looks up while it is on it. This covers the whole '
    'phone, including a profile that is signed in. Private lookups come back when you leave this network.',
    'Continue without encryption',
    'Stay private',
]
names = ['title', 'body', 'continue', 'stay']
bad = [i for i in range(4) if got[i] != lit[i]]
for i in bad: print("DOC DRIFT: h49 #2's %s is %r, this suite holds %r" % (names[i], got[i], lit[i]))
if bad: sys.exit(1)
io.open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(got) + '\n')
PY
rc=$?
if [ "$rc" -ne 0 ]; then echo "test-private-dns-downgrade-java: FAIL -- the h49 #2 words (rc $rc)"; exit "$rc"; fi
echo "ok the h49 #2 words match the literals"

cases() { # cases <PrivateDnsDowngrade.java> [quiet]: 0 pass, 1 a case failed, 2 did not compile
  local dg=$1 quiet=${2:-} cls out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$dg" "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.PrivateDnsDowngradeCases "$EXP" 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <PrivateDnsDowngrade.java> <PrivateDnsWatch.java> <ChooserActivity.java> <NowhereApp.java>
       #      <AndroidManifest.xml> <PrivateDnsPromptActivity.java> <PrivateDnsChoiceReceiver.java>
  python3 - "$@" "$EXP" <<'PY'
import io, re, sys
dg_raw, pw_raw, ca_raw, na_raw, mf_raw, pa_raw, pr_raw = [io.open(p, encoding='utf-8').read() for p in sys.argv[1:8]]
words = [w for w in io.open(sys.argv[8], encoding='utf-8').read().split('\n') if w]

def strip(s):
    """Drop // and /* */ comments; string and char literals are kept."""
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

def body(src, sig, what):
    k = len(re.findall(sig, src))
    if k != 1:
        print("EXTRACTION FAILED: %s: %r occurs %d times" % (what, sig, k)); sys.exit(2)
    m = re.search(sig, src)
    j = src.index('{', m.end() - 1)
    d = 0
    for k in range(j, len(src)):
        if src[k] == '{': d += 1
        elif src[k] == '}':
            d -= 1
            if d == 0: return src[j:k + 1]
    print("EXTRACTION FAILED: %s: unbalanced braces after %r" % (what, sig)); sys.exit(2)

pw, ca, na, pa, pr = strip(pw_raw), strip(ca_raw), strip(na_raw), strip(pa_raw), strip(pr_raw)
bad = []

start = body(pw, r'static void start\((?:android\.content\.)?Context ctx\) \{', 'PrivateDnsWatch.start')
# P1 the user-0 guard is start's first statement
if not re.match(r'\{\s*if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;', start):
    bad.append('(P1) PrivateDnsWatch.start does not return outside user 0 as its first statement')
# P2 the restore runs at start, before the network callback is registered
r, g = start.find('PrivateDnsDowngrade.restoreIfMarked(io);'), start.find('registerDefaultNetworkCallback(')
if r < 0 or g < 0 or r > g:
    bad.append('(P2) start does not call PrivateDnsDowngrade.restoreIfMarked before registerDefaultNetworkCallback')
# P3 / P4 every network change restores
if 'PrivateDnsDowngrade.restoreIfMarked(io);' not in body(pw, r'public void onAvailable\(Network n\) \{', 'onAvailable'):
    bad.append('(P3) onAvailable does not call PrivateDnsDowngrade.restoreIfMarked')
if 'PrivateDnsDowngrade.restoreIfMarked(io);' not in body(pw, r'public void onLost\(Network n\) \{', 'onLost'):
    bad.append('(P4) onLost does not call PrivateDnsDowngrade.restoreIfMarked')
# P5 B1: never the opportunistic mode, comments included
for name, raw in (('PrivateDnsDowngrade.java', dg_raw), ('PrivateDnsWatch.java', pw_raw)):
    if re.search(r'opportunistic', raw, re.I):
        bad.append('(P5) %s holds an opportunistic literal' % name)
# P6 the hidden method, and every fallback reads false
pb = body(pw, r'static boolean privateDnsBroken\(NetworkCapabilities nc\) \{', 'privateDnsBroken')
if 'getMethod("isPrivateDnsBroken")' not in pb:
    bad.append('(P6) privateDnsBroken does not reflect on isPrivateDnsBroken')
rets = re.findall(r'return ([^;]*);', pb)
if rets != ['false', 'Boolean.TRUE.equals(brokenMethod.invoke(nc))', 'false']:
    bad.append('(P6) privateDnsBroken returns %r, want false on null, the invoke result, false on a failure' % rets)
# P7 the gate's onCreate starts the watcher after its user-0 guard
oc = body(ca, r'protected void onCreate\(Bundle b\) \{', 'ChooserActivity.onCreate')
gd, st = oc.find('if (android.os.UserHandle.myUserId() != 0) {'), oc.find('PrivateDnsWatch.start(this);')
if gd < 0 or st < 0 or st < gd or oc.count('PrivateDnsWatch.start(this);') != 1:
    bad.append('(P7) ChooserActivity.onCreate does not start PrivateDnsWatch once, after its user-0 guard')
# P8 the marker, the settings write, and no mode literal of the watcher's own
if 'new java.io.File(app.getFilesDir(), "dns-downgraded")' not in pw:
    bad.append('(P8) PrivateDnsWatch does not name the marker new java.io.File(app.getFilesDir(), "dns-downgraded")')
if 'Settings.Global.putString(' not in pw:
    bad.append('(P8) PrivateDnsWatch does not write through Settings.Global.putString')
if re.search(r'"(?:off|hostname)"', pw):
    bad.append('(P8) PrivateDnsWatch holds a mode literal of its own')
# P9 the buttons
if 'setPositiveButton(PrivateDnsDowngrade.CONTINUE, (d, w) -> gate.onContinue(token))' not in pw:
    bad.append('(P9) the Continue button does not go through gate.onContinue(token)')
if 'setNegativeButton(PrivateDnsDowngrade.STAY, (d, w) -> gate.onStay(token))' not in pw:
    bad.append('(P9) the Stay button does not go through gate.onStay(token)')
if 'setOnDismissListener(d -> gate.onDismissed(token))' not in pw:
    bad.append('(P9) the dismissal does not go through gate.onDismissed(token)')
if re.search(r'PrivateDnsDowngrade\.downgrade\(', pw):
    bad.append('(P9) PrivateDnsWatch calls PrivateDnsDowngrade.downgrade itself, around the Gate')
# P10 every process birth starts the watcher
if body(na, r'public void onCreate\(\) \{', 'NowhereApp.onCreate').count('PrivateDnsWatch.start(this);') != 1:
    bad.append('(P10) NowhereApp.onCreate does not call PrivateDnsWatch.start(this) exactly once')
# P11 start works from any Context, and watches the gate through the Application
if 'ctx.getApplicationContext()' not in start or 'registerActivityLifecycleCallbacks(' not in start:
    bad.append('(P11) start does not use ctx.getApplicationContext() and registerActivityLifecycleCallbacks')
# P12 RF-001: every callback feeds the Gate; a new default network reaches it before the restore
oa = body(pw, r'public void onAvailable\(Network n\) \{', 'onAvailable')
if not re.match(r'\{\s*if \(!gate\.onAvailable\(n\)\) return;', oa):
    bad.append('(P12) onAvailable does not start with if (!gate.onAvailable(n)) return;')
if 'gate.onLost(n);' not in body(pw, r'public void onLost\(Network n\) \{', 'onLost'):
    bad.append('(P12) onLost does not call gate.onLost(n)')
if 'gate.onBroken(n, privateDnsBroken(nc));' not in body(pw, r'public void onCapabilitiesChanged\(Network n, NetworkCapabilities nc\) \{', 'onCapabilitiesChanged'):
    bad.append('(P12) onCapabilitiesChanged does not call gate.onBroken(n, privateDnsBroken(nc))')
res = body(pw, r'public void onActivityResumed\(Activity a\) \{', 'onActivityResumed')
if 'gateResumed = true;' not in res or 'feed();' not in res:
    bad.append('(P12) onActivityResumed does not set gateResumed = true and feed()')
pau = body(pw, r'public void onActivityPaused\(Activity a\) \{', 'onActivityPaused')
if 'gateResumed = false;' not in pau or 'feed();' not in pau:
    bad.append('(P12) onActivityPaused does not set gateResumed = false and feed()')
feed = body(pw, r'private static void feed\(\) \{', 'PrivateDnsWatch.feed')
if 'gate.onSurface(PrivateDnsDowngrade.surface(gateResumed, currentUser));' not in feed:
    bad.append('(P12) feed does not call gate.onSurface(PrivateDnsDowngrade.surface(gateResumed, currentUser))')

# P13 NWP-20261127-07: both new components are in the manifest, each exported="false" inside its own tag
mf = re.sub(r'<!--.*?-->', '', mf_raw, flags=re.S)
for kind, name in (('activity', '.PrivateDnsPromptActivity'), ('receiver', '.PrivateDnsChoiceReceiver')):
    tags = re.findall(r'<%s\s[^>]*android:name="%s"[^>]*>' % (kind, re.escape(name)), mf)
    if len(tags) != 1 or 'android:exported="false"' not in tags[0]:
        bad.append('(P13) the manifest does not declare one <%s %s> with android:exported="false"' % (kind, name))
# P14 start feeds the current user after the restore and before the switch receiver; the switch receiver feeds
r = start.find('PrivateDnsDowngrade.restoreIfMarked(io);')
cu = start.find('currentUser = currentUser();')
fd = start.find('feed();')
rx = start.find('registerReceiver(new UserSwitch()')
af = start.find('new IntentFilter(Intent.ACTION_USER_SWITCHED)')
if min(r, cu, fd, rx, af) < 0 or not (r < cu < fd < af < rx):
    bad.append('(P14) start does not restore, then read the current user, then feed(), then register the '
               'ACTION_USER_SWITCHED receiver, in that order')
if 'return android.app.ActivityManager.getCurrentUser();' not in body(pw, r'private static int currentUser\(\) \{', 'currentUser'):
    bad.append('(P14) currentUser() does not read ActivityManager.getCurrentUser()')
us = body(pw, r'class UserSwitch extends BroadcastReceiver \{', 'UserSwitch')
if not re.search(r'int to = i\.getIntExtra\(Intent\.EXTRA_USER_HANDLE, -1\);\s*if \(to < 0\) return;\s*currentUser = to;\s*feed\(\);', us):
    bad.append('(P14) UserSwitch.onReceive does not take EXTRA_USER_HANDLE into currentUser and feed()')
# P15 the receiver acts only in user 0, before it reaches the watch; onChoice goes through the Gate by token
orc = body(pr, r'public void onReceive\(Context ctx, Intent intent\) \{', 'PrivateDnsChoiceReceiver.onReceive')
gd, oc2 = orc.find('if (android.os.UserHandle.myUserId() != 0) return;'), orc.find('PrivateDnsWatch.onChoice(token, cont)')
if not re.match(r'\{\s*if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;', orc) or oc2 < 0 or gd > oc2:
    bad.append('(P15) PrivateDnsChoiceReceiver.onReceive does not return outside user 0 first, before PrivateDnsWatch.onChoice')
if 'new Handler(Looper.getMainLooper()).post(() -> PrivateDnsWatch.onChoice(token, cont));' not in orc:
    bad.append('(P15) PrivateDnsChoiceReceiver does not post PrivateDnsWatch.onChoice to the main thread')
ch = body(pw, r'static void onChoice\(long token, boolean cont\) \{', 'onChoice')
if not re.match(r'\{\s*if \(gate == null\) return;', ch) or 'if (cont) gate.onContinue(token); else gate.onStay(token);' not in ch \
        or 'ui.chosen(token);' not in ch:
    bad.append('(P15) onChoice does not refuse an unstarted watch, go through gate.onContinue/onStay(token) and ui.chosen(token)')
# P16 the notification: through the session user's context, an IMMUTABLE PendingIntent from that context
ps = body(pw, r'private boolean postSession\(long token, int uid\) \{', 'postSession')
for need in ('Context uc = app.createContextAsUser(android.os.UserHandle.of(uid), 0);',
             'NotificationManager nm = uc.getSystemService(NotificationManager.class);',
             'nm.createNotificationChannel(',
             'PendingIntent.getActivity(uc, 0,',
             'new Intent(uc, PrivateDnsPromptActivity.class)',
             '.putExtra(PrivateDnsPromptActivity.EXTRA_TOKEN, token)',
             'PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE)',
             '.setContentIntent(pi)',
             'nm.notify(NOTIF_ID, n);'):
    if need not in ps:
        bad.append('(P16) postSession does not hold %r' % need)
for name, src in (('PrivateDnsWatch', pw), ('PrivateDnsPromptActivity', pa), ('PrivateDnsChoiceReceiver', pr)):
    if 'FLAG_MUTABLE' in src:
        bad.append('(P16) %s holds FLAG_MUTABLE' % name)
sh = body(pw, r'public boolean show\(long token, int surface\) \{', 'PromptUi.show')
if 'if (surface == PrivateDnsDowngrade.SURFACE_GATE) return showGate(token);' not in sh \
        or 'if (surface > 0) return postSession(token, surface);' not in sh:
    bad.append('(P16) PromptUi.show does not send SURFACE_GATE to the gate dialog and a uid > 0 to postSession')
# P17 the decided words through PrivateDnsDowngrade, never a literal copy
for need in ('.setContentTitle(PrivateDnsDowngrade.TITLE)', '.setContentText(PrivateDnsDowngrade.BODY)',
             'bigText(PrivateDnsDowngrade.BODY)'):
    if need not in ps:
        bad.append('(P17) postSession does not hold %r' % need)
for need in ('.setTitle(PrivateDnsDowngrade.TITLE)', '.setMessage(PrivateDnsDowngrade.BODY)', '.setCancelable(false)',
             '.setPositiveButton(PrivateDnsDowngrade.CONTINUE, (d, w) -> send(PrivateDnsDowngrade.CHOICE_CONTINUE))',
             '.setNegativeButton(PrivateDnsDowngrade.STAY, (d, w) -> send(PrivateDnsDowngrade.CHOICE_STAY))'):
    if need not in pa:
        bad.append('(P17) PrivateDnsPromptActivity does not hold %r' % need)
lits = lambda src: re.findall(r'"((?:[^"\\]|\\.)*)"', src)
for name, src in (('PrivateDnsWatch', pw), ('PrivateDnsPromptActivity', pa), ('PrivateDnsChoiceReceiver', pr)):
    for l in lits(src):
        if any(w in l for w in words):
            bad.append('(P17) %s holds a literal copy of a decided word: %r' % (name, l))
# P18 no new file path; the session dialog sends only from its buttons
if pw.count('getFilesDir()') != 1:
    bad.append('(P18) PrivateDnsWatch names getFilesDir() %d times, want 1 (the P8 marker)' % pw.count('getFilesDir()'))
for name, src in (('PrivateDnsWatch', pw), ('PrivateDnsPromptActivity', pa), ('PrivateDnsChoiceReceiver', pr)):
    for w in ('getCacheDir', 'openFileOutput', 'getSharedPreferences', 'getDataDir', 'getExternalFilesDir'):
        if w in src:
            bad.append('(P18) %s names %s' % (name, w))
for name, src in (('PrivateDnsPromptActivity', pa), ('PrivateDnsChoiceReceiver', pr)):
    if re.search(r'getFilesDir|new (?:java\.io\.)?File\(|Settings\.', src):
        bad.append('(P18) %s names a file or a setting' % name)
snd = body(pa, r'private void send\(String choice\) \{', 'PrivateDnsPromptActivity.send')
if not re.search(r'sendBroadcastAsUser\(new Intent\(this, PrivateDnsChoiceReceiver\.class\)\s*\.putExtra\(EXTRA_TOKEN, token\)'
                 r'\s*\.putExtra\(PrivateDnsChoiceReceiver\.EXTRA_CHOICE, choice\), android\.os\.UserHandle\.SYSTEM\);', snd):
    bad.append('(P18) PrivateDnsPromptActivity.send does not send the token and the choice to PrivateDnsChoiceReceiver in UserHandle.SYSTEM')
if '.setOnDismissListener(d -> finish())' not in pa or pa.count('send(') != 3:
    bad.append('(P18) PrivateDnsPromptActivity does not finish on a dismissal, or sends outside its two buttons')
# P19 a closed prompt cancels the notification where it went; a choice cancels only its own token's
cs = body(pw, r'private void cancelSession\(\) \{', 'cancelSession')
if 'app.createContextAsUser(android.os.UserHandle.of(uid), 0)' not in cs or 'nm.cancel(NOTIF_ID)' not in cs \
        or 'int uid = postedUid;' not in cs:
    bad.append('(P19) cancelSession does not cancel NOTIF_ID through the context of the user it was posted to')
if not re.match(r'\{\s*cancelSession\(\);', body(pw, r'public void dismiss\(\) \{', 'PromptUi.dismiss')):
    bad.append('(P19) PromptUi.dismiss does not cancel the notification first')
if 'if (token == 0 || token != postedToken) return;' not in body(pw, r'void chosen\(long token\) \{', 'chosen'):
    bad.append('(P19) chosen does not cancel only the notification that carries this token')
# P20 RF-001: the token is a long end to end, and each Gate seeds its counter at random (no durable state)
if 'final long token = intent.getLongExtra(PrivateDnsPromptActivity.EXTRA_TOKEN, 0);' not in orc:
    bad.append('(P20) PrivateDnsChoiceReceiver does not read the token as a long')
if 'return i != null ? i.getLongExtra(EXTRA_TOKEN, 0L) : 0L;' not in pa or 'private long token;' not in pa:
    bad.append('(P20) PrivateDnsPromptActivity does not carry the token as a long')
for name, src in (('PrivateDnsWatch', pw), ('PrivateDnsPromptActivity', pa), ('PrivateDnsChoiceReceiver', pr)):
    if 'getIntExtra(PrivateDnsPromptActivity.EXTRA_TOKEN' in src or 'getIntExtra(EXTRA_TOKEN' in src:
        bad.append('(P20) %s reads the token as an int' % name)
for b in bad: print('PIN FAILED: ' + b)
if not bad: print('ok P1-P20 PrivateDnsWatch, the session dialog, its receiver, the manifest, ChooserActivity and NowhereApp wiring')
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <dg> <pw> <ca> <na> <mf> <pa> <pr> [quiet]: 0 pass, 1 failed, 2 could not run
  local dg=$1 pw=$2 ca=$3 na=$4 mf=$5 pa=$6 pr=$7 quiet=${8:-} rc=0 prc=0 pout
  cases "$dg" "$quiet" || rc=$?
  [ "$rc" -eq 2 ] && return 2
  pout=$(pins "$dg" "$pw" "$ca" "$na" "$mf" "$pa" "$pr" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$DG" "$PW" "$CA" "$NAPP" "$MF" "$PA" "$PR"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-private-dns-downgrade-java: FAIL (rc $rc)"; exit 1; fi
echo "test-private-dns-downgrade-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: dg|pw|ca|na|mf|pa|pr> <exact anchor> <replacement>: the anchor must occur exactly once
  local name=$1 which=$2 old=$3 new=$4 d mdg mpw mca mna mmf mpa mpr src rc=0
  d=$(mktemp -d -p "$W") || { fails=$((fails + 1)); return; }
  mdg="$d/PrivateDnsDowngrade.java"; mpw="$d/PrivateDnsWatch.java"; mca="$d/ChooserActivity.java"
  mna="$d/NowhereApp.java"; mmf="$d/AndroidManifest.xml"; mpa="$d/PrivateDnsPromptActivity.java"
  mpr="$d/PrivateDnsChoiceReceiver.java"
  cp "$DG" "$mdg"; cp "$PW" "$mpw"; cp "$CA" "$mca"; cp "$NAPP" "$mna"; cp "$MF" "$mmf"; cp "$PA" "$mpa"; cp "$PR" "$mpr"
  case "$which" in
    dg) src=$mdg ;;
    pw) src=$mpw ;;
    ca) src=$mca ;;
    na) src=$mna ;;
    mf) src=$mmf ;;
    pa) src=$mpa ;;
    pr) src=$mpr ;;
    *) echo "  $name: ⚠ unknown file '$which'"; fails=$((fails + 1)); rm -rf "$d"; return ;;
  esac
  if ! python3 - "$src" "$old" "$new" <<'PY'
import io, sys
p, old, new = sys.argv[1:4]
s = io.open(p, encoding='utf-8').read()
if s.count(old) != 1: sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
  then
    echo "  $name: ⚠ NOT APPLIED (the anchor is not there exactly once)"; fails=$((fails + 1)); rm -rf "$d"; return
  fi
  suite "$mdg" "$mpw" "$mca" "$mna" "$mmf" "$mpa" "$mpr" quiet; rc=$?
  if [ "$rc" -eq 1 ]; then echo "  $name: CONVICTED"
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

echo "mutants:"
mutant "M1 the downgrade writes opportunistic, not off" dg \
  'static final String MODE_OFF = "off";' 'static final String MODE_OFF = "opportunistic";'
mutant "M2 the marker written after the mode" dg \
  $'        if (!io.mark()) return false;\n        return io.setMode(MODE_OFF);' \
  $'        boolean set = io.setMode(MODE_OFF);\n        if (!io.mark()) return false;\n        return set;'
mutant "M3 restore without the marker check" dg \
  $'        if (!io.marked()) return false;\n' ''
mutant "M4 restore removes the marker before writing hostname" dg \
  $'        if (!io.setMode(MODE_STRICT)) return false;\n        io.unmark();' \
  $'        io.unmark();\n        if (!io.setMode(MODE_STRICT)) return false;'
mutant "M5 prompt ignores declinedOn" dg \
  'network != null && !network.equals(declinedOn);' 'network != null;'
mutant "M6 the reflection fallback reads true" pw \
  $'                Log.w(TAG, "private dns broken signal unreadable: " + t.getClass().getName());\n            }\n            return false;' \
  $'                Log.w(TAG, "private dns broken signal unreadable: " + t.getClass().getName());\n            }\n            return true;'
mutant "M7 no user-0 guard" pw \
  $'        if (android.os.UserHandle.myUserId() != 0) return;\n' ''
mutant "M8 onLost does not restore" pw \
  $'        PrivateDnsDowngrade.restoreIfMarked(io); // rule (ii): the network went away\n' ''
mutant "M9 prompt compares the network with ==" dg \
  '!network.equals(declinedOn)' 'network != declinedOn'
mutant "M10 NowhereApp does not start the watcher" na \
  $'            PrivateDnsWatch.start(this);\n' ''
mutant "M11 onAvailable does not restore" pw \
  $'            PrivateDnsDowngrade.restoreIfMarked(io); // rule (ii): a new default network\n' ''
mutant "M12 start does not restore" pw \
  $'        PrivateDnsDowngrade.restoreIfMarked(io); // rule (ii): at every start\n' ''
mutant "M14 RF-001: a new default network keeps the old dialog" dg \
  $'            broken = false;\n            close(); // the old network\'s dialog is no consent for this one\n' \
  $'            broken = false;\n'
mutant "M15 RF-001: a closed dialog's Continue still counts" dg \
  $'            if (token == 0 || token != asked) return false; // a closed dialog\'s button\n' ''
mutant "M16 RF-001: the dialog stays up when the prompt no longer holds" dg \
  $'            if (!prompt(blocked(io.mode(), broken), surface, current, declinedOn)) {\n                close();\n                return;\n            }' \
  $'            if (!prompt(blocked(io.mode(), broken), surface, current, declinedOn)) {\n                return;\n            }'
mutant "M17 RF-001: the watcher ignores the gate on a new default network" pw \
  $'            if (!gate.onAvailable(n)) return; // the same default network: nothing changed\n' ''
mutant "M18 RF-001: onLost does not tell the gate" dg \
  $'            current = null;\n            broken = false;\n            close();' \
  $'            current = null;\n            broken = false;'
mutant "M13 the gate's onCreate does not start the watcher" ca \
  $'        PrivateDnsWatch.start(this); // NWP-20261122-07: user-0 only: the blocked-encrypted-DNS prompt (h49 #2, h50 #4)\n' ''
# NWP-20261127-07: the session half
mutant "M19 a change of surface does not close the open prompt" dg \
  $'                surface = s;\n                close(); // the old surface\'s prompt is closed; a new token goes to the new one\n' \
  $'                surface = s;\n'
mutant "M20 a session surface treated as NONE" dg \
  'blocked && surface != SURFACE_NONE && network' 'blocked && surface == SURFACE_GATE && network'
mutant "M21 start does not feed the current user (a process born mid-session)" pw \
  $'        currentUser = currentUser(); // a process born mid-session gets no switch broadcast\n        feed();\n' ''
mutant "M22 the choice receiver's user-0 guard dropped" pr \
  $'        if (android.os.UserHandle.myUserId() != 0) return;\n' ''
mutant "M23 the notification's PendingIntent made mutable" pw \
  'PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE' 'PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE'
mutant "M24 Stay private's stale-token refusal dropped" dg \
  $'        void onStay(long token) {\n            if (token == 0 || token != asked) return;\n' $'        void onStay(long token) {\n'
mutant "M25 a session wins over the resumed gate" dg \
  $'        if (gateResumed) return SURFACE_GATE;\n        return currentUser > 0 ? currentUser : SURFACE_NONE;' \
  $'        if (currentUser > 0) return currentUser;\n        return gateResumed ? SURFACE_GATE : SURFACE_NONE;'
mutant "M26 a user switch does not feed the Gate" pw \
  $'            currentUser = to;\n            feed();\n' $'            currentUser = to;\n'
mutant "M27 the session dialog exported" mf \
  '<activity android:name=".PrivateDnsPromptActivity" android:exported="false"' \
  '<activity android:name=".PrivateDnsPromptActivity" android:exported="true"'
mutant "M28 the choice receiver exported" mf \
  '<receiver android:name=".PrivateDnsChoiceReceiver" android:exported="false"/>' \
  '<receiver android:name=".PrivateDnsChoiceReceiver" android:exported="true"/>'
mutant "M29 the PendingIntent built from user 0's context" pw \
  'PendingIntent.getActivity(uc, 0,' 'PendingIntent.getActivity(app, 0,'
mutant "M30 a literal copy of the title on the notification" pw \
  '.setContentTitle(PrivateDnsDowngrade.TITLE)' '.setContentTitle("This network blocks encrypted DNS")'
mutant "M31 the session dialog sends Stay on a dismissal" pa \
  '.setOnDismissListener(d -> finish())' '.setOnDismissListener(d -> send(PrivateDnsDowngrade.CHOICE_STAY))'
mutant "M32 a choice does not cancel the notification" pw \
  $'        ui.chosen(token);\n' ''
mutant "M33 a dismissal does not cancel the notification" pw \
  $'        public void dismiss() {\n            cancelSession();\n' $'        public void dismiss() {\n'
mutant "M35 RF-001: every Gate starts its tokens at the same value" dg \
  '            this.lastToken = new java.security.SecureRandom().nextLong();' '            this.lastToken = 0;'
mutant "M36 RF-001: the receiver reads the token as an int" pr \
  'final long token = intent.getLongExtra(PrivateDnsPromptActivity.EXTRA_TOKEN, 0);' \
  'final long token = intent.getIntExtra(PrivateDnsPromptActivity.EXTRA_TOKEN, 0);'
mutant "M34 the session dialog keeps the token in a file" pa \
  '        token = tokenOf(getIntent());' \
  '        token = tokenOf(getIntent()); getSharedPreferences("privatedns", 0).edit().putLong("t", token).apply();'
if [ "$fails" -ne 0 ]; then echo "test-private-dns-downgrade-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-private-dns-downgrade-java: all mutants convicted"
