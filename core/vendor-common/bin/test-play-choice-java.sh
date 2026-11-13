#!/usr/bin/env bash
# test-play-choice-java.sh [--mutate] -- the Google Play row in Profile › Apps, under javac (NWP-20261122-06).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-01, "twenty-two answers to harvests 50, 51 and 52 ...",
# h50 #7 (A1 with the not-installed row, B1 (i), B2) gives Play one on/off control in Profile › Apps. Its rules live in
# PlayChoice (pure java), compiled as-is with PlayChoiceCases: the flag play.wanted has three states and absent is
# never off (every older profile has no flag), the row's text with the decided not-installed draft verbatim, the
# keep-mode a Play stack member gets at install, and Off dropping Play Store alone (B1 (i)). The PINS check the wiring
# the cases cannot see, on the sources with comments stripped:
#   P1  showYourApps calls playRow(ll) once, before the intro note; playRow's first statement returns unless
#       PlayChoice.offered(isInstalledPkg(GOS_STORE_PKG), sessionType, offlineSession) -- no row on Diaspore, in a
#       throwaway or offline.
#       playState reads play.wanted through PlayChoice.effective(..., gosStorePresent(this)), so a flag roamed to a phone
#       without the GrapheneOS App Store (Diaspore) reads as absent; gosStorePresent asks for GOS_STORE_PKG.
#   P1b paintPlayRow reads kept from the keep-set and installed from isOnDevicePkg (installed or archived) once, and
#       hands the same pair to PlayChoice.rowText and PlayChoice.tap; the tap's three answers go to turnPlayOn /
#       openGosStore / confirmPlayOff. turnPlayOn marks every PlayChoice.onMarks(this::isOnDevicePkg) member On-demand.
#   P1c (RF-004) playRow keeps no snapshot: it paints the row when it draws it, reads it again at each tap and each
#       time the window gets the focus back (Back or Recents from the App Store), so Play Store installed there turns
#       "not installed yet" into "On" and the next tap offers Off.
#   P2  turnPlayOff signs each Google account out through signOutGoogle (after GoogleSignOut.claim) and never calls
#       removeAccount itself; signOutGoogle writes the mark, returns when it was not recorded, and only then removes.
#   P3  turnPlayOff writes "0" and checks it landed before it drops anything or signs anything out; it drops exactly
#       PlayChoice.offDrops(); confirmPlayOff's "Turn off" runs it.
#   P4  reconcilePlayStack derives playOff from PlayChoice.blocksVendingReadd(playState()) and guards exactly the two
#       Play Store re-adds with it (the user-kept m.put and the auto-pulled applyStackMember); gms/gsf are not guarded.
#   P5  AppInstallReceiver.decide reads the flag through PlayChoice.effective(..., ProfileActivity.gosStorePresent(ctx))
#       and passes its default through PlayChoice.keepModeOnInstall after appDefaultForInstaller and before its first branch, and records a Play Store keep with setPlayDep only when it wrote the keep line. Its second setPlayDep is the back-On one (P7).
#   P6  PlayChoice's package and mode literals equal ProfileActivity's VENDING_PKG / GMS_PKG / GSF_PKG / MODE_ONDEMAND.
#   P7  NWP-20261129-16 (docs/product-decisions.md, 2026-11-05, "seventeen answers to harvest 59 ...", #7): decide asks
#       PlayChoice.turnsOnAtInstall with `replacing` and "broadcast".equals(via), writes State.ON and reads it back before
#       keepModeOnInstall; the Off line, the guarded setPlayDep and the backOnMarks keeps run only under backOn, after the
#       branches; the on-this-phone test reads archived packages for this user and never MATCH_ANY_USER.
#
# What it does NOT prove: the handset run (the row on an Endospore device, the App Store opening, Off dropping Play
# Store at the next save and the Google account leaving with its mark). That is the backlog row's CLOSES WHEN.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-play-choice-java.sh            # the cases and the pins
#   bash test-play-choice-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ProfileActivity.java"
CLS="$SRCDIR/PlayChoice.java"
AIR="$SRCDIR/AppInstallReceiver.java"
CASES="$root/core/chooser/tests/play-choice/PlayChoiceCases.java"
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

# pins <ProfileActivity.java> <PlayChoice.java> <AppInstallReceiver.java> -> 0 ok, 1 a pin failed, 2 a control failed
pins() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, re, sys
act_path, cls_path, air_path = sys.argv[1:4]

def strip_comments(src):
    """Drop line and block comments; keep string and char literals. Whitespace is kept."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if src.startswith('"""', i):
            j = src.find('"""', i + 3); j = n if j < 0 else j + 3
            out.append(src[i:j]); i = j; continue
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

def method(code, sig):
    """The member from sig to its closing brace (literals skipped), or None when sig is not there exactly once."""
    if code.count(sig) != 1: return None
    i = code.index(sig); k = code.index('{', i); d = 0; n = len(code)
    while k < n:
        c = code[k]
        if c in '"\'':
            j = k + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == '\\' else 1
            k = j + 1; continue
        if c == '{': d += 1
        elif c == '}':
            d -= 1
            if d == 0: return code[i:k + 1]
        k += 1
    return None

flat = lambda s: re.sub(r'\s+', '', s)
fails = []
def pin(name, ok, why):
    if ok: print('  ok    ' + name)
    else: print('  PIN   ' + name + ': ' + why); fails.append(name)

act = strip_comments(io.open(act_path, encoding='utf-8').read())
cls = strip_comments(io.open(cls_path, encoding='utf-8').read())
air = strip_comments(io.open(air_path, encoding='utf-8').read())

controls = {
    'showYourApps': method(act, 'private void showYourApps() {'),
    'reconcilePlayStack': method(act, 'private void reconcilePlayStack(java.util.Map<String,String> m, java.util.Set<String> preKept) {'),
    'signOutGoogle': method(act, 'private void signOutGoogle(final android.accounts.Account acct, final String hash) {'),
    'decide': method(air, 'private static boolean decide(Context ctx, String pkg, boolean replacing, String via) {'),
}
for k, v in controls.items():
    if v is None:
        print('  CONTROL %s not found exactly once (or its braces do not balance)' % k); sys.exit(2)
sya, rps, sog, dec = (flat(controls[k]) for k in ('showYourApps', 'reconcilePlayStack', 'signOutGoogle', 'decide'))

def new_method(sig):
    m = method(act, sig)
    return flat(m) if m is not None else ''
prow = new_method('private void playRow(LinearLayout ll) {')
poff = new_method('private void turnPlayOff() {')
pon = new_method('private void turnPlayOn() {')
pconf = new_method('private void confirmPlayOff() {')
pstate = new_method('private PlayChoice.State playState() {')
pstore = new_method('private void openGosStore() {')
pgos = new_method('static boolean gosStorePresent(android.content.Context ctx) {')
pdev = new_method('private boolean isOnDevicePkg(String pkg) {')
ppaint = new_method('private PlayChoice.Tap paintPlayRow(TextView sub) {')

def pos(hay, needle):
    return hay.find(needle)

# P1
p_call = sya.count('playRow(ll);')
p_note = pos(sya, 'TextViewnote=newTextView(this);')
pin('P1 showYourApps calls playRow(ll) once, before the intro note',
    p_call == 1 and p_note >= 0 and pos(sya, 'playRow(ll);') < p_note,
    'calls=%d, playRow at %d, note at %d' % (p_call, pos(sya, 'playRow(ll);'), p_note))
GUARD = 'if(!PlayChoice.offered(isInstalledPkg(GOS_STORE_PKG),sessionType,offlineSession))return;'
pin('P1 playRow starts by returning unless PlayChoice.offered(isInstalledPkg(GOS_STORE_PKG), sessionType, offlineSession)',
    prow.startswith('privatevoidplayRow(LinearLayoutll){' + GUARD), 'playRow head: ' + prow[:160])
pin('P1 playState reads play.wanted from nowhere-config through PlayChoice.parse and PlayChoice.effective(gosStorePresent)',
    pstate == 'privatePlayChoice.StateplayState(){returnPlayChoice.effective(PlayChoice.parse(readConfig().get(PlayChoice.CFG_KEY)),gosStorePresent(this));}',
    pstate[:200])
pin('P1 gosStorePresent asks PackageManager for GOS_STORE_PKG',
    'getApplicationInfo(GOS_STORE_PKG,0);returntrue;' in pgos and pgos.count('returntrue;') == 1, pgos[:200])
pin('P1b isOnDevicePkg counts an installed or an archived package (MATCH_ARCHIVED_PACKAGES through ApplicationInfoFlags.of)',
    pdev.startswith('privatebooleanisOnDevicePkg(Stringpkg){if(isInstalledPkg(pkg))returntrue;try{getPackageManager().getApplicationInfo(pkg,'
                    'android.content.pm.PackageManager.ApplicationInfoFlags.of(android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES));returntrue;}'),
    pdev[:240])

# P1b
for need, why in [
    ('finalPlayChoice.Statest=playState();', 'st from playState()'),
    ('finalbooleankept=readAppModes().containsKey(VENDING_PKG);', 'kept from the keep-set'),
    ('finalbooleaninstalled=isOnDevicePkg(VENDING_PKG);', 'installed from isOnDevicePkg (installed or archived)'),
    ('sub.setText(PlayChoice.rowText(st,kept,installed));', 'the subtitle is rowText(st, kept, installed)'),
    ('returnPlayChoice.tap(st,kept,installed);}', 'the tap returned is tap(st, kept, installed)'),
]:
    pin('P1b paintPlayRow: ' + why, ppaint.count(need) == 1, 'want exactly one ' + need)
pin('P1b paintPlayRow asks about Play Store on the phone once (one reading for text and tap)',
    ppaint.count('isOnDevicePkg(VENDING_PKG)') == 1 and 'isInstalledPkg(VENDING_PKG)' not in ppaint,
    'isOnDevicePkg x%d' % ppaint.count('isOnDevicePkg(VENDING_PKG)'))
for need, why in [
    ('caseTURN_ON:turnPlayOn();break;', 'TURN_ON -> turnPlayOn'),
    ('caseOPEN_STORE:openGosStore();break;', 'OPEN_STORE -> openGosStore'),
    ('caseCONFIRM_OFF:confirmPlayOff();break;', 'CONFIRM_OFF -> confirmPlayOff'),
    ('.setText(PlayChoice.TITLE);', 'the title is PlayChoice.TITLE'),
]:
    pin('P1b playRow: ' + why, prow.count(need) == 1, 'want exactly one ' + need)

# P1c (RF-004): no snapshot; the row reads again at draw, at each tap and on each window focus.
c_paint = pos(prow, 'col.addView(sub);paintPlayRow(sub);')
c_click = pos(prow, 'row.setOnClickListener(v->{switch(paintPlayRow(sub)){')
pin('P1c playRow paints the subtitle when it draws it, then the tap reads the row again',
    0 <= c_paint < c_click, 'paint=%d click=%d' % (c_paint, c_click))
pin('P1c playRow holds no reading of its own (no rowText, tap, playState or isOnDevicePkg outside paintPlayRow)',
    all(x not in prow for x in ('PlayChoice.rowText(', 'PlayChoice.tap(', 'playState()', 'isOnDevicePkg(', 'readAppModes()')),
    'a snapshot in playRow')
pin('P1c the window regaining the focus paints the row again',
    prow.count('OnWindowFocusChangeListeneronFocus=has->{if(has)paintPlayRow(sub);};') == 1, 'focus listener missing')
pin('P1c the focus listener is added while the row is attached and removed when it is detached',
    'publicvoidonViewAttachedToWindow(Viewv){v.getViewTreeObserver().addOnWindowFocusChangeListener(onFocus);}' in prow
    and 'publicvoidonViewDetachedFromWindow(Viewv){v.getViewTreeObserver().removeOnWindowFocusChangeListener(onFocus);}' in prow
    and 'row.addOnAttachStateChangeListener(' in prow, 'attach/detach wiring missing')
pin('P1b openGosStore opens the App Store at the Play entry through GosStoreLink.route, by its launch intent otherwise',
    'newandroid.content.Intent(GosStoreLink.ACTION).setPackage(GosStoreLink.STORE_PKG).putExtra(GosStoreLink.EXTRA,GosStoreLink.ENTRY_PKG);' in pstore
    and 'switch(GosStoreLink.route(' in pstore
    and 'getPackageManager().getLaunchIntentForPackage(GOS_STORE_PKG)' in pstore
    and 'startActivity(start);' in pstore, pstore[:200])
pin('P1b turnPlayOn writes "1", checks it landed, then opens the App Store',
    pon.startswith('privatevoidturnPlayOn(){cfgPut(PlayChoice.CFG_KEY,PlayChoice.raw(PlayChoice.State.ON));'
                   'if(playState()!=PlayChoice.State.ON){') and 'openGosStore();' in pon, pon[:200])
on_mk = pos(pon, 'for(Stringp:PlayChoice.onMarks(this::isOnDevicePkg))applyKeepModeOffThread(p,MODE_ONDEMAND,null,null);')
pin('P1b turnPlayOn marks each PlayChoice.onMarks member On-demand, after the flag landed and before the App Store opens',
    pos(pon, 'if(playState()!=PlayChoice.State.ON){') < on_mk < pos(pon, 'openGosStore();')
    and pon.count('applyKeepModeOffThread(') == 1, 'onMarks loop at %d' % on_mk)

# P2
new_bodies = prow + ppaint + poff + pon + pconf + pstate + pstore
pin('P2 no new helper calls removeAccount itself', 'removeAccount(' not in new_bodies, 'removeAccount( in a new helper')
pin('P2 turnPlayOff claims each account, then runs signOutGoogle(a, hash)',
    poff.count('if(GoogleSignOut.claim(hash)){newThread(()->signOutGoogle(a,hash),') == 1
    and 'getAccountsByType(GoogleSignOut.ACCOUNT_TYPE)' in poff
    and 'finalStringhash=GoogleSignOut.markHash(a.name);' in poff, poff[:400])
m_mark = pos(sog, 'booleanrecorded=GoogleSignOut.mark(')
m_ret = pos(sog, 'if(!recorded){GoogleSignOut.release(hash);googleSignOutFailed(')
m_retend = sog.find('return;}', m_ret) if m_ret >= 0 else -1
m_rm = pos(sog, 'removeAccount(')
pin('P2 signOutGoogle writes the mark, returns when it was not recorded, and only then calls removeAccount',
    0 <= m_mark < m_ret < m_retend < m_rm and sog.count('removeAccount(') == 1,
    'mark=%d notRecorded=%d return=%d removeAccount=%d' % (m_mark, m_ret, m_retend, m_rm))

# P3
o_put = pos(poff, 'cfgPut(PlayChoice.CFG_KEY,PlayChoice.raw(PlayChoice.State.OFF));')
o_chk = pos(poff, 'if(playState()!=PlayChoice.State.OFF){')
o_chkret = poff.find('return;}', o_chk) if o_chk >= 0 else -1
o_drop = pos(poff, 'for(Stringp:PlayChoice.offDrops())applyKeepModeOffThread(p,null,null,null);')
o_so = pos(poff, 'signOutGoogle(')
pin('P3 turnPlayOff writes "0", returns unless it landed, then drops, then signs out',
    0 <= o_put < o_chk < o_chkret < o_drop < o_so, 'put=%d check=%d return=%d drop=%d signout=%d' % (o_put, o_chk, o_chkret, o_drop, o_so))
pin('P3 turnPlayOff drops exactly PlayChoice.offDrops() (one applyKeepModeOffThread, one setAppMode path)',
    poff.count('applyKeepModeOffThread(') == 1 and 'setAppMode(' not in poff and 'GMS_PKG' not in poff and 'GSF_PKG' not in poff,
    'applyKeepModeOffThread x%d' % poff.count('applyKeepModeOffThread('))
pin('P3 confirmPlayOff warns with the drafted words and "Turn off" runs turnPlayOff',
    '.setTitle(PlayChoice.OFF_TITLE).setMessage(PlayChoice.OFF_MESSAGE).setNegativeButton(PlayChoice.OFF_CANCEL,null)'
    '.setPositiveButton(PlayChoice.OFF_CONFIRM,(d,w)->turnPlayOff())' in pconf, pconf[:300])

# P4
pin('P4 reconcilePlayStack derives playOff from PlayChoice.blocksVendingReadd(playState()) once',
    rps.count('finalbooleanplayOff=PlayChoice.blocksVendingReadd(playState());') == 1, 'decl x%d' % rps.count('finalbooleanplayOff='))
pin('P4 the user-kept Play Store re-add is guarded by !playOff',
    rps.count('if(!playOff&&!m.containsKey(VENDING_PKG)&&(preKept.contains(VENDING_PKG)||isInstalledPkg(VENDING_PKG)))m.put(VENDING_PKG,MODE_ONDEMAND);') == 1,
    'guarded user-kept re-add not found')
pin('P4 the auto-pulled Play Store re-add is guarded by !playOff',
    rps.count('}elseif(!playOff){applyStackMember(m,VENDING_PKG,need,preKept);}') == 1, 'guarded auto branch not found')
pin('P4 playOff guards nothing else (named three times: its declaration and the two re-adds)',
    len(re.findall(r'\bplayOff\b', controls['reconcilePlayStack'])) == 3,
    'playOff x%d' % len(re.findall(r'\bplayOff\b', controls['reconcilePlayStack'])))
pin('P4 gms/gsf are reconciled unguarded',
    'applyStackMember(m,GMS_PKG,need,preKept);applyStackMember(m,GSF_PKG,need,preKept);if(need==null){m.remove(VENDING_PKG);}' in rps,
    'the gms/gsf lines moved or gained a guard')
pin('P4 VENDING_PKG is put back in exactly the two guarded places',
    rps.count('m.put(VENDING_PKG') == 1 and rps.count('applyStackMember(m,VENDING_PKG') == 1, 'extra re-add site')

# P5
d_def = pos(dec, 'Stringmode=ProfileActivity.appDefaultForInstaller(ctx,installer);')
d_st = pos(dec, 'PlayChoice.Stateplay=PlayChoice.effective(PlayChoice.parse(ProfileActivity.cfgStatic(ctx,PlayChoice.CFG_KEY)),'
               'ProfileActivity.gosStorePresent(ctx));')
d_km = pos(dec, 'mode=PlayChoice.keepModeOnInstall(play,pkg,mode);')
d_first = pos(dec, 'if(replacing){')
pin('P5 decide reads the flag through effective(gosStorePresent) and passes its default through keepModeOnInstall before its first branch',
    0 <= d_def < d_st < d_km < d_first and dec.count('keepModeOnInstall(') == 1,
    'default=%d state=%d keepMode=%d firstBranch=%d' % (d_def, d_st, d_km, d_first))
d_dep = pos(dec, 'if(wrote&&PlayChoice.userKeepsOnInstall(play,pkg)){try{ProfileActivity.setPlayDep(ctx,pkg,true);}')
pin('P5 decide records a Play Store keep with setPlayDep only after it wrote the keep line',
    d_dep > d_first and dec.count('setPlayDep(') == 2, 'setPlayDep at %d, x%d' % (d_dep, dec.count('setPlayDep(')))

# P6
def lit(src, name):
    m = re.findall(r'static final String ' + name + r'\s*=\s*"([^"]*)"\s*;', src)
    return m[0] if len(m) == 1 else None
for pa, pc in (('VENDING_PKG', 'VENDING'), ('GMS_PKG', 'GMS'), ('GSF_PKG', 'GSF'), ('MODE_ONDEMAND', 'ONDEMAND')):
    a, c = lit(act, pa), lit(cls, pc)
    pin('P6 PlayChoice.%s equals ProfileActivity.%s' % (pc, pa), a is not None and a == c, '%r vs %r' % (a, c))

# P7
b_at = pos(dec, 'if(PlayChoice.turnsOnAtInstall(play,pkg,replacing,"broadcast".equals(via))){')
b_put = pos(dec, 'ProfileActivity.cfgPutStatic(ctx,PlayChoice.CFG_KEY,PlayChoice.raw(PlayChoice.State.ON));')
# dec.find from b_put: the first read of the flag holds the same text
b_read = dec.find('play=PlayChoice.effective(PlayChoice.parse(ProfileActivity.cfgStatic(ctx,PlayChoice.CFG_KEY)),'
                  'ProfileActivity.gosStorePresent(ctx));', b_put) if b_put >= 0 else -1
b_on = dec.find('backOn=play==PlayChoice.State.ON;', b_read) if b_read >= 0 else -1
pin('P7 decide asks turnsOnAtInstall(play, pkg, replacing, "broadcast".equals(via)) once, after the first read of the flag',
    0 <= d_st < b_at and dec.count('turnsOnAtInstall(') == 1, 'state=%d ask=%d x%d' % (d_st, b_at, dec.count('turnsOnAtInstall(')))
pin('P7 the write of State.ON and its read-back come before keepModeOnInstall, and backOn is what the read-back says',
    0 <= b_at < b_put < b_read < b_on < d_km < d_first and dec.count('cfgPutStatic(') == 1,
    'ask=%d put=%d read=%d backOn=%d keepMode=%d firstBranch=%d' % (b_at, b_put, b_read, b_on, d_km, d_first))
b_blk = method(dec, 'if(backOn){')
b_blk_at = pos(dec, 'if(backOn){')
pin('P7 one if (backOn) block, after the branches and the wrote playdep',
    b_blk is not None and 0 <= pos(dec, 'outcome=wrote?"kept":"refusedbykeepInMode";') < b_blk_at and d_dep < b_blk_at,
    'block at %d, wrote playdep at %d' % (b_blk_at, d_dep))
for need, why in [
    ('StoreInstaller.clearTurnedOff(ctx,java.util.Collections.singleton(PlayChoice.VENDING));', 'clearTurnedOff retires Play Store alone'),
    ('if(!wrote&&StoreInstaller.keepSetHas(ctx,PlayChoice.VENDING)){ProfileActivity.setPlayDep(ctx,PlayChoice.VENDING,true);}',
     'setPlayDep only for a keep line this call did not write'),
    ('PlayChoice.backOnMarks(onDevice,', 'the marks come from backOnMarks'),
    ('StoreInstaller.keepInMode(ctx,member,false,PlayChoice.ONDEMAND);', 'each mark is kept On-demand'),
]:
    pin('P7 under backOn: ' + why, b_blk is not None and b_blk.count(need) == 1, 'want exactly one ' + need)
pin('P7 clearTurnedOff and backOnMarks are called only there',
    dec.count('clearTurnedOff(') == 1 and dec.count('backOnMarks(') == 1,
    'clearTurnedOff x%d backOnMarks x%d' % (dec.count('clearTurnedOff('), dec.count('backOnMarks(')))
d_a0 = pos(dec, 'pm.getApplicationInfo(p,0);')
d_a1 = pos(dec, 'pm.getApplicationInfo(p,android.content.pm.PackageManager.ApplicationInfoFlags.of('
                'android.content.pm.PackageManager.MATCH_ARCHIVED_PACKAGES));')
pin('P7 the on-this-phone test asks with flags 0, then MATCH_ARCHIVED_PACKAGES through ApplicationInfoFlags, and never MATCH_ANY_USER',
    0 <= d_a0 < d_a1 and 'MATCH_ANY_USER' not in dec, 'flags0=%d archived=%d' % (d_a0, d_a1))

sys.exit(1 if fails else 0)
PY
}

# suite <ProfileActivity.java> <PlayChoice.java> <AppInstallReceiver.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source or a control is missing, 3 the class did not compile. Only 1 convicts.
suite() {
  local act="$1" cls="$2" air="$3" o rc
  for f in "$act" "$cls" "$air" "$CASES"; do [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }; done
  o=$(mktemp -d -p "$W")
  cp "$cls" "$o/PlayChoice.java"; cp "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/PlayChoice.java" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  rc=0
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$o" com.nowhere.chooser.PlayChoiceCases || rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 3 ;; esac
  rc=0
  pins "$act" "$cls" "$air" || rc=$?
  case "$rc" in 0) echo "  cases and pins ok"; return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

echo "== $CLS + $ACT + $AIR"
suite "$ACT" "$CLS" "$AIR"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc=$rc)"; [ "$rc" = 1 ] && exit 1 || exit 2; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only; one that does not apply or compile fails)"
fails=0
# mut <label> <target: cls|act|air> <perl-expr> [expect: convict|pass]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-convict}" d rc a c r t orig
  d=$(mktemp -d -p "$W"); a="$d/ProfileActivity.java"; c="$d/PlayChoice.java"; r="$d/AppInstallReceiver.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"; cp "$AIR" "$r"
  case "$target" in cls) t="$c"; orig="$CLS" ;; act) t="$a"; orig="$ACT" ;; air) t="$r"; orig="$AIR" ;; esac
  if ! perl -0pi -e "$expr" "$t"; then echo "  ERROR     $label -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$t" "$orig"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  suite "$a" "$c" "$r" >"$d/out" 2>&1; rc=$?
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
mut 'M1 the not-installed text changed' cls 's/On · not installed yet — tap/On · not installed — tap/'
mut 'M2 absent read as off' cls 's/(if \("0"\.equals\(v\)\) return State\.OFF;\n\s*)return State\.ABSENT;/${1}return State.OFF;/'
mut 'M2b the reconcile guard blocks on absent too' cls 's/return s == State\.OFF;/return s != State.ON;/'
mut 'M3 offDrops drops Play services too' cls 's/Collections\.singleton\(VENDING\)/new java.util.HashSet<>(java.util.Arrays.asList(VENDING, GMS))/'
mut 'M3b turnPlayOff drops Play services too' act 's/(for \(String p : PlayChoice\.offDrops\(\)\) applyKeepModeOffThread\(p, null, null, null\);)/$1\n        applyKeepModeOffThread(GMS_PKG, null, null, null);/'
mut 'M4 the user-kept re-add guard removed' act 's/if \(!playOff && !m\.containsKey\(VENDING_PKG\)/if (!m.containsKey(VENDING_PKG)/'
mut 'M4b the auto-pulled re-add guard removed' act 's/\} else if \(!playOff\) \{(\n\s*\/\/ AUTO-pulled)/} else {$1/'
mut 'M4c playOff never set' act 's/final boolean playOff = PlayChoice\.blocksVendingReadd\(playState\(\)\);/final boolean playOff = false;/'
mut 'M4d the guard also blocks gms' act 's/applyStackMember\(m, GMS_PKG, need, preKept\);/if (!playOff) applyStackMember(m, GMS_PKG, need, preKept);/'
mut 'M5 keepModeOnInstall ignores the flag' cls 's/if \(s == State\.ON && isStackMember\(pkg\)\) return ONDEMAND;/if (isStackMember(pkg)) return ONDEMAND;/'
mut 'M5b keepModeOnInstall touches another package' cls 's/if \(s == State\.ON && isStackMember\(pkg\)\) return ONDEMAND;/if (s == State.ON) return ONDEMAND;/'
mut 'M6 the row drawn without the GrapheneOS App Store condition' act 's/PlayChoice\.offered\(isInstalledPkg\(GOS_STORE_PKG\), sessionType/PlayChoice.offered(true, sessionType/'
mut 'M6b offered ignores the GrapheneOS App Store' cls 's/return gosStorePresent && !offline/return !offline/'
mut 'M6c offered ignores the session type (a throwaway gets the row)' cls 's/ && "STORED"\.equals\(sessionType\);/;/'
mut 'M7 turnPlayOff removes the account itself' act 's/new Thread\(\(\) -> signOutGoogle\(a, hash\), "nowhere-google-signout"\)\.start\(\);/android.accounts.AccountManager.get(this).removeAccount(a, this, null, null);/'
mut 'M7b signOutGoogle removes without a recorded mark' act 's/if \(!recorded\) \{/if (false) {/'
mut 'M8 decide does not call keepModeOnInstall' air 's/mode = PlayChoice\.keepModeOnInstall\(play, pkg, mode\);/;/'
mut 'M8b decide records the playdep whether or not it wrote' air 's/if \(wrote && PlayChoice\.userKeepsOnInstall/if (PlayChoice.userKeepsOnInstall/'
mut 'M9 the row drawn in an offline session' act 's/(PlayChoice\.offered\(isInstalledPkg\(GOS_STORE_PKG\), sessionType), offlineSession\)\) return;/$1, false)) return;/'
mut 'M9b offered ignores offline' cls 's/return gosStorePresent && !offline && /return gosStorePresent \&\& /'
mut 'M10 absent no longer follows the keep line' cls 's/return vendingInstalled \|\| vendingKept;/return vendingInstalled;/'
mut 'M10b playRow passes false for kept to rowText' act 's/PlayChoice\.rowText\(st, kept, installed\)/PlayChoice.rowText(st, false, installed)/'
mut 'M10c playRow passes false for kept to tap' act 's/PlayChoice\.tap\(st, kept, installed\)/PlayChoice.tap(st, false, installed)/'
mut 'M11 turnPlayOff goes on when the flag did not land' act 's/if \(playState\(\) != PlayChoice\.State\.OFF\) \{/if (false) {/'
mut 'M11b turnPlayOff drops before it writes the flag' act 's/(    private void turnPlayOff\(\) \{\n)(\s*cfgPut\(PlayChoice\.CFG_KEY, PlayChoice\.raw\(PlayChoice\.State\.OFF\)\);\n)/$1        for (String q : PlayChoice.offDrops()) applyKeepModeOffThread(q, null, null, null);\n$2/'
mut 'M12 showYourApps no longer draws the row' act 's/\n\s*playRow\(ll\); \/\/ NWP-20261122-06[^\n]*//'
mut 'M13 the tap answers swapped' act 's/case OPEN_STORE: openGosStore\(\); break;/case OPEN_STORE: confirmPlayOff(); break;/'
# RF-001: a roamed flag acts only where the GrapheneOS App Store is installed.
mut 'M14 effective ignores the GrapheneOS App Store' cls 's/return gosStorePresent \? stored : State\.ABSENT;/return stored;/'
mut 'M14b playState reads the stored flag without effective' act 's/return PlayChoice\.effective\(PlayChoice\.parse\(readConfig\(\)\.get\(PlayChoice\.CFG_KEY\)\), gosStorePresent\(this\)\);/return PlayChoice.parse(readConfig().get(PlayChoice.CFG_KEY));/'
mut 'M14c decide acts on the flag without the GrapheneOS App Store' air 's/ProfileActivity\.gosStorePresent\(ctx\)\);/true);/'
mut 'M14d gosStorePresent always true' act 's/(static boolean gosStorePresent\(android\.content\.Context ctx\) \{\n\s*)try \{[^\n]*/${1}return true;/'
# RF-002: turning Play on marks every installed stack member On-demand.
mut 'M15 onMarks marks Play Store alone' cls 's/for \(String p : new String\[\] \{VENDING, GMS, GSF\}\)/for (String p : new String[] {VENDING})/'
mut 'M15b onMarks ignores the installed test' cls 's/if \(installed\.test\(p\)\) out\.add\(p\);/out.add(p);/'
mut 'M15c turnPlayOn keeps an existing mode' act 's/applyKeepModeOffThread\(p, MODE_ONDEMAND, null, null\);/applyKeepModeOffThread(p, readAppModes().getOrDefault(p, MODE_ONDEMAND), null, null);/'
mut 'M15d turnPlayOn marks nothing' act 's/\n\s*for \(String p : PlayChoice\.onMarks\(this::isOnDevicePkg\)\) applyKeepModeOffThread\(p, MODE_ONDEMAND, null, null\);//'
mut 'M15e onMarks puts the services before Play Store' cls 's/\{VENDING, GMS, GSF\}\)/{GMS, GSF, VENDING})/'
# RF-003: On with Play Store kept but not on the phone reads the not-installed text and opens the App Store.
mut 'M16 rowText counts a keep line as installed' cls 's/return vendingInstalled \? ON_TEXT : NOT_INSTALLED;/return vendingInstalled || vendingKept ? ON_TEXT : NOT_INSTALLED;/'
mut 'M16b tap counts a keep line as installed' cls 's/return vendingInstalled \? Tap\.CONFIRM_OFF : Tap\.OPEN_STORE;/return vendingInstalled || vendingKept ? Tap.CONFIRM_OFF : Tap.OPEN_STORE;/'
mut 'M16c playRow reads installed with flags 0 (an archived Play Store reads as not installed)' act 's/final boolean installed = isOnDevicePkg\(VENDING_PKG\);/final boolean installed = isInstalledPkg(VENDING_PKG);/'
mut 'M16d isOnDevicePkg drops the archived test' act 's/(private boolean isOnDevicePkg\(String pkg\) \{\n\s*if \(isInstalledPkg\(pkg\)\) return true;\n\s*try \{\n\s*)getPackageManager\(\)[^;]*;/${1}if (true) throw new RuntimeException();/'
# RF-004: the row reads again after the App Store; a snapshot keeps "not installed yet" and the App Store tap.
mut 'M17 the tap uses the reading taken when the row was drawn' act 's/        paintPlayRow\(sub\);\n(\s*row\.addView\(col[^\n]*\n\s*row\.setOnClickListener\(v -> \{\n\s*)switch \(paintPlayRow\(sub\)\) \{/        final PlayChoice.Tap tap = paintPlayRow(sub);\n${1}switch (tap) {/'
mut 'M17b no refresh when the window gets the focus back' act 's/has -> \{ if \(has\) paintPlayRow\(sub\); \}/has -> { }/'
mut 'M17c the focus listener never added' act 's/v\.getViewTreeObserver\(\)\.addOnWindowFocusChangeListener\(onFocus\);/ /'
mut 'M17d the not-installed tap stays OPEN_STORE after the install' cls 's/return vendingInstalled \? Tap\.CONFIRM_OFF : Tap\.OPEN_STORE;/return vendingKept \&\& vendingInstalled ? Tap.CONFIRM_OFF : Tap.OPEN_STORE;/'
# NWP-20261129-16 (h59 #7): a hand install of Play Store with Play Off turns Play back On.
mut 'N1 turnsOnAtInstall always false' cls 's/return s == State\.OFF && VENDING\.equals\(pkg\) && !replacing && broadcast;/return false;/'
mut 'N2 turnsOnAtInstall fires on the catch-up' cls 's/(VENDING\.equals\(pkg\) && !replacing) && broadcast;/$1;/'
mut 'N3 turnsOnAtInstall fires on an update' cls 's/(VENDING\.equals\(pkg\)) && !replacing( && broadcast;)/$1$2/'
mut 'N4 turnsOnAtInstall fires for gms' cls 's/s == State\.OFF && VENDING\.equals\(pkg\) && !replacing/s == State.OFF \&\& isStackMember(pkg) \&\& !replacing/'
mut 'N9 backOnMarks lists VENDING' cls 's/new String\[\] \{GMS, GSF\}/new String[] {VENDING, GMS, GSF}/'
mut 'M18 decide passes true for the broadcast path' air 's/"broadcast"\.equals\(via\)/true/'
mut 'M18b the on-this-phone test reads every user' air 's/(PackageManager\.)MATCH_ARCHIVED_PACKAGES/$1MATCH_ANY_USER/'
mut 'probe: the reconcile guard reformatted (must pass)' act 's/if \(!playOff && !m\.containsKey\(VENDING_PKG\)/if ( !playOff\n                    \&\& !m.containsKey(VENDING_PKG)/' pass
mut 'probe: a comment naming removeAccount in turnPlayOff (must pass)' act 's/(    private void turnPlayOff\(\) \{\n)/$1        \/\/ never removeAccount( here\n/' pass
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
