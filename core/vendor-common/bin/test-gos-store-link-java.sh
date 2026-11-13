#!/usr/bin/env bash
# test-gos-store-link-java.sh [--mutate] -- the Google Play row opens the store's Play entry, under javac
# (NWP-20261202-21).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-10 (item 1: the row's tap landed on the App Store's main
# list, "so the slice finds a way to open the Play entry for the prompt and the row alike") and 2026-11-01 (h50 #7 A1:
# the row opens the App Store's Play page). GosStoreLink (pure java) holds the link's parts and the route rule and is
# compiled as-is with PlayChoice and GosStoreLinkCases: the Android literals, Play Store as the entry, the fixed log
# lines, and route = the entry when the link resolves, else the store's list, else nothing. The PINS check the wiring
# the cases cannot see, on ProfileActivity with comments stripped:
#   G1  openGosStore is declared once.
#   G2  it builds the link exactly: new Intent(GosStoreLink.ACTION).setPackage(GosStoreLink.STORE_PKG)
#       .putExtra(GosStoreLink.EXTRA, GosStoreLink.ENTRY_PKG) (only the store can answer it).
#   G3  it resolves the link with flags 0 before the route (MATCH_DEFAULT_ONLY never resolves: the store's filter has
#       no DEFAULT category).
#   G4  the route decides, from the resolution and the store's launch intent.
#   G5  PLAY_ENTRY starts the link at the resolved activity, not the launch intent, and logs LOG_ENTRY.
#   G6  STORE_LIST starts the launch intent and logs LOG_LIST.
#   G7  NONE logs LOG_NONE, shows the toast and returns.
#   G8  one start, with FLAG_ACTIVITY_NEW_TASK; a throw shows the toast.
#   G9  every log line in the method is a GosStoreLink.LOG_ constant, nothing added to it.
#   G10 playRow's OPEN_STORE case and turnPlayOn each call it (the total number of callers is NOT pinned).
#   G11 GosStoreLink.STORE_PKG equals ProfileActivity.GOS_STORE_PKG.
#
# What it does NOT prove: the handset run (the link resolves to the store's activity on lynx, and the row's tap shows
# Play Store's entry with logcat "gos store: opened at the Play entry"). That is the merger's device check.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gos-store-link-java.sh            # the cases and the pins
#   bash test-gos-store-link-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
CLS="$SRCDIR/GosStoreLink.java"
PCH="$SRCDIR/PlayChoice.java"
PRO="$SRCDIR/ProfileActivity.java"
CASES="$root/core/chooser/tests/gos-store-link/GosStoreLinkCases.java"
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

# pins <ProfileActivity.java> <GosStoreLink.java>
#   -> 0 ok, 1 a pin failed, 2 a control failed.
pins() {
  python3 -I - "$1" "$2" <<'PY'
import io, os, re, sys
pro_path, cls_path = sys.argv[1:3]

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

pro = strip_comments(read(pro_path))
cls = strip_comments(read(cls_path))

controls = {
    'openGosStore': method(pro, 'private void openGosStore() {'),
    'playRow': method(pro, 'private void playRow(LinearLayout ll) {'),
    'turnPlayOn': method(pro, 'private void turnPlayOn() {'),
}
for k, v in controls.items():
    if v is None:
        print('  CONTROL %s not found exactly once (or its braces do not balance)' % k); sys.exit(2)
og = flat(controls['openGosStore'])
TOAST = 'android.widget.Toast.makeText(this,"Couldn\'topentheGrapheneOSAppStore.",android.widget.Toast.LENGTH_SHORT).show();'

def block(code, start):
    """The text after `start` up to the next `case`/`default:`/closing of the switch, or '' when start is absent."""
    if code.count(start) != 1: return ''
    i = code.index(start) + len(start)
    m = re.search(r'case[A-Z_]+:|default:|\}start\.addFlags', code[i:])
    return code[i:i + m.start()] if m else code[i:]

pin('G1 openGosStore is declared once', pro.count('private void openGosStore()') == 1,
    'declarations=%d' % pro.count('private void openGosStore()'))

LINK = ('finalandroid.content.Intentlink=newandroid.content.Intent(GosStoreLink.ACTION)'
        '.setPackage(GosStoreLink.STORE_PKG).putExtra(GosStoreLink.EXTRA,GosStoreLink.ENTRY_PKG);')
pin('G2 it builds the link: ACTION, setPackage(STORE_PKG), putExtra(EXTRA, ENTRY_PKG), exactly once',
    og.count(LINK) == 1 and og.count('newandroid.content.Intent(') == 1, og[:260])

RES = 'finalandroid.content.pm.ResolveInfori=getPackageManager().resolveActivity(link,0);'
SW = 'switch(GosStoreLink.route('
pin('G3 it resolves the link with flags 0, once, before the route',
    og.count(RES) == 1 and og.count('resolveActivity(') == 1 and 0 <= og.find(RES) < og.find(SW),
    'resolve at %d, route at %d' % (og.find(RES), og.find(SW)))
pin('G3 it never asks for MATCH_DEFAULT_ONLY', 'MATCH_DEFAULT_ONLY' not in og, 'MATCH_DEFAULT_ONLY in the method')

LAUNCH = 'finalandroid.content.Intentlaunch=getPackageManager().getLaunchIntentForPackage(GOS_STORE_PKG);'
pin('G4 the route decides from the resolution and the launch intent',
    og.count('switch(GosStoreLink.route(ri!=null&&ri.activityInfo!=null,launch!=null)){') == 1 and og.count(LAUNCH) == 1
    and og.count('GosStoreLink.route(') == 1, og[:400])

pin('G5 PLAY_ENTRY starts the link at the resolved activity and logs LOG_ENTRY',
    block(og, 'casePLAY_ENTRY:') == ('link.setClassName(ri.activityInfo.packageName,ri.activityInfo.name);start=link;'
                                     'android.util.Log.i("NowhereChooser",GosStoreLink.LOG_ENTRY);break;'),
    block(og, 'casePLAY_ENTRY:') or 'no casePLAY_ENTRY:')
pin('G6 STORE_LIST starts the launch intent and logs LOG_LIST',
    block(og, 'caseSTORE_LIST:') == 'start=launch;android.util.Log.i("NowhereChooser",GosStoreLink.LOG_LIST);break;',
    block(og, 'caseSTORE_LIST:') or 'no caseSTORE_LIST:')
pin('G7 NONE logs LOG_NONE, shows the toast and returns',
    block(og, 'caseNONE:default:') == 'android.util.Log.i("NowhereChooser",GosStoreLink.LOG_NONE);' + TOAST + 'return;',
    block(og, 'caseNONE:default:') or 'no caseNONE:default:')

START = 'start.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);try{startActivity(start);}catch(Throwablet){' + TOAST + '}'
pin('G8 one start with FLAG_ACTIVITY_NEW_TASK; a throw shows the toast',
    og.count(START) == 1 and og.count('startActivity(') == 1, 'startActivity=%d' % og.count('startActivity('))

logs = re.findall(r'Log\.\w\(([^;]*)\);', og)
pin('G9 every log line is a GosStoreLink.LOG_ constant, alone',
    len(logs) == 3 and all(re.fullmatch(r'"NowhereChooser",GosStoreLink\.LOG_(ENTRY|LIST|NONE)', l) for l in logs),
    'log calls: %r' % logs)

pin('G10 playRow\'s OPEN_STORE case opens through openGosStore',
    flat(controls['playRow']).count('caseOPEN_STORE:openGosStore();break;') == 1, 'no caseOPEN_STORE:openGosStore();break;')
pin('G10 turnPlayOn opens through openGosStore', flat(controls['turnPlayOn']).count('openGosStore();') == 1,
    'calls=%d' % flat(controls['turnPlayOn']).count('openGosStore();'))

a = re.findall(r'static final String GOS_STORE_PKG\s*=\s*"([^"]*)";', pro)
b = re.findall(r'static final String STORE_PKG\s*=\s*"([^"]*)";', cls)
pin('G11 GosStoreLink.STORE_PKG equals ProfileActivity.GOS_STORE_PKG', len(a) == 1 and a == b, '%r vs %r' % (a, b))

if fails:
    print('  %d pin(s) failed' % len(fails)); sys.exit(1)
print('  pins ok')
PY
}

# suite <GosStoreLink.java> <ProfileActivity.java>
#   -> 0 ok, 1 a case or pin failed, 2 the suite could not run (a control, or a copy that does not compile)
suite() {
  local cls="$1" pro="$2" d rc_c=0 rc_p
  d=$(mktemp -d -p "$W")
  if [ ! -f "$cls" ]; then
    echo "  FAIL  cases: GosStoreLink.java is absent"; rc_c=1
  else
    mkdir -p "$d/src" "$d/out"
    cp "$cls" "$d/src/GosStoreLink.java"; cp "$PCH" "$d/src/PlayChoice.java"; cp "$CASES" "$d/src/GosStoreLinkCases.java"
    if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/GosStoreLink.java" "$d/src/PlayChoice.java" \
        "$d/src/GosStoreLinkCases.java" >"$d/javac.out" 2>&1; then
      echo "  BROKEN: the cases do not compile"; sed 's/^/      /' "$d/javac.out" | head -10; return 2
    fi
    "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.GosStoreLinkCases || rc_c=1
  fi
  pins "$pro" "$cls"; rc_p=$?
  [ "$rc_p" = 2 ] && return 2
  [ "$rc_c" = 0 ] && [ "$rc_p" = 0 ] && return 0
  return 1
}

echo "== $CLS + $PRO"
suite "$CLS" "$PRO"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc=$rc)"; [ "$rc" = 1 ] && exit 1 || exit 2; }
echo "  cases and pins ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only; one that does not apply or compile fails)"
fails=0
# mut <label> <target: cls|pro> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc c p t orig
  d=$(mktemp -d -p "$W"); c="$d/GosStoreLink.java"; p="$d/ProfileActivity.java"
  cp "$CLS" "$c"; cp "$PRO" "$p"
  case "$target" in cls) t="$c"; orig="$CLS" ;; pro) t="$p"; orig="$PRO" ;; esac
  if ! perl -0pi -e "$expr" "$t"; then echo "  ERROR     $label -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$t" "$orig"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  suite "$c" "$p" >"$d/out" 2>&1; rc=$?
  case "$rc" in
    1) echo "  CONVICTED $label"; grep -E "^  (PIN|FAIL) " "$d/out" | cut -c1-110 | sed "s/^/      by/" ;;
    0) echo "  SURVIVED  $label"; fails=$((fails+1)) ;;
    *) echo "  BROKEN    $label -- the mutant did not compile or extract (rc $rc)"; tail -3 "$d/out" | sed 's/^/      /'; fails=$((fails+1)) ;;
  esac
}
mut 'M1 route prefers the list when the entry resolves (C2)' cls 's/if \(entryResolves\) return Route\.PLAY_ENTRY;/if (entryResolves \&\& !launchIntentPresent) return Route.PLAY_ENTRY;/'
mut 'M2 the extra names com.google.android.gms (G2)' pro 's/\.putExtra\(GosStoreLink\.EXTRA, GosStoreLink\.ENTRY_PKG\)/.putExtra(GosStoreLink.EXTRA, "com.google.android.gms")/'
mut 'M2b ENTRY_PKG is Play services (C1)' cls 's/ENTRY_PKG = PlayChoice\.VENDING;/ENTRY_PKG = PlayChoice.GMS;   /'
mut 'M3 setPackage dropped: any store could answer (G2)' pro 's/\.setPackage\(GosStoreLink\.STORE_PKG\)//'
mut 'M4 openGosStore starts the launch intent on PLAY_ENTRY (G5)' pro 's/start = link;/start = launch;/'
mut 'M4b PLAY_ENTRY starts the package-only link, no resolved activity (G5)' pro 's/\n\s*link\.setClassName\(ri\.activityInfo\.packageName, ri\.activityInfo\.name\);//'
mut 'M5 the resolve check removed: entryResolves hard-coded true (G4)' pro 's/GosStoreLink\.route\(ri != null && ri\.activityInfo != null, /GosStoreLink.route(true, /'
mut 'M5b resolved with MATCH_DEFAULT_ONLY, which never resolves on the store filter (G3)' pro 's/resolveActivity\(link, 0\)/resolveActivity(link, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)/'
mut 'M6 the NONE toast removed (G7)' pro 's/(GosStoreLink\.LOG_NONE\);)\n\s*android\.widget\.Toast\.makeText[^\n]*/$1/'
mut 'M7 a log line names the package (G9)' pro 's/GosStoreLink\.LOG_ENTRY\)/GosStoreLink.LOG_ENTRY + " " + GosStoreLink.ENTRY_PKG)/'
mut 'M8 route never returns NONE (C4)' cls 's/return launchIntentPresent \? Route\.STORE_LIST : Route\.NONE;/return Route.STORE_LIST;/'
mut 'M9 the row no longer opens the store (G10)' pro 's/case OPEN_STORE: openGosStore\(\); break;/case OPEN_STORE: break;/'
mut 'M10 STORE_PKG is not the App Store (C1, G11)' cls 's/STORE_PKG = "app\.grapheneos\.apps";/STORE_PKG = "com.android.vending";/'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
