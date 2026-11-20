#!/usr/bin/env bash
# test-fetch-queue-java.sh [--mutate] -- NWP-20261210-20: the download notification's "(n of m)" counts each app once
# per batch, from the landing card's rows, and keeps its total across a Pause and Resume of one sweep.
#
# WHY. Backlog row 'The download notification's "(n of m)" can count one app twice, and starts without the Play-stack
# deps the landing card already counts' (section B). UnarchiveService's set counted any removed member as done and let a
# done member join again, the sweep queued its work list without the deps the card counts, and a Pause drained the set,
# so the Resume counted "2 of 7" against the card's "1 of 8" (lynx, 2026-11-17/18 proof round, S18).
#
# WHAT RUNS. FetchQueue (pure Java) is compiled with LandingLine, AppDeps and tests/fetch-queue/FetchQueueCases.java and
# RUN: F1 three members and the next batch; F2 the double count; F3 the declined ask during a sweep; F4 the deps from
# the first frame (LandingLine.cardPkgs through the real AppDeps rule); F5/F5b/F5c a Pause and Resume of the same card,
# another card or none, and a key-0 batch in between; F6 holders; F7 a failed group; F8 start of a finished member,
# the named member and the rest's order; F9/F9b/F9c the sweep's own claim, replayed as sweepAuto keeps it, with a tap
# holder beside it: a Pause then the end release, a busy lane on the last app and its retry, a throw then a sign-out;
# F10/F10b the remembered tap's claim beside a live tap's: two busy attempts, a sign-out after a retry, a throw.
# WHAT IS PINNED BY ANCHOR (UnarchiveService cannot be compiled off the build host), on the comment-stripped source:
# (Q1) no Q_PENDING, Q_DONE, Q_CURRENT or Q_LOCK; renderQueue reads one FQ.snapshot() and its verb tests the snapshot's
# current; the FGS notice reads FQ.current(); the report snapshot reads FQ.pendingSize(); (Q2) sweepAuto builds `queued`
# from LandingLine.cardPkgs with the card's inputs, then qBatch(card); qEnqueue(queued);, and holds no qEnqueue(work);
# (Q3) the finally that sends "AUTO-SWEEP\n0\n" calls qDrop(queued); just before it; (Q4) both pendingDeps branches that
# find code call cardDepLanded(dep); then qFinish(dep);; (Q5) materializeAndInstall sets matRan = true; after the lock,
# the declined ask sets matRan = false; before its matEnd = ERROR and return false;, and the entry point is released on !matRan or BUSY,
# else finished; (Q6) stopSelfSafely calls FQ.clear();; (Q7) `queued` is the sweep's own claim: a mutable list, the
# catch releases the app, the RETRY arm claims it again (qBatch(card); then qEnqueue of the app), the app leaves `queued`
# after the RETRY arm, and `queued.removeAll(work);` ends the try, so the end release never takes a tap's holder (RF-001);
# (Q8) the remembered-tap loop tracks its own claim in tapHeld: set after each claim, cleared before each call, the
# catch releases the app, a busy retry claims it again, and the cleanup releases only a held claim (RF-002).
# The merger's full javac / `m NowhereChooser` covers the service.
#
# What this does NOT prove: on lynx, the notification's m equals the landing card's n from the first frame, stays when
# Play Store is tapped and the Play-stack ask declined, and still equals the card's total after a Pause and Resume.
# That is the merger's device follow-up.
#
#   bash test-fetch-queue-java.sh              # the cases and the pins
#   bash test-fetch-queue-java.sh --mutate     # ... plus mutants that must each be convicted by the assertion they name
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
  echo "test-fetch-queue-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

FQ="$SRC/FetchQueue.java"; US="$SRC/UnarchiveService.java"; LL="$SRC/LandingLine.java"; AD="$SRC/AppDeps.java"
CASES="$HERE/tests/fetch-queue/FetchQueueCases.java"
for f in "$CASES" "$US" "$LL" "$AD"; do
  if [ ! -f "$f" ]; then echo "test-fetch-queue-java: FAIL -- $f is missing"; exit 2; fi
done

cases() { # cases <FetchQueue.java>: prints the cases' lines; 0 pass, 1 a case failed, 2 did not compile
  local fq=$1 cls out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  if [ ! -f "$fq" ]; then
    echo "COMPILE FAILED: $fq is missing"
    rm -rf "$cls"; return 2
  fi
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$fq" "$LL" "$AD" "$CASES" 2>&1); then
    printf 'COMPILE FAILED:\n%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.FetchQueueCases 2>&1) || rc=$?
  printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <UnarchiveService.java>: prints the pins' lines; 0 hold, 1 failed, 2 extract
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

def block(s, at):
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

def body(sig):
    n = src.count(sig)
    if n != 1:
        print("EXTRACTION FAILED: %r occurs %d times" % (sig, n)); sys.exit(2)
    a, b = block(src, src.index(sig))
    return src[a:b]

bad = []

# Q1 the old fields are gone; one snapshot; the verb tests current; the FGS notice and the report read FQ
for t in ('Q_PENDING', 'Q_DONE', 'Q_CURRENT', 'Q_LOCK'):
    if t in src:
        bad.append('(Q1) %s is still in UnarchiveService.java' % t)
if src.count('static final FetchQueue FQ = new FetchQueue();') != 1:
    bad.append('(Q1) the service does not hold one static final FetchQueue FQ')
rq = body('private void renderQueue() {')
m = re.search(r'final FetchQueue\.Snapshot (\w+) = FQ\.snapshot\(\);', rq)
if rq.count('FQ.') != 1 or not m:
    bad.append('(Q1) renderQueue does not read FQ exactly once, through one FQ.snapshot()')
else:
    v = m.group(1)
    if not re.search(r'\(%s\.current == null \? "Waiting for " : "Downloading "\)' % v, rq):
        bad.append('(Q1) renderQueue\'s verb does not test the snapshot\'s current ("Waiting for ")')
    if not re.search(r'final String cur = %s\.named;' % v, rq):
        bad.append('(Q1) renderQueue does not name the snapshot\'s named member')
if src.count('bPkg = FQ.current();') != 1:
    bad.append('(Q1) the FGS notice does not read bPkg = FQ.current();')
if body('static SweepSnapshot.Input snapshot() {').count('queue = FQ.pendingSize();') != 1:
    bad.append('(Q1) the report snapshot does not read queue = FQ.pendingSize();')

# Q2 the sweep queues the card's rows, keyed by the card
sw = body('private void sweepAuto(boolean byHand) {')
qd = ('java.util.List<String> queued = new ArrayList<>(java.util.Arrays.asList(LandingLine.cardPkgs(work, '
      'p -> ProfileActivity.appDeps(this, p), p -> hasInstalledCode(p))));')
if 'qEnqueue(work);' in sw:
    bad.append('(Q2) sweepAuto still calls qEnqueue(work);')
if sw.count(qd) != 1 or not re.search(re.escape(qd) + r'\s*qBatch\(card\);\s*qEnqueue\(queued\);', sw) \
        or sw.count('qBatch(') != 2 or sw.count('qEnqueue(queued);') != 1:
    bad.append('(Q2) sweepAuto does not build queued from LandingLine.cardPkgs, then qBatch(card); qEnqueue(queued);')
elif not (sw.index(qd) < sw.find('"AUTO-SWEEP\\n1\\n"') < sw.find('for (int i = 0; i < work.size(); i++) {')):
    bad.append('(Q2) the queue is not filled before AUTO-SWEEP 1 and the work loop')
if src.count('private void qBatch(long card) {') != 1 or 'FQ.batch(card);' not in body('private void qBatch(long card) {'):
    bad.append('(Q2) qBatch(long) does not call FQ.batch')

# Q3 the end release, just before AUTO-SWEEP 0
if sw.count('"AUTO-SWEEP\\n0\\n"') != 1 or not re.search(
        r'\}\s*finally\s*\{\s*qDrop\(queued\);\s*DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n", 30000\);\s*\}', sw):
    bad.append('(Q3) the finally does not call qDrop(queued); just before AUTO-SWEEP 0')

# Q4 the deps found with code are counted done, as the card ticks them
pd = body('private java.util.List<String> pendingDeps(String pkg, java.util.List<String> restoreOnly) {')
for arm in ('AUTO_WHOLE', 'AUTO_RESTORE_ONLY'):
    i = pd.find('if (action == %s) {' % arm)
    if i < 0:
        bad.append('(Q4) pendingDeps has no %s branch' % arm); continue
    a, b = block(pd, i)
    if not re.match(r'\{\s*cardDepLanded\(dep\);\s*qFinish\(dep\);', pd[a:b]):
        bad.append('(Q4) pendingDeps\' %s branch does not call cardDepLanded(dep); then qFinish(dep);' % arm)

# Q5 the exits that ran nothing take back only the caller's claim
if src.count('private static boolean matRan;') != 1:
    bad.append('(Q5) no private static boolean matRan;')
ma = body('private boolean materializeAndInstall(String pkg, boolean quiet) {')
if not re.search(r'MAT_LOCK\.lock\(\);\s*try \{\s*matEnd = SweepOutcome\.ERROR;\s*matRan = true;', ma):
    bad.append('(Q5) materializeAndInstall does not set matRan = true; after the lock')
if not re.search(r'boolean ok = materializeLocked\(pkg, quiet\);\s*if \(ok\) noteSeen\(pkg\);\s*'
                 r'if \(!matRan \|\| SweepOutcome\.BUSY\.equals\(matEnd\)\) qDrop\(java\.util\.Collections\.singletonList\(pkg\)\);'
                 r'\s*else qFinish\(pkg\);\s*return ok;', ma):
    bad.append('(Q5) materializeAndInstall does not release the entry point on !matRan or BUSY, else finish it')
ml = body('private boolean materializeLocked(String pkg, boolean quiet) {')
i = ml.find('if (a != PlayFetchAsk.Reply.YES) {')
if i < 0:
    bad.append('(Q5) materializeLocked has no declined-ask branch')
else:
    a, b = block(ml, i)
    if not re.search(r'matRan = false;\s*matEnd = SweepOutcome\.ERROR;\s*return false;\s*\}\Z', ml[a:b]) \
            or src.count('matRan = false;') != 1:
        bad.append('(Q5) the declined-ask branch does not set matRan = false; before its matEnd and return false;')

# Q6 the service's stop clears the queue
if body('private void stopSelfSafely() {').count('FQ.clear();') != 1:
    bad.append('(Q6) stopSelfSafely does not call FQ.clear();')

# Q7 the sweep's claim is its own: each app leaves `queued` once its holder is taken back, so the end release takes
# back only what the sweep still holds (RF-001)
one = 'java.util.Collections.singletonList(pkg)'
if not re.search(r'catch \(Throwable t\) \{ end = SweepOutcome\.ERROR; qDrop\(%s\);' % re.escape(one), sw):
    bad.append('(Q7) the sweep loop\'s catch does not release the app\'s claim (qDrop of the app)')
i = sw.find('if (step == SweepBusy.Step.RETRY) {')
if i < 0:
    bad.append('(Q7) sweepAuto has no RETRY arm')
else:
    a, b = block(sw, i)
    if not re.search(r'qBatch\(card\);\s*qEnqueue\(%s\);\s*i--;\s*continue;\s*\}\Z' % re.escape(one), sw[a:b]):
        bad.append('(Q7) the RETRY arm does not claim the app again (qBatch(card); qEnqueue of the app) before i--; continue;')
    if not re.match(r'\s*queued\.remove\(pkg\);\s*if \(ok\) done\+\+;', sw[b:]) or sw.count('queued.remove(pkg);') != 1:
        bad.append('(Q7) the app does not leave queued (queued.remove(pkg);) after the RETRY arm')
if sw.count('queued.removeAll(work);') != 1 or not re.search(
        r'\}\s*queued\.removeAll\(work\);\s*\}\s*finally\s*\{\s*qDrop\(queued\);', sw):
    bad.append('(Q7) the try does not end with queued.removeAll(work); before the finally\'s qDrop(queued);')

# Q8 the remembered tap's claim is its own (RF-002): tapHeld is set after each claim and cleared before each call, the
# catch releases the app, a busy retry claims it again, and the cleanup releases only a claim still held
lp = sw.find('for (int k = 0; k < remembered.size()')
if lp < 0:
    bad.append('(Q8) sweepAuto has no remembered-tap loop')
else:
    a, b = block(sw, lp)
    tl = sw[a:b]
    if not re.search(r'boolean tapHeld = false;\s*try \{\s*qEnqueue\(%s\);\s*tapHeld = true;\s*while \(!SignOutGate\.begun\(\)\) \{' % re.escape(one), tl):
        bad.append('(Q8) the remembered tap does not claim the app (qEnqueue; tapHeld = true;) before its loop')
    if not re.search(r'MAT_LOCK\.lock\(\);\s*try \{\s*tapHeld = false;\s*materializeAndInstall\(pkg, true\);', tl):
        bad.append('(Q8) the remembered tap does not clear tapHeld before materializeAndInstall')
    if not re.search(r'catch \(Throwable t\) \{\s*tapEnd = SweepOutcome\.ERROR;\s*qDrop\(%s\);' % re.escape(one), tl):
        bad.append('(Q8) the remembered tap\'s catch does not release the app\'s claim')
    if not re.search(r'left -= 1000L;\s*\}\s*qEnqueue\(%s\);\s*tapHeld = true;\s*\}\s*\}\s*finally' % re.escape(one), tl):
        bad.append('(Q8) the remembered tap\'s busy retry does not claim the app again (qEnqueue; tapHeld = true;)')
    if not re.search(r'\}\s*finally\s*\{\s*if \(tapHeld\) qDrop\(%s\);\s*if \(SweepOutcome\.BUSY\.equals\(tapEnd\)\) \{\s*\}' % re.escape(one), tl) \
            or tl.count('qDrop(') != 2:
        bad.append('(Q8) the remembered tap\'s cleanup does not release only a held claim (if (tapHeld) qDrop)')

for b in bad: print('PIN FAILED: ' + b)
if not bad: print('ok Q1-Q8 the FetchQueue reads, the card\'s rows queued, the end release, the deps counted, the nothing-ran exits, the clear, the sweep\'s and the remembered tap\'s own claims')
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <FetchQueue.java> <UnarchiveService.java>: prints every line; 0 pass, 1 failed, 2 compile/extract
  local fq=$1 us=$2 rc=0 prc=0
  cases "$fq" || rc=$?
  pins "$us" || prc=$?
  if [ "$rc" -eq 2 ] || [ "$prc" -eq 2 ]; then return 2; fi
  if [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

out=$(suite "$FQ" "$US"); rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then echo "test-fetch-queue-java: FAIL (rc $rc)"; exit 1; fi
echo "test-fetch-queue-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <fq|us> <python-regex> <replacement> <assertion>...: convicted only by each named assertion
  local name=$1 which=$2 pat=$3 rep=$4 d src orig mfq mus rc=0 mout id miss=""
  shift 4
  d=$(mktemp -d -p "$W") || return 1
  mfq="$d/FetchQueue.java"; mus="$d/UnarchiveService.java"
  cp "$FQ" "$mfq"; cp "$US" "$mus"
  case "$which" in
    fq) src=$mfq; orig=$FQ ;;
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
  mout=$(suite "$mfq" "$mus"); rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$#" -eq 0 ]; then echo "  $name: survived (control)"
    else echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1)); fi
  elif [ "$rc" -eq 2 ]; then
    echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1))
  elif [ "$#" -eq 0 ]; then
    echo "  $name: ⚠ the control FAILED the suite"; fails=$((fails + 1))
  else
    for id in "$@"; do
      case "$id" in
        Q*) [[ "$mout" == *"PIN FAILED: ($id)"* ]] || miss="$miss $id" ;;
        *) [[ "$mout" == *"FAIL $id "* ]] || miss="$miss $id" ;;
      esac
    done
    if [ -z "$miss" ]; then echo "  $name: convicted by $*"
    else echo "  $name: ⚠ failed, but not by$miss"; fails=$((fails + 1)); fi
  fi
  rm -rf "$d"
}

echo "mutants:"
mutant "M1 enqueue admits a finished member" fq 'if \(p == null \|\| finished\.contains\(p\)\) continue;' 'if (p == null) continue;' F2
mutant "M2 release ignores holders" fq 'if \(h <= 1\) pending\.remove\(p\);\s*else pending\.put\(p, h - 1\);' 'pending.remove(p);' F3 F6
mutant "M3 the remembered batch is never restored" fq 'if \(k != 0 && k == rememberedKey\) \{' 'if (false) {' F5
mutant "M4 the remembered batch is restored for any key" fq 'if \(k != 0 && k == rememberedKey\) \{' 'if (rememberedKey != 0) {' F5b
mutant "M5 a drain keeps finished" fq '(remembered\.addAll\(finished\);\s*\}\s*)finished\.clear\(\);' '\1' F1
mutant "M6 start re-adds a finished member" fq '!pending\.containsKey\(pkg\) && !finished\.contains\(pkg\)' '!pending.containsKey(pkg)' F8
mutant "M7 qEnqueue(work); back" us 'qEnqueue\(queued\);' 'qEnqueue(work);' Q2
mutant "M8 the end release removed" us '\n[^\n]*qDrop\(queued\);[^\n]*' '' Q3
mutant "M9 one pendingDeps qFinish(dep) removed" us '(cardDepLanded\(dep\); // another path[^\n]*)\n[^\n]*qFinish\(dep\);[^\n]*' '\1' Q4
mutant "M10 the declined exit finishes" us '\n[^\n]*matRan = false;[^\n]*' '' Q5
mutant "M11 clear() forgets the remembered batch" fq '(synchronized void clear\(\) \{\n)' '\1        remembered.clear();\n' F5
mutant "M12 the verb tests named, not current" us 'q\.current == null \? "Waiting for "' 'q.named == null ? "Waiting for "' Q1
mutant "M13 stopSelfSafely keeps the queue" us '\n[^\n]*FQ\.clear\(\);' '' Q6
mutant "M14 materializeAndInstall never sets matRan" us '\n[^\n]*matRan = true;[^\n]*' '' Q5
mutant "M15 the end release takes the exits' claims again (RF-001)" us '\n[^\n]*queued\.removeAll\(work\);[^\n]*' '' Q7
mutant "M16 a started app stays in queued" us '\n[^\n]*queued\.remove\(pkg\);[^\n]*' '' Q7
mutant "M17 the busy retry does not claim the app again" us '\n[^\n]*qBatch\(card\);\n[^\n]*qEnqueue\(java\.util\.Collections\.singletonList\(pkg\)\);(\n[^\n]*i--;)' '\1' Q7
mutant "M18 the catch keeps the app's claim" us 'end = SweepOutcome\.ERROR; qDrop\(java\.util\.Collections\.singletonList\(pkg\)\); ' 'end = SweepOutcome.ERROR; ' Q7
mutant "M19 the remembered tap's cleanup releases unconditionally (RF-002)" us 'if \(tapHeld\) qDrop\(' 'qDrop(' Q8
mutant "M20 the remembered tap's retry does not claim the app again" us '(left -= 1000L;\n\s*\}\n)[^\n]*\n\s*qEnqueue\(java\.util\.Collections\.singletonList\(pkg\)\);\n\s*tapHeld = true;\n' '\1' Q8
mutant "M21 the remembered tap's catch keeps the claim" us '(tapEnd = SweepOutcome\.ERROR;\n)[^\n]*qDrop\(java\.util\.Collections\.singletonList\(pkg\)\);[^\n]*\n' '\1' Q8
mutant "M22 tapHeld stays set across the call" us '\n[^\n]*tapHeld = false; // materializeAndInstall[^\n]*' '' Q8
mutant "control: a comment edit survives" fq '/\*\* The batch ends when nothing is pending;' '/** The batch ends (a comment edit) when nothing is pending;'
if [ "$fails" -ne 0 ]; then echo "test-fetch-queue-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-fetch-queue-java: all mutants convicted"
