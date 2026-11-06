#!/usr/bin/env bash
# test-pending-row-java.sh [--mutate] -- NWP-20261027-12: the Your apps "Install pending apps now" row recounts after a
# drained mode change.
#
# WHY. The row was counted once per build (UnarchiveService.pendingAutoApps on the list thread), so an app set to Auto
# never brought it up, and its count never changed, until the screen was rebuilt (lynx 0.5.48, 2026-10-19).
#
# WHAT RUNS. PendingRow (pure Java) is compiled with PendingRowCases and RUN: the add / replace / remove decision.
# WHAT IS PINNED BY ANCHOR (ProfileActivity cannot be compiled off the build host): (a) onRowChange calls
# refreshPendingRow only inside a `MODE_PENDING.get() == 0` condition; (b) refreshPendingRow calls
# UnarchiveService.pendingAutoApps inside a `new Thread(` body, never after runOnUiThread; (c) it checks
# isAttachedToWindow() before touching ll; (e) a superseded recount (older ticket) never draws; (f) the ticket is per build of the list, not an Activity field; (d) the first build no longer adds the row with a bare ll.addView; and
# applyPendingRow asks PendingRow.action.
# NWP-20261117-40: the end of an auto sweep redraws an open Your apps, so the suite reads UnarchiveService too:
# (g) sweepAuto sends ACTION_SWEEP_DONE once, scoped with setPackage(getPackageName()), inside a try, after its
# "#130 sweep done" log statement; (h) showYourApps registers one receiver for it with RECEIVER_NOT_EXPORTED, only
# under an isAttachedToWindow() check, and ll's detach listener unregisters it; (i) the receiver measures the sizes in
# `new Thread(` and, on the UI thread, checks ll is attached, then sizes.putAll, updateSummary.run() and a
# refreshPendingRow under `MODE_PENDING.get() == 0`; (j) sizes.putAll( is written only inside a runOnUiThread body.
# NWP-20261119-30: a sweep's end rebuilds the row at an unchanged count and redraws each app row's size line. The cases
# run PendingRow.action(shown, n, sweepEnded): (n, n, true) is REPLACE for n in 1..4, and the false form equals the
# two-argument form for shown, n in 0..4. The pins, read with comment lines stripped: (k) the sweepDone UI block runs
# sizes.putAll, then the keepRowSizePaints loop, then refreshPendingRow(..., true) under `MODE_PENDING.get() == 0`;
# (l) no other refreshPendingRow call passes true; (m) the 6-argument applyPendingRow asks the three-argument
# PendingRow.action, and the 6-argument refreshPendingRow hands sweepEnded on; (n) appKeepRow adds its size view at its
# own top level and registers a repaint that reads sizes.get(pkg); (o) keepRowSizePaints is cleared wherever
# keepRowPaints is. The two 6-argument overloads are read as the LAST declaration of each name.
# The merger's full javac / `m NowhereChooser` covers ProfileActivity and UnarchiveService themselves.
#
# What this does NOT prove: the device run (set an on-demand app to Auto; the row appears without leaving Your apps)
# stays on the backlog row, as does the sweep-end run (Install pending apps now with Your apps open; the row, the
# waiting line and the old size go without leaving the screen), and the handset run of NWP-20261119-30 (a sweep that
# leaves an app pending shows "Install" again; the installed app's row shows its size, without leaving the screen).
#
#   bash test-pending-row-java.sh              # the cases and the pins
#   bash test-pending-row-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
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
  echo "test-pending-row-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

pins() { # pins <ProfileActivity.java> <UnarchiveService.java>: rc 0 all hold, 1 a pin failed, 2 could not extract
  python3 - "$1" "$2" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
us = io.open(sys.argv[2], encoding='utf-8').read()

def body(sig, text=None):
    src = globals()['src'] if text is None else text
    n = src.count(sig)
    if n != 1:
        print("EXTRACTION FAILED: %r occurs %d times" % (sig, n)); sys.exit(2)
    i = src.index(sig)
    j = src.index('{', i + len(sig) - 1) if sig.endswith('{') is False else i + len(sig) - 1
    d = 0
    for k in range(j, len(src)):
        if src[k] == '{': d += 1
        elif src[k] == '}':
            d -= 1
            if d == 0: return src[j:k + 1]
    print("EXTRACTION FAILED: unbalanced braces after %r" % sig); sys.exit(2)

def braced(text, at):
    """The brace body of the first { at or after `at`, or '' if there is none or it does not close."""
    j = text.find('{', at)
    if j < 0: return ''
    d = 0
    for k in range(j, len(text)):
        if text[k] == '{': d += 1
        elif text[k] == '}':
            d -= 1
            if d == 0: return text[j:k + 1]
    return ''

def decl6(name):
    """The 6-argument overload of `name`: the LAST `private void <name>(` declaration, which must end
    `boolean sweepEnded) {` before any other { or ;. Returns (signature text, its body)."""
    head, tail = 'private void %s(' % name, 'boolean sweepEnded) {'
    if src.count(head) != 2:
        print("EXTRACTION FAILED: %r occurs %d times, not 2" % (head, src.count(head))); sys.exit(2)
    d = src.rfind(head)
    e = src.find(tail, d)
    if e < 0 or '{' in src[d:e] or ';' in src[d:e]:
        print("EXTRACTION FAILED: the last %r does not end %r" % (head, tail)); sys.exit(2)
    sig = src[d:e + len(tail)]
    b = braced(src, e + len(tail) - 1)
    if not b:
        print("EXTRACTION FAILED: unbalanced braces after %r" % sig); sys.exit(2)
    return sig, b

def nc(t):
    """t without its comment lines (//, /* and * at the start of a line)."""
    return '\n'.join(l for l in t.split('\n') if not l.lstrip().startswith(('//', '/*', '*')))

def blank_strings(t):
    """t with the contents of every string and char literal blanked, so braces and parens inside them do not count."""
    return re.sub(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'', lambda m: m.group(0)[0] + ' ' * (len(m.group(0)) - 2) + m.group(0)[0], t)

def call_args(t, at):
    """The text from the ( at or after `at` to its matching ), by paren depth, or '' if it does not close."""
    j = t.find('(', at)
    if j < 0: return ''
    d = 0
    for k in range(j, len(t)):
        if t[k] == '(': d += 1
        elif t[k] == ')':
            d -= 1
            if d == 0: return t[j:k + 1]
    return ''

refresh_sig, refresh = decl6('refreshPendingRow')
apply_sig, apply_ = decl6('applyPendingRow')
rowchange = body('final Runnable onRowChange = () -> {')
bad = []

# (a) every refreshPendingRow( call in onRowChange sits on the line of a MODE_PENDING.get() == 0 condition
calls = [l for l in rowchange.split('\n') if 'refreshPendingRow(' in l]
if not calls or any('MODE_PENDING.get() == 0' not in l for l in calls):
    bad.append('(a) onRowChange does not call refreshPendingRow inside MODE_PENDING.get() == 0')

# (b) the count is taken inside new Thread(, before runOnUiThread(, and never after it
t, ui = refresh.find('new Thread('), refresh.find('runOnUiThread(')
p = refresh.find('UnarchiveService.pendingAutoApps(')
if not (0 <= t < p < ui) or 'pendingAutoApps(' in refresh[ui:]:
    bad.append('(b) refreshPendingRow does not count pendingAutoApps on its background thread')

# (c) the attached check precedes any use of ll on the UI thread
tail = refresh[ui:] if ui >= 0 else ''
a = tail.find('isAttachedToWindow()')
use = [m.start() for m in re.finditer(r'\bll\.|applyPendingRow\(', tail)]
first_ll = min([u for u in use if not tail[u:].startswith('ll.isAttachedToWindow')] or [-1])
if a < 0 or (first_ll >= 0 and first_ll < a):
    bad.append('(c) refreshPendingRow does not check isAttachedToWindow() before touching ll')

# (e) a recount that is not the newest asked for never draws: the ticket is taken before the thread starts and
# compared on the UI thread before applyPendingRow
# (f) the ticket belongs to one build of the list: a parameter of refreshPendingRow, declared in the build, never an Activity field
sig = refresh_sig
if 'AtomicInteger pendingRowTicket' not in sig or re.search(r'AtomicInteger pendingRowTicket\s*=', src) \
        or 'final java.util.concurrent.atomic.AtomicInteger pendingTicket = new' not in src:
    bad.append('(f) the recount ticket is not local to one build of the list')
tk = refresh.find('pendingRowTicket.incrementAndGet()')
if re.search(r'(private|static)[^;(]*\bpendingRowTicket\b', src) or 'final java.util.concurrent.atomic.AtomicInteger pendingTicket = new' not in src:
    bad.append('(f) the recount ticket is not local to one build of the list')
cmp_ = tail.find('ticket != pendingRowTicket.get()')
ap = tail.find('applyPendingRow(')
if not (0 <= tk < t) or cmp_ < 0 or ap < 0 or cmp_ > ap:
    bad.append('(e) refreshPendingRow does not drop a superseded recount before drawing')

# (d) the first build goes through the one apply path
if 'll.addView(installPendingRow(pendingAuto.size())' in src:
    bad.append('(d) the first build still adds the row with a bare ll.addView')
if 'applyPendingRow(ll, summary, pendingRowView, pendingShown, pendingAuto.size())' not in src:
    bad.append('(d) the first build does not call applyPendingRow')
if 'PendingRow.action(' not in apply_:
    bad.append('(d) applyPendingRow does not ask PendingRow.action')

# (g) sweepAuto tells this app, and only this app, that the sweep is done: once, inside a try, after the done line
DECL = 'static final String ACTION_SWEEP_DONE = "com.nowhere.chooser.action.AUTO_SWEEP_DONE";'
SEND = 'sendBroadcast(new Intent(ACTION_SWEEP_DONE)'
sweep = body('private void sweepAuto(', us)
if us.count(DECL) != 1:
    bad.append('(g) UnarchiveService does not declare ACTION_SWEEP_DONE once')
if us.count(SEND) != 1:
    bad.append('(g) UnarchiveService sends ACTION_SWEEP_DONE %d times, not once' % us.count(SEND))
else:
    s_at = sweep.find(SEND)
    stmt = sweep[s_at:sweep.find(';', s_at)] if s_at >= 0 else ''
    if '.setPackage(getPackageName())' not in stmt:
        bad.append('(g) the sweep-done broadcast is not scoped to this package')
    lg = sweep.find('"#130 sweep done: "')
    lg_end = sweep.find(';', lg) if lg >= 0 else -1
    if s_at < 0 or lg_end < 0 or s_at < lg_end:
        bad.append('(g) the sweep-done broadcast is not in sweepAuto after its "#130 sweep done" log statement')
    else:
        line = sweep[sweep.rfind('\n', 0, s_at) + 1:s_at]
        if line.strip() != 'try {':
            bad.append('(g) the sweep-done broadcast is not inside a try')

# (h) one receiver, not exported, registered only while ll is attached, unregistered when ll detaches
sya = body('private void showYourApps() {')
if sya.count('UnarchiveService.ACTION_SWEEP_DONE') != 1:
    bad.append('(h) showYourApps names UnarchiveService.ACTION_SWEEP_DONE %d times, not once'
               % sya.count('UnarchiveService.ACTION_SWEEP_DONE'))
regs = list(re.finditer(r'(?<![A-Za-z0-9_])registerReceiver\(', sya))
if len(regs) != 1:
    bad.append('(h) showYourApps calls registerReceiver %d times, not once' % len(regs))
else:
    r_at = regs[0].start()
    call = sya[r_at:sya.find(';', r_at)]
    if 'UnarchiveService.ACTION_SWEEP_DONE' not in call or 'RECEIVER_NOT_EXPORTED' not in call:
        bad.append('(h) the receiver is not registered for ACTION_SWEEP_DONE with RECEIVER_NOT_EXPORTED')
    guarded = False
    for m in re.finditer(r'if \(ll\.isAttachedToWindow\(\)\) \{', sya):
        g = braced(sya, m.end() - 1)
        if g and m.end() - 1 < r_at < m.end() - 1 + len(g): guarded = True
    if not guarded:
        bad.append('(h) the receiver is registered without an isAttachedToWindow() check')
    la = sya.find('ll.addOnAttachStateChangeListener(', r_at)
    det = sya.find('public void onViewDetachedFromWindow(', la) if la >= 0 else -1
    if la < 0 or det < 0 or 'unregisterReceiver(sweepDone)' not in braced(sya, det):
        bad.append('(h) ll has no detach listener that unregisters the receiver')

# (i) the receiver: measured off the UI thread, drawn on it, only while ll is attached
RCV = 'final android.content.BroadcastReceiver sweepDone = new android.content.BroadcastReceiver() {'
if src.count(RCV) != 1:
    bad.append('(i) showYourApps has no single sweepDone receiver (%d)' % src.count(RCV))
else:
    rcv = body(RCV)
    th = rcv.find('new Thread(')
    thb = braced(rcv, th) if th >= 0 else ''
    ui_at = thb.find('runOnUiThread(')
    ms = thb.find('apkSize(pm.getApplicationInfo(')
    if not thb or ui_at < 0 or not (0 <= ms < ui_at):
        bad.append('(i) the receiver does not measure the sizes inside new Thread( before runOnUiThread(')
    uib = braced(thb, ui_at) if ui_at >= 0 else ''
    at, pa_ = uib.find('ll.isAttachedToWindow()'), uib.find('sizes.putAll(')
    if not (0 <= at < pa_):
        bad.append('(i) the receiver does not check ll.isAttachedToWindow() before sizes.putAll( on the UI thread')
    if pa_ < 0 or uib.find('updateSummary.run()', pa_) < 0:
        bad.append('(i) the receiver does not run updateSummary after sizes.putAll(')
    rl = [l for l in uib.split('\n') if 'refreshPendingRow(' in l]
    if not rl or any('MODE_PENDING.get() == 0' not in l for l in rl):
        bad.append('(i) the receiver does not call refreshPendingRow inside MODE_PENDING.get() == 0')

# (j) sizes is written only on the UI thread: the innermost thread-or-UI lambda around each sizes.putAll( is runOnUiThread
puts = [m.start() for m in re.finditer(r'sizes\.putAll\(', src)]
if not puts:
    bad.append('(j) ProfileActivity has no sizes.putAll(')
spans = []
for m in re.finditer(r'new Thread\(|runOnUiThread\(', src):
    b = braced(src, m.end())
    if b:
        j0 = src.find('{', m.end())
        spans.append((m.start(), j0, j0 + len(b), m.group(0)))
for u in puts:
    inner = [sp for sp in spans if sp[1] < u < sp[2]]
    if not inner or max(inner)[3] != 'runOnUiThread(':
        bad.append('(j) a sizes.putAll( is not written inside a runOnUiThread body')
# (k) the sweepDone UI block: sizes.putAll, then every size repaint, then the recount that says a sweep ended
if src.count(RCV) == 1:
    u = nc(uib)
    pa2 = u.find('sizes.putAll(')
    lp = u.find('new java.util.ArrayList<>(keepRowSizePaints)')
    lb = braced(u, lp) if lp >= 0 else ''
    rt = u.find('refreshPendingRow(ll, summary, pendingRowView, pendingShown, pendingTicket, true)')
    if not (0 <= pa2 < lp) or '.accept(sizes)' not in lb:
        bad.append('(k) the sweepDone block does not run the size repaints after sizes.putAll')
    if not (0 <= lp < rt) or 'MODE_PENDING.get() == 0' not in u[u.rfind('\n', 0, rt) + 1:u.find('\n', rt)]:
        bad.append('(k) the sweepDone block does not call refreshPendingRow with true after the size repaints')

# (l) only the sweepDone recount says a sweep ended
ncs = blank_strings(nc(src))
trues = []
for m in re.finditer(r'(?<![A-Za-z0-9_.])refreshPendingRow\(', ncs):
    if ncs[max(0, m.start() - len('private void ')):m.start()] == 'private void ': continue
    a = call_args(ncs, m.start())
    if re.search(r',\s*true\s*\)$', a): trues.append(m.start())
r_at = ncs.find(RCV)
r_span = (r_at, r_at + len(RCV) + len(braced(ncs, r_at + len(RCV) - 1))) if ncs.count(RCV) == 1 else (-1, -1)
if len(trues) != 1 or not (r_span[0] < trues[0] < r_span[1]):
    bad.append('(l) a refreshPendingRow call other than sweepDone\'s passes true (%d pass true)' % len(trues))
if re.search(r'refreshPendingRow\([^;]*,\s*true\s*\)', nc(rowchange)):
    bad.append('(l) onRowChange\'s refreshPendingRow passes true')

# (m) the 6-argument overloads carry sweepEnded down to the three-argument PendingRow.action
if 'PendingRow.action(shown[0], n, sweepEnded)' not in nc(apply_) or 'PendingRow.action(shown[0], n)' in nc(apply_):
    bad.append('(m) the 6-argument applyPendingRow does not ask the three-argument PendingRow.action')
if 'applyPendingRow(ll, summary, rowRef, shown, n, sweepEnded)' not in nc(refresh):
    bad.append('(m) the 6-argument refreshPendingRow does not hand sweepEnded to applyPendingRow')

# (n) appKeepRow adds its size view at its own top level and registers a repaint that reads the re-measured sizes
akr = blank_strings(nc(body('private LinearLayout appKeepRow(final String pkg, Long sizeBytes, final boolean sideloaded, final Runnable onChange) {')))
top, made, d = set(), False, 0
for l in akr.split('\n'):
    if d == 1: top.add(l.strip())
    d += l.count('{') - l.count('}')
if 'col.addView(sub);' not in top or 'final TextView sub = new TextView(this);' not in top or 'sub.setVisibility(' not in akr:
    bad.append('(n) appKeepRow does not add its size view unconditionally')
reg = akr.find('keepRowSizePaints.add(')
ra = call_args(akr, reg) if reg >= 0 else ''
if 'sizes.get(pkg)' not in ra or 'sub.isAttachedToWindow()' not in ra:
    bad.append('(n) appKeepRow does not register a size repaint that reads sizes')

# (o) keepRowSizePaints is cleared wherever keepRowPaints is: on the same line or the next non-comment line
lines = [l for l in nc(src).split('\n') if l.strip()]
kc = [i for i, l in enumerate(lines) if 'keepRowPaints.clear()' in l]
sc = sum(l.count('keepRowSizePaints.clear()') for l in lines)
if not kc or sc != len(kc) or any('keepRowSizePaints.clear()' not in lines[i] + (lines[i + 1] if i + 1 < len(lines) else '')
                                  for i in kc):
    bad.append('(o) keepRowSizePaints is not cleared wherever keepRowPaints is')
for b in bad: print('PIN FAILED: ' + b)
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <PendingRow.java> <ProfileActivity.java> <UnarchiveService.java> [quiet]: 0 pass, 1 failed, 2/3 could not run
  local pr=$1 pa=$2 us=$3 quiet=${4:-} out rc=0 prc=0
  out=$(bash "$HERE/tests/pending-row/run.sh" "$pr" 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  [ "$rc" -eq 3 ] && return 2
  local pout; pout=$(pins "$pa" "$us" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ] && return 1
  return 0
}

PR="$SRC/PendingRow.java"; PA="$SRC/ProfileActivity.java"; US="$SRC/UnarchiveService.java"
if [ ! -f "$PR" ]; then echo "test-pending-row-java: FAIL -- $PR is missing"; exit 2; fi
if [ ! -f "$US" ]; then echo "test-pending-row-java: FAIL -- $US is missing"; exit 2; fi
suite "$PR" "$PA" "$US"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-pending-row-java: FAIL (rc $rc)"; exit 1; fi
echo "test-pending-row-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: pr|pa|us> <python-regex> <replacement>
  local name=$1 which=$2 pat=$3 rep=$4 d src orig mpr mpa mus rc=0
  d=$(mktemp -d -p "$W") || return 1
  mpr="$d/PendingRow.java"; mpa="$d/ProfileActivity.java"; mus="$d/UnarchiveService.java"
  cp "$PR" "$mpr"; cp "$PA" "$mpa"; cp "$US" "$mus"
  case "$which" in
    pr) src=$mpr; orig=$PR ;;
    pa) src=$mpa; orig=$PA ;;
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
  suite "$mpr" "$mpa" "$mus" quiet; rc=$?
  if [ "$rc" -eq 1 ]; then echo "  $name: convicted"
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

echo "mutants:"
mutant "W1 REPLACE never chosen" pr 'if \(n > 0 && shown != n\) return REPLACE;' 'if (n > 0 && shown != n) return NONE;'
mutant "W2 REMOVE never chosen" pr 'if \(n == 0 && shown > 0\) return REMOVE;' 'if (n == 0 && shown > 0) return NONE;'
mutant "W3 drain condition dropped" pa 'if \(MODE_PENDING\.get\(\) == 0\) refreshPendingRow\(' 'refreshPendingRow('
mutant "W4 pendingAutoApps on the UI thread" pa '(private void refreshPendingRow\(.*?)n = UnarchiveService\.pendingAutoApps\(this, false\)\.size\(\);(.*?runOnUiThread\(\(\) -> \{)' '\1n = 0;\2 final int m = UnarchiveService.pendingAutoApps(this, false).size();'
mutant "W5 attached check dropped" pa '\n[^\n]*if \(!ll\.isAttachedToWindow\(\)\) return;[^\n]*' ''
mutant "W7 ticket shared by every build" pa 'java\.util\.concurrent\.atomic\.AtomicInteger pendingRowTicket, boolean sweepEnded\) \{' 'int unusedTicket, boolean sweepEnded) {'
mutant "W6 superseded recount still draws" pa '\n[^\n]*if \(ticket != pendingRowTicket\.get\(\)\) return;[^\n]*' ''
mutant "G1 the sweep-done broadcast removed" us '\n[^\n]*sendBroadcast\(new Intent\(ACTION_SWEEP_DONE\)[^\n]*' ''
mutant "G2 setPackage dropped" us '(new Intent\(ACTION_SWEEP_DONE\))\.setPackage\(getPackageName\(\)\)' '\1'
mutant "H1 receiver exported" pa '(UnarchiveService\.ACTION_SWEEP_DONE\).*?)RECEIVER_NOT_EXPORTED' '\1RECEIVER_EXPORTED'
mutant "H2 detach unregister removed" pa 'try \{ unregisterReceiver\(sweepDone\); \} catch \(Throwable ignore\) \{\}' ''
mutant "H3 registration not guarded by attach" pa 'if \(ll\.isAttachedToWindow\(\)\) \{(\s*// [^\n]*)?(\s*final android\.content\.BroadcastReceiver sweepDone)' '{\2'
mutant "I1 attached check dropped" pa '\n[^\n]*if \(!ll\.isAttachedToWindow\(\)\) return; // sweep done[^\n]*' ''
mutant "I2 updateSummary.run() dropped" pa '(sizes\.putAll\(fresh\);[^\n]*\n\s*)updateSummary\.run\(\);' '\1'
mutant "I3 recount outside MODE_PENDING" pa '(sizes\.putAll\(fresh\);.*?)if \(MODE_PENDING\.get\(\) == 0\) refreshPendingRow\(' '\1refreshPendingRow('
mutant "J1 putAll in the measuring thread" pa '(\n\s*)(runOnUiThread\(\(\) -> \{\n\s*if \(!ll\.isAttachedToWindow\(\)\) return; // sweep done[^\n]*\n\s*)sizes\.putAll\(fresh\);' '\1sizes.putAll(fresh);\1\2'
mutant "K1 sweepEnded REPLACE branch removed" pr '\n[^\n]*if \(sweepEnded && n > 0\) return REPLACE;[^\n]*' ''
mutant "K2 sweepDone recount passes false" pa '(sizes\.putAll\(fresh\);.*?refreshPendingRow\(ll, summary, pendingRowView, pendingShown, pendingTicket), true\)' '\1, false)'
mutant "K3 size repaint loop removed" pa '\n[^\n]*for \(java\.util\.function\.Consumer<java\.util\.Map<String, Long>> r : new java\.util\.ArrayList<>\(keepRowSizePaints\)\) \{\n[^\n]*\n[^\n]*\}' ''
mutant "K4 onRowChange recount passes true" pa '(final Runnable onRowChange = \(\) -> \{.*?refreshPendingRow\(ll, summary, pendingRowView, pendingShown, pendingTicket)\);' '\1, true);'
mutant "K5 size view only when it has text" pa '(private LinearLayout appKeepRow\(.*?\n(\s*))col\.addView\(sub\);' '\1if ((sizeBytes != null && sizeBytes > 0) || sideloaded) col.addView(sub);'
mutant "K6 size repaint ignores the re-measured map" pa 'paintSize\.accept\(sizes\.get\(pkg\)\)' 'paintSize.accept(sizeBytes)'
mutant "K7 keepRowSizePaints never cleared" pa '\n[^\n]*keepRowSizePaints\.clear\(\);[^\n]*' ''
mutant "K8 refresh drops sweepEnded" pa 'applyPendingRow\(ll, summary, rowRef, shown, n, sweepEnded\)' 'applyPendingRow(ll, summary, rowRef, shown, n, false)'
mutant "K9 apply asks the two-argument action" pa 'PendingRow\.action\(shown\[0\], n, sweepEnded\)' 'PendingRow.action(shown[0], n)'
if [ "$fails" -ne 0 ]; then echo "test-pending-row-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-pending-row-java: all mutants convicted"
