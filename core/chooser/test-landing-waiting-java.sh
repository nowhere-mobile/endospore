#!/usr/bin/env bash
# test-landing-waiting-java.sh [--mutate] -- NWP-20261208-23: the landing card appears when the home screen lands, in
# its waiting state, and turns into the running card when the sweep starts.
#
# WHY. Backlog row "After sign-in lands on the home screen, about 15 s pass with no sign that the Auto apps are coming".
# ChooserActivity.kickAutoMaterialise waits 15 s after the switch lands before it starts the sweep, and the card came
# only from the sweep. Design approved by Chester 2026-11-17 (NWP-20261116-48), words verbatim: the headline
# "Starting in a moment · 0 of <n>" (U+00B7), an empty bar, each row "◷ waiting" (U+25F7), "+<n> more" and Got it as
# today. The 15 s stays: f83e4a1b6 (DIA-20260813-11) set it so the PIN arm lands before the sweep's MATERIALIZE-APP ops.
#
# WHAT RUNS. LandingLine (pure Java) is compiled with tests/landing-waiting/LandingWaitingCases.java and RUN (C1-C20):
# waitingHeadline byte for byte, the 3-arg state and the unchanged 2-arg state, and LandingLine.Sweep's waiting
# record: beginWaiting, go (once, own id only), begin clears waiting, drop (dropped + done, own id only), dropped
# survives a later begin, pkgs is a clone, sameRows; and (C14-C19, RF-001) beginWaiting(ticket, rows) refuses
# when a landing start came after the ticket, runs, or has an open card, so a waiting card shown late never replaces
# the running card's record, and gone() tells an adopted card from a dropped or replaced one; and (C20, RF-002) a
# waiting reader paused between the record and the publish blocks a landing start until the publish, so the landing
# take finds the card and drops it, and no waiting card survives or starts after the landing cleanup.
# WHAT IS PINNED BY ANCHOR (the activities and the service cannot be compiled off the build host), on comment-stripped
# sources: (K1, NWP-20261119-35) kickAutoMaterialise starts NO service between `if (!landed) return;` and
# `Thread.sleep(15000)`, sends no EXTRA_WAITING, and starts UnarchiveService once, after the unchanged 15000 -- the
# waiting start met the SMS role's revoke, which kills the session chooser as the home screen lands (husky 0.5.59,
# 2026-11-19), so the waiting arm below has no sender until it is moved out of that window; (K2) the waiting arm is the sweep thread's first statement and ends
# in workerDone() and return; (K3) showWaitingCard writes nothing (no writeAtomic, no foldAppFirst, no StoreInstaller)
# and calls beginWaiting, then starts the card with EXTRA_SWEEP = w; (K4) sweepAuto takes
# WAITING_CARD on the landing pass only, before LandingLine.show, its adopt path calls Sweep.go and starts no activity, its other path drops the
# waiting card before begin, and a show() that fails drops it; (K5) the landing arm's finally drops a leftover
# WAITING_CARD before workerDone(); (K6) LandingNoticeActivity.sync() checks dropped() first; (K7) render() turns off
# both hold buttons while waiting, draws the waiting headline and an empty bar, and paintRow gets the waiting flag;
# (K8, RF-001) onStartCommand takes the waiting start's ticket before the sweep thread, the landing arm calls
# landingStarts() right after LANDING.set(!byHand) and landingEnds() after the finally's take, and showWaitingCard
# records the card only through beginWaiting(ticket, rows, WAITING_CARD::set), which sets WAITING_CARD under the
# record's lock (RF-002), sets it nowhere else, returns on a refusal, and starts no dropped or replaced card.
# The merger's full javac / `m NowhereChooser` covers UnarchiveService, ChooserActivity and LandingNoticeActivity.
#
# What this does NOT prove: on lynx, the card in its waiting state within 2 s of the home screen at a sign-in with
# Auto apps, and its turn into the running card, stays the merger's handset follow-up.
#
#   bash test-landing-waiting-java.sh              # the cases and the pins
#   bash test-landing-waiting-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
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
  echo "test-landing-waiting-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

LL="$SRC/LandingLine.java"; US="$SRC/UnarchiveService.java"; LA="$SRC/LandingNoticeActivity.java"
CA="$SRC/ChooserActivity.java"; CASES="$HERE/tests/landing-waiting/LandingWaitingCases.java"
for f in "$CASES" "$LL" "$US" "$LA" "$CA"; do
  if [ ! -f "$f" ]; then echo "test-landing-waiting-java: FAIL -- $f is missing"; exit 2; fi
done

cases() { # cases <LandingLine.java> [quiet]: 0 pass, 1 a case failed, 2 did not compile
  local ll=$1 quiet=${2:-} cls srcd out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  srcd=$(mktemp -d -p "$W") || return 2
  mkdir -p "$srcd/com/nowhere/chooser"
  cp "$ll" "$srcd/com/nowhere/chooser/LandingLine.java"
  # The copy is first on the sourcepath, so it shadows the real LandingLine; anything else it names comes from src.
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" -sourcepath "$srcd:$HERE/src" -implicit:class \
      "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls" "$srcd"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.LandingWaitingCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls" "$srcd"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <ChooserActivity.java> <UnarchiveService.java> <LandingNoticeActivity.java> [quiet]: 0 hold, 1 failed
  local quiet=${4:-} out rc=0
  out=$(python3 - "$1" "$2" "$3" <<'PY'
import io, re, sys
ca_path, us_path, la_path = sys.argv[1:4]

def strip(s):
    """Drop // and /* */ comments; string and char literals are kept."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '"' or c == "'":
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

def block(s, at):
    """(start, end) of the text from the first '{' at or after `at` to its matching '}'; None when there is none."""
    j = s.find('{', at)
    if at < 0 or j < 0:
        return None
    d = 0
    for k in range(j, len(s)):
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: return j, k + 1
    return None

def body(s, sig):
    """The block after the one `sig` in s; '' when sig is not there once (a pin then fails, never exit 2)."""
    if s.count(sig) != 1:
        return ''
    b = block(s, s.index(sig))
    return s[b[0]:b[1]] if b else ''

ca = strip(io.open(ca_path, encoding='utf-8').read())
us = strip(io.open(us_path, encoding='utf-8').read())
la = strip(io.open(la_path, encoding='utf-8').read())
bad = []

# K1 (NWP-20261119-35) NO start of UnarchiveService between the landing check and the unchanged 15 s sleep: the
# waiting start that NWP-20261208-23 put there met the SMS role's revoke, which kills the session chooser as the home
# screen lands, and left the sweep service half-restarted (husky 0.5.59, 2026-11-19). The one start is after the sleep.
kick = body(ca, 'private static void kickAutoMaterialise(final android.content.Context appCtx, final int uid) {')
lr = kick.find('if (!landed) return;')
sl = kick.find('Thread.sleep(15000)')
if not kick or kick.count('Thread.sleep(15000)') != 1 or 'UnarchiveService.EXTRA_WAITING' in kick:
    bad.append('(K1) kickAutoMaterialise does not hold Thread.sleep(15000) once, or still sends UnarchiveService.EXTRA_WAITING')
elif not (0 <= lr < sl):
    bad.append('(K1) if (!landed) return; is not before Thread.sleep(15000)')
else:
    if 'startServiceAsUser' in kick[lr:sl]:
        bad.append('(K1) kickAutoMaterialise starts a service between the landing check and the 15 s sleep')
    if kick.count('startServiceAsUser') != 1 or kick.find('startServiceAsUser') < sl:
        bad.append('(K1) kickAutoMaterialise does not start UnarchiveService exactly once, after the 15 s sleep')
    for m in re.finditer(r'Thread\.sleep\((\w+)\)', kick):
        if m.group(1) not in ('1000', '15000'):
            bad.append('(K1) kickAutoMaterialise sleeps %s' % m.group(1))

# K2 the waiting arm is the sweep thread's first statement and ends in workerDone() and return
if 'static final String EXTRA_WAITING = "nowhere.unarchive.waiting";' not in us \
        or 'final boolean waitingStart = intent != null && intent.getBooleanExtra(EXTRA_WAITING, false);' not in us:
    bad.append('(K2) UnarchiveService does not declare EXTRA_WAITING and read it into waitingStart')
sw = body(us, 'Thread sw = new Thread(() -> {')
first = sw[1:].lstrip()
if not first.startswith('if (waitingStart) {'):
    bad.append('(K2) the sweep thread does not start with if (waitingStart) {')
else:
    wb = block(first, 0)
    arm = first[wb[0]:wb[1]] if wb else ''
    if 'try { showWaitingCard(waitTicket); }' not in arm or 'finally { workerDone(); }' not in arm:
        bad.append('(K2) the waiting arm does not run showWaitingCard(), workerDone() in a finally, then return')
    if not arm[:-1].rstrip().endswith('return;') or arm.find('finally { workerDone(); }') > arm.rfind('return;') \
            or 'sweepAuto' in arm:
        bad.append('(K2) the waiting arm does not end in return; after its finally, or runs a sweep')

# K3 showWaitingCard reads and shows; it writes nothing
wc = body(us, 'private void showWaitingCard(long ticket) {')
if not wc:
    bad.append('(K3) UnarchiveService has no one showWaitingCard()')
else:
    for t in ('writeAtomic', 'foldAppFirst', 'StoreInstaller.', 'qEnqueue', 'step('):
        if t in wc:
            bad.append('(K3) showWaitingCard names %s: it must write nothing' % t)
    for t in ('SweepHold.held()', 'work.removeAll(OLDER_COPY);', 'AutoSweepNet.mayFetch(false,',
              'LandingLine.show(true, work.size(), readLandingStamp(stamp), landingSerial())',
              'LandingLine.cardPkgs(work, p -> ProfileActivity.appDeps(this, p), p -> hasInstalledCode(p))'):
        if t not in wc:
            bad.append('(K3) showWaitingCard does not hold %s' % t)
    jr, pa = wc.find('SweepJoin.running()'), wc.find('pendingAutoApps(this, false)')
    if not (0 <= jr < pa):
        bad.append('(K3) showWaitingCard does not ask SweepJoin.running() before pendingAutoApps(this, false)')
    bw, st = wc.find('LandingLine.Sweep.beginWaiting('), wc.find('startActivity(')
    if wc.count('startActivity(') != 1 or not (0 <= bw < st):
        bad.append('(K3) showWaitingCard does not call beginWaiting, then one startActivity')
    # K8 (RF-001, RF-002) the card is recorded only through the ticket check, WAITING_CARD is set only by that call,
    # under the record's lock, and a dropped or replaced card is not started
    if wc.count('LandingLine.Sweep.beginWaiting(') != 1 \
            or 'long w = LandingLine.Sweep.beginWaiting(ticket, rows, WAITING_CARD::set);' not in wc:
        bad.append('(K8) showWaitingCard does not record the card with LandingLine.Sweep.beginWaiting(ticket, rows, WAITING_CARD::set) only')
    if 'WAITING_CARD.set(' in wc or 'WAITING_CARD.lazySet(' in wc:
        bad.append('(K8) showWaitingCard sets WAITING_CARD outside beginWaiting, after the record lock is released (RF-002)')
    z = wc.find('if (w == 0L) {')
    if not (0 <= bw < z < st) or 'return;' not in wc[z:wc.find('}', z) + 1]:
        bad.append('(K8) showWaitingCard does not return on a refused card (w == 0L) before the start')
    gn = wc.find('if (LandingLine.Sweep.gone(w)) {')
    gb = block(wc, gn) if gn >= 0 else None
    if not (0 <= z < gn < st) or not gb or 'return;' not in wc[gb[0]:gb[1]]:
        bad.append('(K8) showWaitingCard does not return on Sweep.gone(w) between the record and the start')
    else:
        stmt = wc[st:wc.find(';', st)]
        for t in ('LandingNoticeActivity.class', 'Intent.FLAG_ACTIVITY_NEW_TASK', 'LandingNoticeActivity.EXTRA_COUNT, rows.length',
                  'LandingNoticeActivity.EXTRA_PKGS, rows', 'LandingNoticeActivity.EXTRA_SWEEP, w'):
            if t not in stmt:
                bad.append('(K3) the waiting start does not hold %s' % t)

# K4 sweepAuto takes the waiting card, adopts it on the same rows, else drops it
sa = body(us, 'private void sweepAuto(boolean byHand) {')
take = 'long waitCard = landing ? WAITING_CARD.getAndSet(0) : 0L;'
sh = sa.find('if (LandingLine.show(landing, ')
if sa.count(take) != 1 or not (0 <= sa.find(take) < sh):
    bad.append('(K4) sweepAuto does not take WAITING_CARD once, on the landing pass only, before LandingLine.show')
else:
    shb = block(sa, sh)
    showb = sa[shb[0]:shb[1]]
    adopt = 'LandingLine.sameRows(LandingLine.Sweep.pkgs(waitCard), cardRows)) {'
    ai = showb.find(adopt)
    if showb.count(adopt) != 1 or 'LandingLine.Sweep.waiting(waitCard)' not in showb[:ai]:
        bad.append('(K4) the card block does not adopt on Sweep.waiting and sameRows')
    else:
        ab = block(showb, ai)
        ad = showb[ab[0]:ab[1]]
        if 'LandingLine.Sweep.go(waitCard);' not in ad or 'card = waitCard;' not in ad or 'tellCard();' not in ad:
            bad.append('(K4) the adopt path does not set card = waitCard, call Sweep.go and tell the card')
        if 'startActivity(' in ad or 'Sweep.begin(' in ad:
            bad.append('(K4) the adopt path starts an activity or begins a new card')
        rest = showb[ab[1]:].lstrip()
        if not rest.startswith('else {'):
            bad.append('(K4) the adopt path has no else')
        else:
            eb = block(rest, 0)
            el = rest[eb[0]:eb[1]]
            dr, bg, st = el.find('LandingLine.Sweep.drop(waitCard);'), el.find('LandingLine.Sweep.begin('), el.find('startActivity(')
            if not (0 <= dr < bg < st):
                bad.append('(K4) the other path does not drop the waiting card before begin and the start')
    tail = sa[shb[1]:].lstrip()
    if not tail.startswith('else if (waitCard != 0L) {'):
        bad.append('(K4) a show() that fails does not drop the waiting card')
    else:
        tb = block(tail, 0)
        if 'LandingLine.Sweep.drop(waitCard);' not in tail[tb[0]:tb[1]]:
            bad.append('(K4) a show() that fails does not drop the waiting card')

# K5 the landing arm's finally drops a leftover
call = 'try { sweepAutoJoined(byHand); }'
ci = us.find(call)
# K8 (RF-001) the ticket is taken on the main thread before the sweep thread, and the landing start counts before its sweep
tk = 'final long waitTicket = waitingStart ? LandingLine.Sweep.landingTicket() : 0L;'
if us.count(tk) != 1 or not (0 <= us.find(tk) < us.find('Thread sw = new Thread(() -> {')):
    bad.append('(K8) onStartCommand does not take waitTicket before the sweep thread')
lset = us.find('LANDING.set(!byHand);')
ls = us.find('LandingLine.Sweep.landingStarts();')
if us.count('LandingLine.Sweep.landingStarts();') != 1 or not (0 <= lset < ls < ci) \
        or us[lset:ls].count(';') != 1:
    bad.append('(K8) the landing arm does not call LandingLine.Sweep.landingStarts() right after LANDING.set(!byHand)')
fi = us.find('finally {', ci)
if us.count(call) != 1 or fi < 0 or us[ci:fi].count(';') > 3:
    bad.append('(K5) no finally right after try { sweepAutoJoined(byHand); }')
else:
    fb = block(us, fi)
    fin = us[fb[0]:fb[1]]
    g, d, wd = fin.find('WAITING_CARD.getAndSet(0)'), fin.find('LandingLine.Sweep.drop('), fin.find('workerDone();')
    if not (0 <= g < d < wd) or 'tellCard();' not in fin:
        bad.append('(K5) the landing finally does not take WAITING_CARD, drop it and tell the card before workerDone()')
    le = fin.find('LandingLine.Sweep.landingEnds();')
    if not (0 <= g < le < wd):
        bad.append('(K8) the landing finally does not call landingEnds() after the WAITING_CARD take, before workerDone()')

# K6 sync() checks dropped() first
sy = body(la, 'private void sync() {')
if not sy[1:].lstrip().startswith('if (LandingLine.Sweep.dropped(sweep)) { finish(); return; }'):
    bad.append('(K6) sync() does not start with if (LandingLine.Sweep.dropped(sweep)) { finish(); return; }')

# K7 render() while waiting
rn = body(la, 'private void render() {')
for t in ('boolean waiting = LandingLine.Sweep.waiting(sweep);', 'setHoldButton(pauseBtn, !ended && !waiting);',
          'setHoldButton(stopBtn, !ended && !paused && !waiting);',
          'if (waiting) headline.setText(LandingLine.waitingHeadline(pkgs.length));',
          'bar.setProgress(waiting ? 0 : got);', 'moreRow.setText(LandingLine.more(more));'):
    if t not in rn:
        bad.append('(K7) render() does not hold %s' % t)
if rn.count('paintRow(') != 2 or rn.count(', waiting);') < 2 or 'paintRow(i, i, waiting);' not in rn \
        or 'paintRow(s, show[s], waiting);' not in rn:
    bad.append('(K7) render() does not give paintRow the waiting flag in both layouts')
pr = body(la, 'private void paintRow(int slot, int i, boolean waiting) {')
if 'LandingLine.state(landed[i], i == installing, waiting)' not in pr:
    bad.append('(K7) paintRow does not take its words from LandingLine.state(landed[i], i == installing, waiting)')

for b in bad: print('PIN FAILED: ' + b)
if not bad: print('ok K1-K8 pins hold')
sys.exit(1 if bad else 0)
PY
) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

suite() { # suite <LL> <CA> <US> <LA> [quiet]: 0 pass, 1 a case or pin failed, 2 did not compile
  local crc prc
  cases "$1" "${5:-}"; crc=$?
  pins "$2" "$3" "$4" "${5:-}"; prc=$?
  if [ "$crc" -eq 2 ]; then return 2; fi
  if [ "$crc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$LL" "$CA" "$US" "$LA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-landing-waiting-java: FAIL (rc $rc)"; exit 1; fi
echo "test-landing-waiting-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: ll|ca|us|la> <python-regex> <replacement> <the assertion that convicts it>
  local name=$1 which=$2 pat=$3 rep=$4 want=$5 d src orig mll mca mus mla rc=0 out
  d=$(mktemp -d -p "$W") || return 1
  mll="$d/LandingLine.java"; mca="$d/ChooserActivity.java"; mus="$d/UnarchiveService.java"; mla="$d/LandingNoticeActivity.java"
  cp "$LL" "$mll"; cp "$CA" "$mca"; cp "$US" "$mus"; cp "$LA" "$mla"
  case "$which" in
    ll) src=$mll; orig=$LL ;;
    ca) src=$mca; orig=$CA ;;
    us) src=$mus; orig=$US ;;
    la) src=$mla; orig=$LA ;;
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
  out=$( { cases "$mll"; pins "$mca" "$mus" "$mla"; } 2>&1 )
  suite "$mll" "$mca" "$mus" "$mla" quiet; rc=$?
  if [ "$rc" -eq 1 ]; then
    case "$out" in
      *"$want"*) echo "  $name: convicted by $want" ;;
      *) echo "  $name: ⚠ failed, but not by $want"; fails=$((fails + 1)) ;;
    esac
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

echo "mutants:"
mutant "M1 the headline without the middle dot" ll '" · 0 of "' '" 0 of "' 'FAIL C1'
mutant "M2 WAITING is \"Waiting\"" ll 'WAITING = "waiting";' 'WAITING = "Waiting";' 'FAIL C2'
mutant "M3 state ignores waiting" ll '\n[^\n]*if \(waiting\) return CLOCK \+ " " \+ WAITING;' '' 'FAIL C2'
mutant "M4 go() leaves waiting set" ll '(if \(sweep == 0 \|\| sweep != id \|\| !waiting\) return false;)\n[^\n]*waiting = false;' '\1' 'FAIL C6'
mutant "M5 begin() keeps waiting" ll '(done = false;)\n[^\n]*waiting = false;' '\1' 'FAIL C8'
mutant "M6 drop() leaves done false" ll '(if \(sweep == 0 \|\| sweep != id\) return;)\n[^\n]*done = true;' '\1' 'FAIL C9'
mutant "M7 the early waiting start put back (NWP-20261119-35)" ca '(if \(!landed\) return;[^\n]*\n)' '\1            try { appCtx.startServiceAsUser(new android.content.Intent(appCtx, UnarchiveService.class).putExtra(UnarchiveService.EXTRA_SWEEP, true).putExtra(UnarchiveService.EXTRA_WAITING, true), android.os.UserHandle.of(uid)); } catch (Throwable t) { }\n' '(K1)'
mutant "M8 showWaitingCard writes the stamp" us '(\n[^\n]*)(long w = LandingLine\.Sweep\.beginWaiting\(ticket, rows, WAITING_CARD::set\);)' '\1StoreInstaller.writeAtomic(stamp, landingSerial());\1\2' '(K3)'
mutant "M9 showWaitingCard folds first" us '(private void showWaitingCard\(long ticket\) \{\n)' '\1        StoreInstaller.foldAppFirst(this);\n' '(K3)'
mutant "M10 the adopt path also starts the card" us '(LandingLine\.Sweep\.go\(waitCard\);\n[^\n]*tellCard\(\);)' '\1 startActivity(new Intent(this, LandingNoticeActivity.class));' '(K4)'
mutant "M11 the mismatch path skips the drop" us '\n[^\n]*if \(waitCard != 0L\) \{ LandingLine\.Sweep\.drop\(waitCard\); tellCard\(\); \}(\n[^\n]*card = LandingLine\.Sweep\.begin)' '\1' '(K4)'
mutant "M12 the landing finally does not drop" us '\n[^\n]*if \(left != 0L\) \{ LandingLine\.Sweep\.drop\(left\); tellCard\(\); \}' '' '(K5)'
mutant "M13 sync() does not check dropped()" la '\n[^\n]*if \(LandingLine\.Sweep\.dropped\(sweep\)\) \{ finish\(\); return; \}[^\n]*' '' '(K6)'
mutant "M14 Pause enabled while waiting" la 'setHoldButton\(pauseBtn, !ended && !waiting\);' 'setHoldButton(pauseBtn, !ended);' '(K7)'
mutant "M15 the sleep shortened to 5000" ca 'try \{ Thread\.sleep\(15000\); \}' 'try { Thread.sleep(5000); }' '(K1)'
# RF-001: a waiting card shown late must not replace the running card's record
mutant "M16 beginWaiting ignores the ticket" ll 'if \(ticket != landings \|\| ' 'if (' 'FAIL C18'
mutant "M17 beginWaiting ignores an open landing start" ll '\|\| landingsOpen > 0 ' '' 'FAIL C16'
mutant "M18 beginWaiting replaces an open card" ll ' \|\| \(id != 0 && !done\)\) return 0;' ') return 0;' 'FAIL C17'
mutant "M19 gone() misses a replaced card" ll 'return sweep == 0 \|\| sweep != id \|\| sweep == dropped;' 'return sweep == 0 || sweep == dropped;' 'FAIL C19'
mutant "M20 showWaitingCard records without the ticket" us 'LandingLine\.Sweep\.beginWaiting\(ticket, rows, WAITING_CARD::set\)' 'LandingLine.Sweep.beginWaiting(rows)' '(K8)'
mutant "M21 showWaitingCard starts a dropped card" us '\n[^\n]*if \(LandingLine\.Sweep\.gone\(w\)\) \{[^\n]*\n[^\n]*\n[^\n]*return;\n[^\n]*\}' '' '(K8)'
mutant "M22 the landing start is not counted" us '\n[^\n]*LandingLine\.Sweep\.landingStarts\(\);[^\n]*' '' '(K8)'
mutant "M23 landingEnds before the take" us '(\n[^\n]*long left = WAITING_CARD\.getAndSet\(0\);)' '\n                    LandingLine.Sweep.landingEnds();\1' '(K8)'
mutant "M24 the ticket taken in the thread" us '\n[^\n]*final long waitTicket = [^\n]*' '' '(K8)'
# RF-002: the waiting card is published under the record's lock, so a landing start's take cannot miss it
mutant "M25 the publish outside the record lock" ll 'static synchronized long beginWaiting\(long ticket, String\[\] rows, java' 'static long beginWaiting(long ticket, String[] rows, java' 'FAIL C20'
mutant "M26 showWaitingCard sets WAITING_CARD after beginWaiting" us 'LandingLine\.Sweep\.beginWaiting\(ticket, rows, WAITING_CARD::set\);' 'LandingLine.Sweep.beginWaiting(ticket, rows, x -> { }); WAITING_CARD.set(w);' '(K8)'
if [ "$fails" -ne 0 ]; then echo "test-landing-waiting-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-landing-waiting-java: all mutants convicted"
