#!/usr/bin/env bash
# test-update-notice-tap-java.sh [--mutate] [--tap <UpdateNoticeTap.java>] [--chooser <ChooserActivity.java>]
#     [--profile <ProfileActivity.java>] -- the "update available" notice opens Profile at its Update card (NWP-20261208-32).
#
# WHAT IT PROVES. Cases U1-U5 compile the REAL UpdateNoticeTap and the REAL LandingLine against the android stubs in
# core/chooser/tests/update-notice-tap/ and RUN them: the intent opens ProfileActivity in the given context's package
# (U1) with EXTRA_OPEN = OPEN_UPDATE (U2), NEW_TASK and SINGLE_TOP (U3); pending() makes ONE immutable PendingIntent
# on the very context it is given, the session user's, with the notice's id as its request (U4); act() over its whole
# table (U5). Pins P1-P3 read the comment-stripped ChooserActivity and ProfileActivity: postUpdateNotice sets the
# content intent once, made on uc, outside every if, so every channel carries it (P1), with no setAutoCancel (P2);
# ProfileActivity calls openUpdateIfAsked() after the probe answers and from onNewIntent, records the Update card,
# and removes the extra only under DROP and SCROLL (P3).
# What it does NOT prove: that a tap on a handset opens Profile with the card in view (the merger's lynx check).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-update-notice-tap-java.sh            # the cases and the pins
#   bash test-update-notice-tap-java.sh --mutate   # ... plus broken copies that must each FAIL their named assertion
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TAP="$HERE/src/com/nowhere/chooser/UpdateNoticeTap.java"
CHOOSER="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
PROFILE="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=no
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --tap) TAP="${2:?--tap needs a file}"; shift ;;
    --chooser) CHOOSER="${2:?--chooser needs a file}"; shift ;;
    --profile) PROFILE="${2:?--profile needs a file}"; shift ;;
    *) echo "usage: $0 [--mutate] [--tap F] [--chooser F] [--profile F]" >&2; exit 2 ;;
  esac
  shift
done
RUN="$HERE/tests/update-notice-tap/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite did NOT run and does not skip: install a JDK or" \
       "run it on the build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 for the pins -- refusing to report" >&2; exit 2; }
[ -f "$RUN" ] && [ -f "$CHOOSER" ] && [ -f "$PROFILE" ] || { echo "FAIL: missing $RUN, $CHOOSER or $PROFILE" >&2; exit 2; }

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export UPDATE_NOTICE_TAP_TMP="$W"

# pins <ChooserActivity.java> <ProfileActivity.java> -> 0 every pin holds, 1 one failed ("--- FAIL P<n>"), 2 a control
# is missing.
pins() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys

def read(p):
    with open(p, encoding='utf-8') as f: return f.read()

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

def open_headers(body, at):
    """The headers of the blocks still open at index at of body (the method's own block first)."""
    m = mask(body); stack = []; start = 0
    for k in range(at):
        ch = m[k]
        if ch == '{':
            stack.append(m[start:k].strip()); start = k + 1
        elif ch == '}':
            if stack: stack.pop()
            start = k + 1
        elif ch == ';':
            start = k + 1
    return stack

fails = []
def pin(name, ok, why):
    if ok: print('  ok    ' + name + ' ' + why)
    else: print('--- FAIL ' + name + ' ' + why); fails.append(name)

cho = strip_comments(read(sys.argv[1]))
pro = strip_comments(read(sys.argv[2]))

SIG_POST = 'private static void postUpdateNotice('
SIG_PROBE = 'private void probeSession() {'
SIG_NEW = 'protected void onNewIntent(Intent intent) {'
SIG_CARD = 'private void addUpdateCard('
# Controls: the members this suite reads that exist before this slice.
for label, code, sig in [('ChooserActivity.postUpdateNotice', cho, SIG_POST),
                         ('ProfileActivity.probeSession', pro, SIG_PROBE),
                         ('ProfileActivity.onNewIntent', pro, SIG_NEW),
                         ('ProfileActivity.addUpdateCard', pro, SIG_CARD)]:
    if method(code, sig) == '':
        print('  CONTROL %s not found exactly once (or its braces do not balance)' % label); sys.exit(2)

# P1: one content intent made on uc, after the Builder chain, before `if (mand) {`, inside no if.
post = method(cho, SIG_POST)
LINE = 'b.setContentIntent(UpdateNoticeTap.pending(uc));'
n = post.count(LINE)
pin('P1', n == 1, 'postUpdateNotice holds %r exactly once (%d)' % (LINE, n))
if n == 1:
    at = post.index(LINE)
    sw = post.find('.setShowWhen(false);'); mand = post.find('if (mand) {', sw if sw >= 0 else 0)
    pin('P1', 0 <= sw < at, 'the content intent comes after .setShowWhen(false);')
    pin('P1', mand >= 0 and at < mand, 'the content intent comes before the Builder\'s `if (mand) {`')
    hdrs = open_headers(post, at)[1:]
    conds = [h for h in hdrs if re.match(r'(\}\s*)?(if|else)\b', h) or re.search(r'\belse\b', h)]
    pin('P1', not conds, 'the content intent is inside no if/else, so every channel carries it (open: %r)' % hdrs)

# P2: nothing else sets a content intent, and the notice is not auto-cancelled.
pin('P2', post.count('setContentIntent(') == 1, 'postUpdateNotice calls setContentIntent( once (%d)' % post.count('setContentIntent('))
pin('P2', post.count('setAutoCancel(') == 0, 'postUpdateNotice calls no setAutoCancel( (%d)' % post.count('setAutoCancel('))

# P3: ProfileActivity's wiring.
SHOW = 'if (shownView == confirmView) showConfirm();'
probe = method(pro, SIG_PROBE)
apply_ = method(probe, 'public void apply(')
pin('P3', apply_ != '', 'probeSession has an apply(')
pin('P3', apply_.count('probed = true;') == 1 and apply_.count(SHOW) == 1
    and apply_.index('probed = true;') < apply_.index(SHOW), 'apply sets probed = true; once, before %r' % SHOW)
pin('P3', probe.count('openUpdateIfAsked();') == 1 and apply_.count('openUpdateIfAsked();') == 1 and apply_.count(SHOW) == 1
    and apply_.index('openUpdateIfAsked();') > apply_.index(SHOW),
    'probeSession calls openUpdateIfAsked(); once, in apply, after %r' % SHOW)
onnew = method(pro, SIG_NEW)
pin('P3', onnew.count('openUpdateIfAsked();') == 1 and onnew.count('openYourAppsIfAsked();') == 1
    and onnew.index('openUpdateIfAsked();') > onnew.index('openYourAppsIfAsked();'),
    'onNewIntent calls openUpdateIfAsked(); once, after openYourAppsIfAsked();')
card = method(pro, SIG_CARD)
pin('P3', card.count('updateCard = card;') == 1, 'addUpdateCard assigns updateCard = card; once')
oua = method(pro, 'private void openUpdateIfAsked() {')
pin('P3', oua != '', 'openUpdateIfAsked() is declared once')
if oua:
    RM = 'removeExtra(LandingLine.EXTRA_OPEN)'
    pin('P3', oua.count('UpdateNoticeTap.act(') == 1, 'openUpdateIfAsked asks UpdateNoticeTap.act( once')
    labels = ['case NONE:', 'case WAIT:', 'case DROP:', 'case SCROLL:']
    if all(oua.count(l) == 1 for l in labels):
        d, s = oua.index('case DROP:'), oua.index('case SCROLL:')
        pin('P3', oua.count(RM) == 2, 'openUpdateIfAsked removes the extra exactly twice (%d)' % oua.count(RM))
        pin('P3', oua[:d].count(RM) == 0, 'no removal before case DROP: (NONE and WAIT keep the extra)')
        pin('P3', d < s and oua[d:s].count(RM) == 1, 'case DROP: removes the extra once')
        pin('P3', oua[s:].count(RM) == 1, 'case SCROLL: removes the extra once')
    else:
        pin('P3', False, 'openUpdateIfAsked switches over NONE, WAIT, DROP and SCROLL, each once')

sys.exit(1 if fails else 0)
PY
}

# suite <tap> <chooser> <profile> -> 0 pass; 1 a case or pin failed ("--- FAIL"); 3 no compile or a tool error.
suite() {
  local crc prc
  bash "$RUN" "$1"; crc=$?
  pins "$2" "$3"; prc=$?
  if [ "$crc" -ne 0 ] && [ "$crc" -ne 1 ]; then return 3; fi
  if [ "$prc" -ne 0 ] && [ "$prc" -ne 1 ]; then return 3; fi
  [ "$crc" -eq 0 ] && [ "$prc" -eq 0 ] && return 0
  return 1
}

echo "== $TAP"
echo "== $CHOOSER"
echo "== $PROFILE"
out=$(suite "$TAP" "$CHOOSER" "$PROFILE" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <convicting id> <tap|chooser|profile> <perl-expr>
  local d m rc o src t c p
  case "$3" in tap) src="$TAP" ;; chooser) src="$CHOOSER" ;; profile) src="$PROFILE" ;;
    *) echo "  ERROR     $1 -- unknown slot $3"; return 1 ;; esac
  d=$(mktemp -d -p "$W"); m="$d/$(basename "$src")"
  if ! perl -0pe "$4" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  t="$TAP"; c="$CHOOSER"; p="$PROFILE"
  case "$3" in tap) t="$m" ;; chooser) c="$m" ;; profile) p="$m" ;; esac
  o=$(suite "$t" "$c" "$p" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL $2 "* ]]; then echo "  convicted $1 (by $2)"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a --- FAIL $2"; echo "$o" | grep -- '--- FAIL' | sed 's/^/            /'; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the PendingIntent made on app, not uc" P1 chooser 's/b\.setContentIntent\(UpdateNoticeTap\.pending\(uc\)\);/b.setContentIntent(UpdateNoticeTap.pending(app));/' || fails=$((fails+1))
mut "M2 the content intent moved inside if (mand)" P1 chooser 's/\n( +)b\.setContentIntent\(UpdateNoticeTap\.pending\(uc\)\);\n( +)if \(mand\) \{\n/\n$2if (mand) {\n$1    b.setContentIntent(UpdateNoticeTap.pending(uc));\n/' || fails=$((fails+1))
mut "M3 the class name shortened to .ProfileActivity" U1 tap 's/"com\.nowhere\.chooser\.ProfileActivity"/".ProfileActivity"/' || fails=$((fails+1))
mut "M4 the extra asks for Your apps" U2 tap 's/putExtra\(LandingLine\.EXTRA_OPEN, OPEN_UPDATE\)/putExtra(LandingLine.EXTRA_OPEN, LandingLine.OPEN_YOUR_APPS)/' || fails=$((fails+1))
mut "M5 FLAG_IMMUTABLE dropped" U4 tap 's/ \| PendingIntent\.FLAG_IMMUTABLE//' || fails=$((fails+1))
mut "M6 FLAG_ACTIVITY_SINGLE_TOP dropped" U3 tap 's/ \| Intent\.FLAG_ACTIVITY_SINGLE_TOP//' || fails=$((fails+1))
mut "M7 getActivity on uc.getApplicationContext()" U4 tap 's/PendingIntent\.getActivity\(uc,/PendingIntent.getActivity(uc.getApplicationContext(),/' || fails=$((fails+1))
mut "M8 act scrolls before the probe answers" U5 tap 's/if \(!probed\) return Act\.WAIT;/if (!probed) return Act.SCROLL;/' || fails=$((fails+1))
mut "M9 apply's openUpdateIfAsked() removed" P3 profile 's/(if \(shownView == confirmView\) showConfirm\(\);\n)[ \t]*openUpdateIfAsked\(\);\n/$1/' || fails=$((fails+1))
mut "M10 onNewIntent's openUpdateIfAsked() removed" P3 profile 's/(openYourAppsIfAsked\(\);\n)[ \t]*openUpdateIfAsked\(\);\n/$1/' || fails=$((fails+1))
mut "M11 setAutoCancel(true) added" P2 chooser 's/(\n( +)b\.setContentIntent\(UpdateNoticeTap\.pending\(uc\)\);)/$1\n$2b.setAutoCancel(true);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
