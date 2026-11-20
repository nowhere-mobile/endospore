#!/usr/bin/env bash
# test-landing-tap-row-java.sh [--mutate] -- NWP-20261210-25: while a tap holds the materialise lock, the landing card
# names the app the notification names.
#
# WHY. The backlog row "For the first seconds after a tap, the landing card names the sweep's first app while the
# notification downloads the tapped app". NWP-20261201-34 has sweepAuto mark its app installing BEFORE it takes
# MAT_LOCK, because the sweep chose the app and waits only for a tap. That is kept. But while a tap holds the lock the
# notification (renderQueue) names the tapped app, so the card and the notification named two apps. The state words
# are DECIDED (docs/product-decisions.md 2026-11-09 "eight answers to harvest 62 ..." #3); this adds no words.
#
# WHAT RUNS. LandingLine and AppDeps (pure Java) are compiled with tests/landing-tap-row/LandingTapRowCases.java and RUN:
# LandingLine.Sweep.startedBehind (T1-T6): the row's case (the tapped app's row installs, the sweep's app reads coming
# back); a named app with no row; named null or equal to pkg is exactly started; the hand-back once the sweep holds the
# lock; a named row that already landed or settled; another sweep's id, the end and a null pkg.
# WHAT IS PINNED BY ANCHOR (UnarchiveService cannot be compiled off the build host), on the comment-stripped source:
# (P1) cardStarted reads MAT_LOCK.owner(), passes qNamed() only when another thread owns the lock, and records through
# LandingLine.Sweep.startedBehind(card, pkg, named); (P2) qNamed returns FQ.snapshot().named, the field renderQueue
# names as cur (FetchQueue, NWP-20261210-20, replaced the Q_* fields); (P3) sweepAuto's work loop calls cardStarted(card, pkg)
# twice: right after `String pkg = work.get(i);` (before step(SweepStall.LOCK ...) and the lock), and between
# `MAT_LOCK.lock();` and the materializeAndInstall(pkg, true) try.
#
# What this does NOT prove: on a device, a tap before the sweep shows the card and the notification naming the same
# app from the card's first frame. That is the merger's device follow-up.
#
#   bash test-landing-tap-row-java.sh              # the cases and the pins
#   bash test-landing-tap-row-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
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
  echo "test-landing-tap-row-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

LL="$SRC/LandingLine.java"; US="$SRC/UnarchiveService.java"; AD="$SRC/AppDeps.java"
CASES="$HERE/tests/landing-tap-row/LandingTapRowCases.java"
for f in "$LL" "$US" "$AD" "$CASES"; do
  if [ ! -f "$f" ]; then echo "test-landing-tap-row-java: FAIL -- $f is missing"; exit 2; fi
done

cases() { # cases <LandingLine.java> [quiet]: 0 pass, 1 a case failed, 2 did not compile
  local ll=$1 quiet=${2:-} cls out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$ll" "$AD" "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.LandingTapRowCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <UnarchiveService.java>: 0 hold, 1 failed, 2 extract
  python3 - "$1" <<'PY'
import io, re, sys
src_raw = io.open(sys.argv[1], encoding='utf-8').read()

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

src = strip(src_raw)

def block(s, at):
    """The text from the first '{' at or after index `at` to its matching '}'."""
    j = s.find('{', at)
    if j < 0:
        print("EXTRACTION FAILED: no '{' after index %d" % at); sys.exit(2)
    d = 0
    for k in range(j, len(s)):
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: return s[j:k + 1]
    print("EXTRACTION FAILED: unbalanced braces after index %d" % at); sys.exit(2)

def method(sig, what):
    n = src.count(sig)
    if n != 1:
        print("EXTRACTION FAILED: %r occurs %d times in %s" % (sig, n, what)); sys.exit(2)
    return block(src, src.index(sig))

bad = []

# P1 cardStarted: the owner test, then the named app only when another thread owns the lock, then startedBehind
cs = method('private void cardStarted(long card, String pkg) {', 'UnarchiveService.java')
if not re.search(r'\{\s*Thread o = MAT_LOCK\.owner\(\);\s*'
                 r'String named = \(o != null && o != Thread\.currentThread\(\)\) \? qNamed\(\) : null;\s*'
                 r'if \(!LandingLine\.Sweep\.startedBehind\(card, pkg, named\)\) return;', cs) \
        or 'LandingLine.Sweep.started(' in cs:
    bad.append('(P1) cardStarted does not read MAT_LOCK.owner(), pass qNamed() only when another thread owns it, '
               'and record through LandingLine.Sweep.startedBehind(card, pkg, named)')
else:
    print('ok P1 cardStarted names the notification\'s app only when another thread holds MAT_LOCK')

# P2 qNamed: the snapshot's named member, the same field renderQueue names as cur
qn = method('private String qNamed() {', 'UnarchiveService.java')
if not re.fullmatch(r'\{\s*return FQ\.snapshot\(\)\.named;\s*\}', qn):
    bad.append('(P2) qNamed does not return FQ.snapshot().named')
else:
    rq = method('private void renderQueue() {', 'UnarchiveService.java')
    if not re.search(r'final FetchQueue\.Snapshot q = FQ\.snapshot\(\);\s*final String cur = q\.named;', rq):
        bad.append('(P2) renderQueue no longer names FQ.snapshot().named as cur: qNamed must agree')
    else:
        print('ok P2 qNamed returns FQ.snapshot().named, the member renderQueue names')

# P3 the work loop marks the app twice: right after it picks it, and once it holds the lock
sw = method('private void sweepAuto(boolean byHand) {', 'UnarchiveService.java')
lh = 'for (int i = 0; i < work.size(); i++) {'
if sw.count(lh) != 1:
    print("EXTRACTION FAILED: %r occurs %d times in sweepAuto" % (lh, sw.count(lh))); sys.exit(2)
loop = block(sw, sw.index(lh))
lc = 'cardStarted(card, pkg);'
first = re.search(r'String pkg = work\.get\(i\);\s*cardStarted\(card, pkg\);', loop)
second = re.search(r'MAT_LOCK\.lock\(\);\s*cardStarted\(card, pkg\);\s*'
                   r'try \{ ok = materializeAndInstall\(pkg, true\); end = matEnd; \}', loop)
if loop.count(lc) != 2 or not first or not second:
    bad.append('(P3) the work loop does not call cardStarted(card, pkg) twice: right after String pkg = work.get(i); '
               'and between MAT_LOCK.lock(); and materializeAndInstall(pkg, true)')
elif not (first.end() < loop.find('step(SweepStall.LOCK') < second.start()):
    bad.append('(P3) the first cardStarted call is not before step(SweepStall.LOCK ...) and the lock')
else:
    print('ok P3 the work loop marks its app before the lock and again once it holds the lock')

for b in bad: print('PIN FAILED: ' + b)
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <LandingLine.java> <UnarchiveService.java> [quiet]: 0 pass, 1 failed, 2 compile/extract
  local ll=$1 us=$2 quiet=${3:-} rc=0 prc=0 pout
  cases "$ll" "$quiet" || rc=$?
  [ "$rc" -eq 2 ] && return 2
  pout=$(pins "$us" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$LL" "$US"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-landing-tap-row-java: FAIL (rc $rc)"; exit 1; fi
echo "test-landing-tap-row-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: ll|us> <python-regex> <replacement> <convicting assertion, e.g. T1 or P3; - for a control> [survive: the control must pass]
  local name=$1 which=$2 pat=$3 rep=$4 want=$5 survive=${6:-} d src orig mll mus rc=0 out nl=$'\n'
  d=$(mktemp -d -p "$W") || return 1
  mll="$d/LandingLine.java"; mus="$d/UnarchiveService.java"
  cp "$LL" "$mll"; cp "$US" "$mus"
  case "$which" in
    ll) src=$mll; orig=$LL ;;
    us) src=$mus; orig=$US ;;
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
  out=$(suite "$mll" "$mus" 2>&1); rc=$?
  if [ -n "$survive" ]; then
    if [ "$rc" -eq 0 ]; then echo "  $name: survived (control)"
    else echo "  $name: ⚠ CONTROL FAILED (rc $rc)"; fails=$((fails + 1)); fi
  elif [ "$rc" -eq 1 ] && { [[ $nl$out == *"${nl}FAIL $want "* ]] || [[ $nl$out == *"${nl}PIN FAILED: ($want)"* ]]; }; then
    echo "  $name: convicted by $want"
  elif [ "$rc" -eq 1 ]; then echo "  $name: ⚠ FAILED, BUT NOT ON $want"; fails=$((fails + 1))
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

SB='(static synchronized boolean startedBehind\(long sweep, String pkg, String named\) \{.*?)'
echo "mutants:"
mutant "N1 startedBehind ignores named" ll "$SB"'!named\.equals\(pkgs\[i\]\)' '\1!pkg.equals(pkgs[i])' T1
mutant "N2 a settled row of named is still marked" ll "$SB"'settled\[i\] \|\| landed\[i\] \|\| ' '\1landed[i] || ' T5
mutant "N3 the owner test inverted" us 'o != Thread\.currentThread\(\)' 'o == Thread.currentThread()' P1
mutant "N4 the second call removed" us '(MAT_LOCK\.lock\(\);)\n[^\n]*cardStarted\(card, pkg\);[^\n]*' '\1' P3
mutant "N5 qNamed names only the running member" us '(private String qNamed\(\) \{\s*return FQ\.snapshot\(\))\.named;' '\1.current;' P2
mutant "N6 startedBehind keeps the old row when named has none" ll "$SB"'\n[^\n]*installing = -1;' '\1' T2
mutant "C1 a comment edited (control)" us '// NWP-20261210-25: the lock is the sweep.s now: its own app' '// NWP-20261210-25: a comment edited' - survive
if [ "$fails" -ne 0 ]; then echo "test-landing-tap-row-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-landing-tap-row-java: all mutants convicted, the control survived"
