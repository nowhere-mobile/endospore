#!/usr/bin/env bash
# test-auto-pending-copy-java.sh [--mutate] -- NWP-20261119-14: Your apps' "Install pending apps now" row says the Auto
# apps wait for Wi-Fi, and links to the "Download over mobile data" switch, when the sweep waits for Wi-Fi.
#
# WHY. The sweep's network rule (NWP-20261112-11) holds every Auto app off mobile data while the switch is off, but the
# row always said "They install in the background". On a mobile-only session nothing explained the wait or reached
# the switch. The words are DECIDED 2026-10-31 (h49 #1, docs/product-decisions.md "thirteen answers to harvest 49").
#
# WHAT RUNS. AutoPendingCopy (pure Java) is compiled with PendingRow and AutoPendingCopyCases ALONE and RUN: the grey
# line for n=1 and n=3 and the link, in each of the four (switch, Wi-Fi) states; and rowAction, which rebuilds a row
# whose count did not change when Wi-Fi came or went since it was drawn (both ways), and leaves it alone otherwise. The waiting words are read from h49 #1 in
# docs/product-decisions.md by this suite AND held here as literals, so a drift in the doc or in the class fails.
# WHAT IS PINNED BY ANCHOR (ProfileActivity cannot be compiled off the build host): (P1) installPendingRow writes
# AutoPendingCopy.subline(n, allowMetered, onWifi); (P2) it holds no "install in the background" or "waiting to
# install" literal of its own; (P3) it shows AutoPendingCopy.link(allowMetered, onWifi) with a click listener that
# opens showOfflineMedia(); (P4) applyPendingRow reads readPrefetchMetered() and ChooserActivity.onWifiCtx(this) before
# its NONE return, gives them and the row's tag to AutoPendingCopy.rowAction there, and passes them to the one
# installPendingRow(n, allowMetered, onWifi) call; (P5) installPendingRow tags its row with waitingForWifi.
# The merger's full javac / `m NowhereChooser` covers ProfileActivity itself.
#
# What this does NOT prove: the handset look (switch off, mobile data only: Your apps shows the waiting line and its
# link opens Offline media) stays on the backlog row.
#
#   bash test-auto-pending-copy-java.sh              # the cases and the pins
#   bash test-auto-pending-copy-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
DOC="$HERE/../../docs/product-decisions.md"
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
  echo "test-auto-pending-copy-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

AC="$SRC/AutoPendingCopy.java"; PA="$SRC/ProfileActivity.java"; PR="$SRC/PendingRow.java"
if [ ! -f "$PR" ]; then echo "test-auto-pending-copy-java: FAIL -- $PR is missing"; exit 2; fi
if [ ! -f "$AC" ]; then echo "test-auto-pending-copy-java: FAIL -- $AC is missing"; exit 2; fi
if [ ! -f "$DOC" ]; then echo "test-auto-pending-copy-java: FAIL -- $DOC is missing"; exit 2; fi

# The expected words, one per line (UTF-8, the › included): waiting n=1, waiting n=3, link, old n=1, old n=3.
# Read from h49 #1 and checked against the literals below; a file, not argv, so the locale cannot mangle the ›.
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
m = re.search(r'^1\. (.*)$', sec, re.M)
if not m:
    print("EXTRACTION FAILED: no item 1. in the h49 entry"); sys.exit(2)
item = m.group(1)
sing = re.search(r'\*"(<n> Auto app is waiting[^"]*)"\*', item)
plur = re.search(r'\*"(<n> Auto apps are waiting) …"\*', item)
link = re.search(r'\*"(Download over mobile data is off\.[^"]*)"\*', item)
if not (sing and plur and link):
    print("EXTRACTION FAILED: could not extract the waiting line, its plural or the link from h49 #1"); sys.exit(2)
sing, plur, link = sing.group(1), plur.group(1), link.group(1)
w1 = sing.replace('<n>', '1')
w3 = plur.replace('<n>', '3') + sing[len('<n> Auto app is waiting'):]
lit = {
    'waiting n=1': (w1, '1 Auto app is waiting for Wi-Fi. Tap Install to use mobile data now.'),
    'waiting n=3': (w3, '3 Auto apps are waiting for Wi-Fi. Tap Install to use mobile data now.'),
    'link': (link, 'Download over mobile data is off. Change it in Offline media ›'),
}
bad = [k for k, (d, l) in lit.items() if d != l]
for k in bad: print("DOC DRIFT: h49 #1's %s is %r, this suite holds %r" % (k, lit[k][0], lit[k][1]))
if bad: sys.exit(1)
old1 = '1 Auto app is waiting to install. They install in the background.'
old3 = '3 Auto apps are waiting to install. They install in the background.'
io.open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join([w1, w3, link, old1, old3]) + '\n')
PY
rc=$?
if [ "$rc" -ne 0 ]; then echo "test-auto-pending-copy-java: FAIL -- the h49 #1 words (rc $rc)"; exit "$rc"; fi
echo "ok the h49 #1 words match the literals"

CASES="$W/AutoPendingCopyCases.java"
cat > "$CASES" <<'JAVA'
package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

public class AutoPendingCopyCases {
    static int fails = 0;

    static void eqi(String what, int got, int want) {
        if (got == want) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + got + ", want " + want);
    }

    /** One recount, as applyPendingRow takes it: the row on screen (tag, count) and the fresh count n. */
    static int recount(Object tag, int shown, int n, boolean allowMetered, boolean onWifi) {
        return AutoPendingCopy.rowAction(PendingRow.action(shown, n), tag, allowMetered, onWifi);
    }

    static void eq(String what, String got, String want) {
        boolean ok = want == null ? got == null : want.equals(got);
        if (ok) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + (got == null ? "null" : "\"" + got + "\""));
    }

    public static void main(String[] a) throws Exception {
        List<String> e = Files.readAllLines(Paths.get(a[0]), StandardCharsets.UTF_8);
        String w1 = e.get(0), w3 = e.get(1), link = e.get(2), old1 = e.get(3), old3 = e.get(4);
        boolean[] tf = { false, true };
        for (boolean allowMetered : tf) {
            for (boolean onWifi : tf) {
                boolean waiting = !allowMetered && !onWifi;
                String st = "(switch " + (allowMetered ? "on" : "off") + ", " + (onWifi ? "Wi-Fi" : "no Wi-Fi") + ")";
                eq("subline n=1 " + st, AutoPendingCopy.subline(1, allowMetered, onWifi), waiting ? w1 : old1);
                eq("subline n=3 " + st, AutoPendingCopy.subline(3, allowMetered, onWifi), waiting ? w3 : old3);
                eq("link " + st, AutoPendingCopy.link(allowMetered, onWifi), waiting ? link : null);
            }
        }
        // RF-001: the count stays 3 and the switch is off. The row's tag is what installPendingRow set when it drew it.
        Object drawnOnWifi = AutoPendingCopy.waitingForWifi(false, true);   // Boolean.FALSE: the old words
        Object drawnOffWifi = AutoPendingCopy.waitingForWifi(false, false); // Boolean.TRUE: the waiting words
        eqi("same count, Wi-Fi lost: rebuilt", recount(drawnOnWifi, 3, 3, false, false), PendingRow.REPLACE);
        eqi("same count, Wi-Fi back: rebuilt", recount(drawnOffWifi, 3, 3, false, true), PendingRow.REPLACE);
        eqi("same count, still on Wi-Fi: left alone", recount(drawnOnWifi, 3, 3, false, true), PendingRow.NONE);
        eqi("same count, still off Wi-Fi: left alone", recount(drawnOffWifi, 3, 3, false, false), PendingRow.NONE);
        eqi("same count, switch on, Wi-Fi lost: left alone", recount(drawnOnWifi, 3, 3, true, false), PendingRow.NONE);
        eqi("same count, switch turned on: rebuilt", recount(drawnOffWifi, 3, 3, true, false), PendingRow.REPLACE);
        eqi("no row, no count: nothing", recount(null, 0, 0, false, false), PendingRow.NONE);
        eqi("no row, a count: added", recount(null, 0, 2, false, false), PendingRow.ADD);
        eqi("count changed: replaced", recount(drawnOffWifi, 3, 2, false, false), PendingRow.REPLACE);
        eqi("count gone: removed", recount(drawnOffWifi, 3, 0, false, true), PendingRow.REMOVE);
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA

cases() { # cases <AutoPendingCopy.java> [quiet]: 0 pass, 1 a case failed, 2 did not compile
  local ac=$1 quiet=${2:-} cls out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$ac" "$PR" "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.AutoPendingCopyCases "$EXP" 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <ProfileActivity.java>: rc 0 all hold, 1 a pin failed, 2 could not extract
  python3 - "$1" <<'PY'
import io, re, sys
raw = io.open(sys.argv[1], encoding='utf-8').read()

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

def body(sig):
    n = src.count(sig)
    if n != 1:
        print("EXTRACTION FAILED: %r occurs %d times" % (sig, n)); sys.exit(2)
    j = src.index(sig) + len(sig) - 1
    d = 0
    for k in range(j, len(src)):
        if src[k] == '{': d += 1
        elif src[k] == '}':
            d -= 1
            if d == 0: return src[j:k + 1]
    print("EXTRACTION FAILED: unbalanced braces after %r" % sig); sys.exit(2)

row = body('private LinearLayout installPendingRow(int n, boolean allowMetered, boolean onWifi) {')
app = body('private void applyPendingRow(LinearLayout ll, View summary, View[] rowRef, int[] shown, int n, boolean sweepEnded) {')   # NWP-20261119-30: the body; the five-argument one delegates with false
bad = []

# P1 the grey line is AutoPendingCopy's
if 'AutoPendingCopy.subline(n, allowMetered, onWifi)' not in row:
    bad.append('(P1) installPendingRow does not write AutoPendingCopy.subline(n, allowMetered, onWifi)')
# P2 no words of its own
if re.search(r'install in the background', row, re.I) or re.search(r'waiting to install', row, re.I):
    bad.append('(P2) installPendingRow holds a waiting-line literal of its own')
# P3 the link, and its tap opens Offline media
li = row.find('AutoPendingCopy.link(allowMetered, onWifi)')
if li < 0:
    bad.append('(P3) installPendingRow does not show AutoPendingCopy.link(allowMetered, onWifi)')
elif not re.search(r'\.setOnClickListener\(\s*\w+\s*->\s*showOfflineMedia\(\)\s*\)', row[li:]):
    bad.append('(P3) the link has no click listener that opens showOfflineMedia()')
# P4 applyPendingRow reads the switch and the Wi-Fi test before its NONE return, lets rowAction rebuild a row whose
# words are stale (RF-001: same count, Wi-Fi came or went), and passes the same two values to installPendingRow
ca = app.find('int act = PendingRow.action(shown[0], n')   # NWP-20261119-30 adds a sweepEnded argument
am = app.find('boolean allowMetered = readPrefetchMetered();')
ow = app.find('boolean onWifi = ChooserActivity.onWifiCtx(this);')
ra = app.find('act = AutoPendingCopy.rowAction(act, rowRef[0] == null ? null : rowRef[0].getTag(), allowMetered, onWifi);')
no = app.find('if (act == PendingRow.NONE) return;')
call = app.find('installPendingRow(n, allowMetered, onWifi)')
if min(ca, am, ow, ra, no, call) < 0 or not (ca < ra and am < ra and ow < ra and ra < no < call):
    bad.append('(P4) applyPendingRow does not read readPrefetchMetered() and ChooserActivity.onWifiCtx(this), ask '
               'AutoPendingCopy.rowAction with the row\'s tag before its NONE return, and pass them to '
               'installPendingRow(n, allowMetered, onWifi)')
if len(re.findall(r'\ballowMetered\s*=', app)) != 1 or len(re.findall(r'\bonWifi\s*=', app)) != 1:
    bad.append('(P4) applyPendingRow sets allowMetered or onWifi more than once')
# P5 the row records which words it says, for rowAction
if 'row.setTag(AutoPendingCopy.waitingForWifi(allowMetered, onWifi));' not in row:
    bad.append('(P5) installPendingRow does not tag its row with AutoPendingCopy.waitingForWifi(allowMetered, onWifi)')
if len(re.findall(r'(?<![\w.])installPendingRow\(', src)) != 2:
    bad.append('(P4) installPendingRow is not declared once and called once')
for b in bad: print('PIN FAILED: ' + b)
if not bad: print('ok P1-P5 installPendingRow and applyPendingRow wiring')
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <AutoPendingCopy.java> <ProfileActivity.java> [quiet]: 0 pass, 1 failed, 2 could not run
  local ac=$1 pa=$2 quiet=${3:-} rc=0 prc=0 pout
  cases "$ac" "$quiet" || rc=$?
  [ "$rc" -eq 2 ] && return 2
  pout=$(pins "$pa" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$AC" "$PA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-auto-pending-copy-java: FAIL (rc $rc)"; exit 1; fi
echo "test-auto-pending-copy-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: ac|pa> <python-regex> <replacement>
  local name=$1 which=$2 pat=$3 rep=$4 d src orig mac mpa rc=0
  d=$(mktemp -d -p "$W") || return 1
  mac="$d/AutoPendingCopy.java"; mpa="$d/ProfileActivity.java"
  cp "$AC" "$mac"; cp "$PA" "$mpa"
  case "$which" in
    ac) src=$mac; orig=$AC ;;
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
  suite "$mac" "$mpa" quiet; rc=$?
  if [ "$rc" -eq 1 ]; then echo "  $name: convicted"
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

echo "mutants:"
mutant "K1 singular and plural swapped" ac 'n == 1 \? " Auto app is"' 'n != 1 ? " Auto app is"'
mutant "K2 onWifi inverted" ac 'return !allowMetered && !onWifi;' 'return !allowMetered && onWifi;'
mutant "K3 the link shown with the switch on" ac 'return waitingForWifi\(allowMetered, onWifi\) \? LINK : null;' 'return !onWifi ? LINK : null;'
mutant "K4 the old text kept in the waiting state" ac 'return who \+ " waiting for Wi-Fi\. Tap Install to use mobile data now\.";' 'return who + " waiting to install. They install in the background.";'
mutant "S1 installPendingRow writes the old literal" pa 'sub\.setText\(AutoPendingCopy\.subline\(n, allowMetered, onWifi\)\);' 'sub.setText(n + (n == 1 ? " Auto app is" : " Auto apps are") + " waiting to install. They install in the background.");'
mutant "S2 applyPendingRow ignores the switch" pa 'boolean allowMetered = readPrefetchMetered\(\);' 'boolean allowMetered = true;'
mutant "S3 applyPendingRow ignores Wi-Fi" pa 'boolean onWifi = ChooserActivity\.onWifiCtx\(this\);' 'boolean onWifi = false;'
mutant "S4 the link opens nothing" pa '\n[^\n]*to\.setOnClickListener\(v -> showOfflineMedia\(\)\);[^\n]*' ''
mutant "K5 a stale row is never rebuilt" ac '\? PendingRow\.NONE : PendingRow\.REPLACE;' '? PendingRow.NONE : PendingRow.NONE;'
mutant "K6 the row's tag ignored" ac 'return \(Boolean\) shownTag == waitingForWifi\(allowMetered, onWifi\)' 'return true'
mutant "S5 applyPendingRow skips rowAction" pa '\n[^\n]*act = AutoPendingCopy\.rowAction\([^\n]*' ''
mutant "S6 the network read after the NONE return" pa '(int act = PendingRow\.action\(shown\[0\], n(?:, sweepEnded)?\);)(.*?)(\n[^\n]*if \(act == PendingRow\.NONE\) return;)' '\1\3\2'
mutant "S7 installPendingRow tags nothing" pa '\n[^\n]*row\.setTag\(AutoPendingCopy\.waitingForWifi\(allowMetered, onWifi\)\);[^\n]*' ''
if [ "$fails" -ne 0 ]; then echo "test-auto-pending-copy-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-auto-pending-copy-java: all mutants convicted"
