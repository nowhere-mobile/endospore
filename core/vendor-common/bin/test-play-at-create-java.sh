#!/usr/bin/env bash
# test-play-at-create-java.sh [--mutate] -- the Google Play question on the create form, under javac (NWP-20261124-09).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-10-26 ("on Endospore, creating a profile asks one question,
# "Use Google Play apps on this profile?", off by default ...") and 2026-11-01 (h50 #7: "on" at Create marks Play kept
# On-demand). PlayAtCreate (pure java) holds the rules and is compiled as-is with PlayChoice and PlayAtCreateCases: the
# decided words verbatim, offered only with the GrapheneOS App Store and in create mode, "1" for on and nothing for
# off, and the session accepting exactly "1". The PINS check the wiring the cases cannot see, on the sources with
# comments stripped:
#   P1  setCreateMode holds, byte for byte, the switch's visibility line through PlayAtCreate.offered(gateGosStore,
#       createMode) and its reset to off; gateGosStore is set once, from ProfileActivity.gosStorePresent(this).
#   P2  the switch is built GateSwitch-styled with PlayAtCreate.QUESTION, off and hidden; nothing ever checks it on;
#       clearSignInFields (the screen-off clear) turns it off; lockGateForm locks it with the form.
#   P3  roamLogin reads the answer at the tap, before its worker thread, only for a create; the send line is exactly
#       `if (isCreate && playAtCreate != null) sendPlayAtCreate(uid, playAtCreate);`, once in the file, after
#       ensureRoamedHomeRole(uid) and before the progress-100 line and the switch-in; prepRoamedUser(uid) and
#       ensureSessionScreenTimeout(uid) stay adjacent.
#   P4  sendPlayAtCreate sends an explicit broadcast to that user (sendBroadcastAsUser, PlayAtCreateReceiver.class,
#       FLAG_INCLUDE_STOPPED_PACKAGES, UserHandle.of(uid)) carrying the value alone; it names no profile.
#   P5  PlayAtCreateReceiver.onReceive returns unless PlayAtCreate.accepts(extra), before its one write, which goes
#       through ProfileActivity.cfgPutStatic(ctx, PlayChoice.CFG_KEY, v); it writes nothing else and marks no package.
#   P6  the manifest declares the receiver once, exactly `<receiver android:name=".PlayAtCreateReceiver"
#       android:exported="false"/>`.
#   P7  cfgPut only delegates to cfgPutStatic(this, key, val); cfgPutStatic reads through SettingsText.read and
#       returns on null before StoreInstaller.writeAtomic (an unreadable file is never written over).
#
# What it does NOT prove: the handset run (the question on an Endospore create form, the broadcast delivered before
# the switch-in, play.wanted=1 in the new session, Play installed from the App Store kept On-demand). That is the
# backlog row's CLOSES WHEN.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-play-at-create-java.sh            # the cases and the pins
#   bash test-play-at-create-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
CLS="$SRCDIR/PlayAtCreate.java"
PCH="$SRCDIR/PlayChoice.java"
ACT="$SRCDIR/ChooserActivity.java"
PRO="$SRCDIR/ProfileActivity.java"
RCV="$SRCDIR/PlayAtCreateReceiver.java"
MAN="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/play-at-create/PlayAtCreateCases.java"
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

# pins <ChooserActivity.java> <ProfileActivity.java> <PlayAtCreateReceiver.java> <AndroidManifest.xml>
#   -> 0 ok, 1 a pin failed, 2 a control failed. A missing file reads as empty, so its pins fail (rc 1).
pins() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import io, os, re, sys
act_path, pro_path, rcv_path, man_path = sys.argv[1:5]

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

flat = lambda s: re.sub(r'\s+', '', s or '')
fails = []
def pin(name, ok, why):
    if ok: print('  ok    ' + name)
    else: print('  PIN   ' + name + ': ' + why); fails.append(name)

act_raw = read(act_path)
act = strip_comments(act_raw)
pro = strip_comments(read(pro_path))
rcv = strip_comments(read(rcv_path))
man = read(man_path)

controls = {
    'setCreateMode': method(act, 'private void setCreateMode(boolean on) {'),
    'clearSignInFields': method(act, 'private void clearSignInFields() {'),
    'lockGateForm': method(act, 'private void lockGateForm(boolean lock) {'),
    'roamLogin': method(act, 'private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {'),
    'cfgPut': method(pro, 'private void cfgPut(String key, String val) {'),
}
for k, v in controls.items():
    if v is None:
        print('  CONTROL %s not found exactly once (or its braces do not balance)' % k); sys.exit(2)
scm, csf, lgf, rl = controls['setCreateMode'], controls['clearSignInFields'], controls['lockGateForm'], controls['roamLogin']

# P1: the two setCreateMode lines, byte for byte (comments included, from the raw source)
VIS = ('        playAtCreateSw.setVisibility(PlayAtCreate.offered(gateGosStore, createMode) ? View.VISIBLE : View.GONE);'
       ' // NWP-20261124-09\n')
RST = '        playAtCreateSw.setChecked(false);                                   // NWP-20261124-09: off by default, every time\n'
raw_scm = method(act_raw, 'private void setCreateMode(boolean on) {') or ''
pin('P1 setCreateMode shows the switch through PlayAtCreate.offered(gateGosStore, createMode) (byte for byte, once)',
    raw_scm.count(VIS) == 1, 'want exactly one line: ' + VIS.strip())
pin('P1 setCreateMode turns the switch off every time (byte for byte, once)',
    raw_scm.count(RST) == 1, 'want exactly one line: ' + RST.strip())
pin('P1 setCreateMode sets the switch visibility only through PlayAtCreate.offered',
    scm.count('playAtCreateSw.setVisibility(') == 1, 'calls=%d' % scm.count('playAtCreateSw.setVisibility('))
fact = flat(act)
pin('P1 gateGosStore is assigned once, from ProfileActivity.gosStorePresent(this)',
    len(re.findall(r'gateGosStore=', fact)) == 1 and fact.count('gateGosStore=ProfileActivity.gosStorePresent(this);') == 1,
    'assignments=%d' % len(re.findall(r'gateGosStore=', fact)))

# P2: the switch's build, off and hidden; never checked on; cleared off; locked with the form
b0 = fact.find('playAtCreateSw=GateSwitch.style(newandroid.widget.Switch(this),GatePalette.active());')
b1 = fact.find('ll.addView(playAtCreateSw,', b0 if b0 >= 0 else 0)
build = fact[b0:b1] if 0 <= b0 < b1 else ''
pin('P2 the switch is built once, GateSwitch-styled, and added to the form',
    fact.count('playAtCreateSw=GateSwitch.style(newandroid.widget.Switch(this),GatePalette.active());') == 1 and build != '',
    'build at %d, addView at %d' % (b0, b1))
for need, why in [
    ('playAtCreateSw.setText(PlayAtCreate.QUESTION);', 'its text is PlayAtCreate.QUESTION'),
    ('playAtCreateSw.setChecked(false);', 'it starts off'),
    ('playAtCreateSw.setVisibility(View.GONE);', 'it starts hidden'),
]:
    pin('P2 the build: ' + why, build.count(need) == 1, 'want exactly one ' + need)
pin('P2 nothing checks the switch on', not re.search(r'playAtCreateSw\.setChecked\((?!false\))', fact),
    'a setChecked( other than false')
pin('P2 clearSignInFields turns the switch off',
    flat(csf).count('if(playAtCreateSw!=null)playAtCreateSw.setChecked(false);') == 1, flat(csf)[-300:])
pin('P2 lockGateForm locks the switch with the form', re.search(r'View\[\]vs=\{[^}]*\bplayAtCreateSw\b', flat(lgf)) is not None,
    'playAtCreateSw not in the vs array')

# P3: the capture at the tap, and the send
frl = flat(rl)
CAP = ('finalStringplayAtCreate=PlayAtCreate.value(isCreate&&playAtCreateSw!=null'
       '&&playAtCreateSw.getVisibility()==View.VISIBLE&&playAtCreateSw.isChecked());')
cap = frl.find(CAP); thr = frl.find('newThread(')
pin('P3 roamLogin reads the answer once, only for a create, before its worker thread',
    frl.count(CAP) == 1 and 0 <= cap < thr, 'capture at %d, new Thread( at %d' % (cap, thr))
pin('P3 nothing else in roamLogin reads the switch', frl.count('playAtCreateSw') == 3, 'reads=%d' % frl.count('playAtCreateSw'))
SEND = 'if (isCreate && playAtCreate != null) sendPlayAtCreate(uid, playAtCreate);'
calls = re.findall(r'(?<![\w.])sendPlayAtCreate\(', act)
pin('P3 sendPlayAtCreate is declared once and called once', len(calls) == 2, 'occurrences=%d' % len(calls))
pin('P3 the send line is exactly `' + SEND + '`, in roamLogin', rl.count(SEND) == 1, 'want exactly one in roamLogin')
s_at = rl.find(SEND)
home = rl.find('ensureRoamedHomeRole(uid);')
prog = rl.find('runOnUiThread(() -> progressBar.setProgress(100));')
sw = rl.find('switchToUser(uid')
pin('P3 the send comes after ensureRoamedHomeRole(uid), before the progress-100 line and the switch-in',
    0 <= home < s_at < prog < sw, 'home %d, send %d, progress %d, switch %d' % (home, s_at, prog, sw))
pin('P3 prepRoamedUser(uid) and ensureSessionScreenTimeout(uid) stay adjacent',
    re.search(r'prepRoamedUser\(uid\);\s*ensureSessionScreenTimeout\(uid\);', rl) is not None, 'not adjacent')

# P4: the broadcast
spc = flat(method(act, 'private void sendPlayAtCreate(int uid, String value) {'))
for need, why in [
    ('app.sendBroadcastAsUser(newIntent(app,PlayAtCreateReceiver.class)', 'an explicit broadcast to PlayAtCreateReceiver'),
    ('.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)', 'FLAG_INCLUDE_STOPPED_PACKAGES'),
    ('.putExtra(PlayAtCreate.EXTRA,value),android.os.UserHandle.of(uid));', 'the value alone, to that user'),
]:
    pin('P4 sendPlayAtCreate: ' + why, spc.count(need) == 1, 'want exactly one ' + need)
pin('P4 sendPlayAtCreate puts one extra', spc.count('.putExtra(') == 1, 'putExtra=%d' % spc.count('.putExtra('))
pin('P4 sendPlayAtCreate names no profile', spc != '' and not re.search(r'(?<![\w.])(name|pw|profile)(?!\w)', spc),
    'a name / pw / profile token in its body')

# P5: the receiver
orc = flat(method(rcv, 'public void onReceive(Context ctx, Intent intent) {'))
gate = orc.find('if(!PlayAtCreate.accepts(v))return;')
put = orc.find('ProfileActivity.cfgPutStatic(ctx,PlayChoice.CFG_KEY,v);')
pin('P5 onReceive reads the value from PlayAtCreate.EXTRA',
    orc.count('Stringv=intent.getStringExtra(PlayAtCreate.EXTRA);') == 1, orc[:200])
pin('P5 onReceive returns unless PlayAtCreate.accepts(v), before its one cfgPutStatic write',
    0 <= gate < put and orc.count('cfgPutStatic(') == 1, 'gate at %d, write at %d' % (gate, put))
pin('P5 onReceive writes nothing else and marks no package',
    orc != '' and not re.search(r'writeAtomic|FileWriter|FileOutputStream|applyKeepMode|markKeep|setPlayDep|cfgPut\(', orc),
    'another write in onReceive')
pin('P5 onReceive logs no profile', orc != '' and not re.search(r'(?<![\w.])(name|pw|profile)(?!\w)', orc),
    'a name / pw / profile token in its body')

# P6: the manifest
REC = '<receiver android:name=".PlayAtCreateReceiver" android:exported="false"/>'
pin('P6 the manifest declares PlayAtCreateReceiver once, exported="false"',
    man.count(REC) == 1 and man.count('".PlayAtCreateReceiver"') == 1, 'want exactly one ' + REC)

# P7: cfgPut and its shared writer
pin('P7 cfgPut only delegates to cfgPutStatic(this, key, val)',
    flat(controls['cfgPut']) == 'privatevoidcfgPut(Stringkey,Stringval){cfgPutStatic(this,key,val);}', flat(controls['cfgPut']))
cps = flat(method(pro, 'static void cfgPutStatic(android.content.Context ctx, String key, String val) {'))
rd = cps.find('Stringtext=SettingsText.read(newjava.io.File(ctx.getFilesDir(),CFG_FILE));')
nl = cps.find('if(text==null){')
rt = cps.find('return;}', nl if nl >= 0 else 0)
wa = cps.find('StoreInstaller.writeAtomic(newjava.io.File(ctx.getFilesDir(),CFG_FILE),sb.toString());')
pin('P7 cfgPutStatic reads through SettingsText.read and returns on null before StoreInstaller.writeAtomic',
    0 <= rd < nl < rt < wa and cps.count('writeAtomic(') == 1, 'read %d, null %d, return %d, write %d' % (rd, nl, rt, wa))
pin('P7 cfgPutStatic merges into the file it read (SettingsText.parseConfig, then m.put)',
    cps.count('java.util.Map<String,String>m=SettingsText.parseConfig(text);m.put(key,val);') == 1, cps[:300])

if fails:
    print('  %d pin(s) failed' % len(fails)); sys.exit(1)
print('  pins ok')
PY
}

# suite <PlayAtCreate.java> <ChooserActivity.java> <ProfileActivity.java> <PlayAtCreateReceiver.java> <manifest>
#   -> 0 ok, 1 a case or pin failed, 2 the suite could not run (a control, or a copy that does not compile)
suite() {
  local cls="$1" act="$2" pro="$3" rcv="$4" man="$5" d rc_c=0 rc_p
  d=$(mktemp -d -p "$W")
  if [ ! -f "$cls" ]; then
    echo "  FAIL  cases: PlayAtCreate.java is absent"; rc_c=1
  else
    mkdir -p "$d/src" "$d/out"
    cp "$cls" "$d/src/PlayAtCreate.java"; cp "$PCH" "$d/src/PlayChoice.java"; cp "$CASES" "$d/src/PlayAtCreateCases.java"
    if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/PlayAtCreate.java" "$d/src/PlayChoice.java" \
        "$d/src/PlayAtCreateCases.java" >"$d/javac.out" 2>&1; then
      echo "  BROKEN: the cases do not compile"; sed 's/^/      /' "$d/javac.out" | head -10; return 2
    fi
    "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.PlayAtCreateCases || rc_c=1
  fi
  pins "$act" "$pro" "$rcv" "$man"; rc_p=$?
  [ "$rc_p" = 2 ] && return 2
  [ "$rc_c" = 0 ] && [ "$rc_p" = 0 ] && return 0
  return 1
}

echo "== $CLS + $ACT + $PRO + $RCV + $MAN"
suite "$CLS" "$ACT" "$PRO" "$RCV" "$MAN"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc=$rc)"; [ "$rc" = 1 ] && exit 1 || exit 2; }
echo "  cases and pins ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only; one that does not apply or compile fails)"
fails=0
# mut <label> <target: cls|act|pro|rcv|man> <perl-expr> [expect: convict|pass]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-convict}" d rc c a p r m t orig
  d=$(mktemp -d -p "$W"); c="$d/PlayAtCreate.java"; a="$d/ChooserActivity.java"; p="$d/ProfileActivity.java"
  r="$d/PlayAtCreateReceiver.java"; m="$d/AndroidManifest.xml"
  cp "$CLS" "$c"; cp "$ACT" "$a"; cp "$PRO" "$p"; cp "$RCV" "$r"; cp "$MAN" "$m"
  case "$target" in cls) t="$c"; orig="$CLS" ;; act) t="$a"; orig="$ACT" ;; pro) t="$p"; orig="$PRO" ;;
    rcv) t="$r"; orig="$RCV" ;; man) t="$m"; orig="$MAN" ;; esac
  if ! perl -0pi -e "$expr" "$t"; then echo "  ERROR     $label -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$t" "$orig"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  suite "$c" "$a" "$p" "$r" "$m" >"$d/out" 2>&1; rc=$?
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
mut 'M1 shown on Diaspore: offered ignores the App Store' cls 's/return gosStorePresent && createMode;/return createMode;/'
mut 'M1b setCreateMode shows the switch without the App Store' act 's/PlayAtCreate\.offered\(gateGosStore, createMode\)/PlayAtCreate.offered(true, createMode)/'
mut 'M1c gateGosStore always true' act 's/gateGosStore = ProfileActivity\.gosStorePresent\(this\);/gateGosStore = true;/'
mut 'M2 default on: the switch is built checked' act 's/playAtCreateSw\.setChecked\(false\);\n(\s*playAtCreateSw\.setVisibility\(View\.GONE\);)/playAtCreateSw.setChecked(true);\n$1/'
mut 'M2b default on: setCreateMode checks the switch' act 's/        playAtCreateSw\.setChecked\(false\);( +\/\/ NWP-20261124-09: off by default)/        playAtCreateSw.setChecked(true);$1/'
mut 'M3 setCreateMode no longer resets the switch' act 's/\n        playAtCreateSw\.setChecked\(false\); +\/\/ NWP-20261124-09: off by default, every time//'
mut 'M3b the screen-off clear no longer resets the switch' act 's/\n\s*if \(playAtCreateSw != null\) playAtCreateSw\.setChecked\(false\);[^\n]*//'
mut 'M4 off writes "0"' cls 's/return on \? "1" : null;/return on ? "1" : "0";/'
mut 'M5 sent on a sign-in' act 's/if \(isCreate && playAtCreate != null\) sendPlayAtCreate/if (playAtCreate != null) sendPlayAtCreate/'
mut 'M5b the tap reads the switch on a sign-in too' act 's/PlayAtCreate\.value\(isCreate && playAtCreateSw != null/PlayAtCreate.value(playAtCreateSw != null/'
mut 'M6 sent after the switch-in' act 's/\n(\s*if \(isCreate && playAtCreate != null\) sendPlayAtCreate\(uid, playAtCreate\);[^\n]*)(.*?switchToUser\(uid, ownedLbls\); finish\(\); \}\);[^\n]*)/$2\n$1/s'
mut 'M6b the switch read in the worker, not at the tap' act 's/(\n\s*final String playAtCreate = PlayAtCreate\.value\([^;]*;)(.*?new Thread\(\(\) -> \{\n)/$2$1/s'
mut 'M7 the receiver writes on any extra' rcv 's/\s*if \(!PlayAtCreate\.accepts\(v\)\) return;//'
mut 'M7b accepts any non-null extra' cls 's/return "1"\.equals\(extra\);/return extra != null;/'
mut 'M7c the receiver writes after a gate that does not return' rcv 's/if \(!PlayAtCreate\.accepts\(v\)\) return;/if (!PlayAtCreate.accepts(v)) android.util.Log.i("NowhereChooser", "x");/'
mut 'M8 accepts trims' cls 's/return "1"\.equals\(extra\);/return extra != null \&\& "1".equals(extra.trim());/'
mut 'M9 manifest exported="true"' man 's/<receiver android:name="\.PlayAtCreateReceiver" android:exported="false"\/>/<receiver android:name=".PlayAtCreateReceiver" android:exported="true"\/>/'
mut 'M9b the receiver dropped from the manifest' man 's/\n\s*<receiver android:name="\.PlayAtCreateReceiver"[^\n]*//'
mut 'M10 sent between prepRoamedUser and ensureSessionScreenTimeout' act 's/\n\s*if \(isCreate && playAtCreate != null\) sendPlayAtCreate\(uid, playAtCreate\);[^\n]*//; s/(\n(\s*)prepRoamedUser\(uid\);[^\n]*)/$1\n$2if (isCreate \&\& playAtCreate != null) sendPlayAtCreate(uid, playAtCreate);/'
mut 'M11 the decided words changed' cls 's/It downloads about 130 MB the first time\./It downloads about 130 MB./'
mut 'M12 the broadcast carries a second extra' act 's/\.putExtra\(PlayAtCreate\.EXTRA, value\),/.putExtra(PlayAtCreate.EXTRA, value).putExtra("n", String.valueOf(uid)),/'
mut 'M12b the broadcast is implicit' act 's/new Intent\(app, PlayAtCreateReceiver\.class\)/new Intent("com.nowhere.chooser.PLAY_AT_CREATE")/'
mut 'M13 cfgPutStatic writes over an unreadable file' pro 's/(static void cfgPutStatic[^\n]*\n(?:[^\n]*\n){3})\s*if \(text == null\) \{\n[^\n]*\n\s*return;\n\s*\}\n/$1        if (text == null) text = "";\n/'
mut 'M13b cfgPut keeps its own body again' pro 's/(    private void cfgPut\(String key, String val\) \{\n)        cfgPutStatic\(this, key, val\);\n/$1        String text = SettingsText.read(new java.io.File(getFilesDir(), CFG_FILE));\n        if (text == null) return;\n        cfgPutStatic(this, key, val);\n/'
mut 'M14 the receiver also marks Play Store kept' rcv 's/(ProfileActivity\.cfgPutStatic\(ctx, PlayChoice\.CFG_KEY, v\);)/$1\n        ProfileActivity.cfgPutStatic(ctx, "keep.com.android.vending", "ondemand");/'
mut 'probe: the send line with its comment moved above it (must pass)' act 's/(\n(\s*)if \(isCreate && playAtCreate != null\) sendPlayAtCreate\(uid, playAtCreate\);) \/\/ NWP-20261124-09: before switch-in/\n$2\/\/ NWP-20261124-09: before switch-in$1/' pass
mut 'probe: another call between the home role and the send (must pass)' act 's/(\n(\s*)if \(isCreate && playAtCreate != null\) sendPlayAtCreate)/\n$2android.util.Log.i("NowhereChooser", "x");$1/' pass
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
