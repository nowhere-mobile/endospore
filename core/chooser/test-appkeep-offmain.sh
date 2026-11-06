#!/usr/bin/env bash
# test-appkeep-offmain.sh [--mutate] -- the three paths that used to wait on StoreInstaller.APPKEEP_LOCK from the
# MAIN thread now take it only off the main thread.
#
# WHY THIS IS COMMITTED. Backlog row "Three UI-thread paths still wait on `APPKEEP_LOCK`" (NWP-20260925-03 filed
# it, NWP-20261029-19 closes it in code). The lock is a leaf held for milliseconds, so none of the three froze
# Profile -- but the 2026-09-26 freeze was exactly "slow work added under the lock while a UI-thread waiter
# exists", and the shape of the code (not the current hold time) is what keeps it from recurring. A later edit
# that tidies a worker back onto the UI thread compiles, runs and passes every functional check, so the shape is
# pinned here:
#   P1 AppInstallReceiver.onReceive calls goAsync() and hands its WHOLE body to ONE static single-thread
#      executor (Executors.newSingleThreadExecutor -- one thread keeps an update's removed+added and an
#      uninstall-then-reinstall in arrival order). Outside the submitted lambda onReceive contains no decide( and
#      no noteAppGone(; inside it a finally block calls .finish().
#   P2 ProfileActivity.showYourApps calls applyDefaultsToUndecided( exactly once, inside a new Thread( (or
#      .execute() lambda) and BEFORE that same body's readAppKeep( -- the reconcile still precedes the rows.
#   P3 ProfileActivity.confirmDropAndSignOut calls recordTurnedOff( only inside a new Thread( lambda, and
#      doLogoff only as runOnUiThread(this::doLogoff) / runOnUiThread(() -> doLogoff()) inside that lambda and
#      AFTER the last record.
# All in FUNCTIONAL form: comments and string/char literals are stripped by a one-pass scanner before any match,
# methods and lambda bodies are found by brace matching. python3 is required and the suite FAILS without it.
#
# Mutants (each must be CONVICTED under every shell found of bash, sh, dash, mksh; one that does not apply is a
# failure): Q1 decide() called on the receiver's thread; Q2 a multi-thread pool for the single-thread executor;
# Q3 finish() removed; Q4 the reconcile moved back before the thread; Q5 doLogoff called directly (outside
# runOnUiThread); Q6 doLogoff run (on the UI thread) before the record loop.
#
#   bash test-appkeep-offmain.sh            # the pins
#   bash test-appkeep-offmain.sh --mutate   # ... plus the mutants
# Override the sources with APPKEEP_AIR / APPKEEP_PA.

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
AIR=${APPKEEP_AIR:-$HERE/src/com/nowhere/chooser/AppInstallReceiver.java}
PA=${APPKEEP_PA:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 2; }

cat > "$W/scan.py" <<'PYEOF'
import re, sys, shutil, os

def strip(src):
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]; d = src[i:i+2]
        if d == '//':
            while i < n and src[i] != '\n': i += 1
        elif d == '/*':
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(' ')
        elif src[i:i+3] == '"""':
            j = src.find('"""', i + 3); i = n if j < 0 else j + 3; out.append('""')
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            i = j + 1; out.append(c + c)
        else:
            out.append(c); i += 1
    return ''.join(out)

def match(code, i, o, c):
    d = 0
    for j in range(i, len(code)):
        if code[j] == o: d += 1
        elif code[j] == c:
            d -= 1
            if d == 0: return j
    return -1

def method(code, sig):
    m = re.search(sig + r'[^;{]*\{', code)
    if not m: return None
    o = m.end() - 1; e = match(code, o, '{', '}')
    return (o, e) if e > 0 else None

def lambdas(code, lo, hi, intro):
    """(open, close) of every `intro ... -> {` body between lo and hi."""
    res = []
    for m in re.finditer(intro, code[lo:hi]):
        a = lo + m.end()
        k = re.compile(r'->\s*\{').search(code, a, hi)
        if not k: continue
        o = k.end() - 1; e = match(code, o, '{', '}')
        if e > 0: res.append((o, e))
    return res

def inside(rs, i):
    return [r for r in rs if r[0] < i < r[1]]

def check(air, pa):
    fails = []
    ac = strip(open(air, encoding='utf-8').read())
    pc = strip(open(pa, encoding='utf-8').read())
    # ---- P1
    ob = method(ac, r'public\s+void\s+onReceive\s*\(\s*Context\s+\w+\s*,\s*Intent\s+\w+\s*\)')
    if not ob: print('CONTROL: onReceive not found'); return 2
    body = ac[ob[0]:ob[1]+1]
    fld = re.findall(r'static\s+(?:final\s+)?[\w.<>]+\s+(\w+)\s*=\s*(?:java\.util\.concurrent\.)?Executors\.newSingleThreadExecutor\s*\(', ac)
    p1 = []
    if not fld: p1.append('no static field initialised by Executors.newSingleThreadExecutor(')
    if 'goAsync()' not in body: p1.append('onReceive does not call goAsync()')
    lam = []
    for f in fld:
        lam += lambdas(body, 0, len(body), r'\b' + f + r'\s*\.\s*(?:execute|submit)\s*\(')
    if fld and not lam: p1.append('onReceive submits no lambda to the single-thread executor')
    for tok in ('decide(', 'noteAppGone('):
        for m in re.finditer(re.escape(tok), body):
            if not inside(lam, m.start()): p1.append('%s outside the submitted lambda' % tok)
    if lam and not any(re.search(r'finally\s*\{[^{}]*\.finish\s*\(\s*\)', body[a:b]) for a, b in lam):
        p1.append('no finally block calling .finish() inside the submitted lambda')
    # ---- P2
    sb = method(pc, r'private\s+void\s+showYourApps\s*\(\s*\)')
    if not sb: print('CONTROL: showYourApps not found'); return 2
    calls = [m.start() for m in re.finditer(r'\bapplyDefaultsToUndecided\s*\(', pc[sb[0]:sb[1]])]
    calls = [sb[0] + c for c in calls]
    p2 = []
    if len(calls) != 1: p2.append('applyDefaultsToUndecided( called %d times, want 1' % len(calls))
    else:
        rs = lambdas(pc, sb[0], sb[1], r'new\s+Thread\s*\(') + lambdas(pc, sb[0], sb[1], r'\.\s*execute\s*\(')
        ins = inside(rs, calls[0])
        if not ins: p2.append('the reconcile is not inside a worker body')
        else:
            r = min(ins, key=lambda x: x[1] - x[0])
            rk = [m.start() + r[0] for m in re.finditer(r'\breadAppKeep\s*\(', pc[r[0]:r[1]])]
            if not rk: p2.append('control: the worker body never reads the keep-set')
            elif calls[0] > min(rk): p2.append('the reconcile follows the keep-set read')
    # ---- P3
    cb = method(pc, r'private\s+void\s+confirmDropAndSignOut\s*\(')
    if not cb: print('CONTROL: confirmDropAndSignOut not found'); return 2
    cbody = pc[cb[0]:cb[1]+1]
    recs = [m.start() for m in re.finditer(r'\brecordTurnedOff\s*\(', cbody)]
    if not recs: print('CONTROL: no recordTurnedOff in confirmDropAndSignOut'); return 2
    ths = lambdas(cbody, 0, len(cbody), r'new\s+Thread\s*\(') + lambdas(cbody, 0, len(cbody), r'\.\s*execute\s*\(')
    p3 = []
    for r in recs:
        if not inside(ths, r): p3.append('recordTurnedOff( outside a worker body')
    logs = [m for m in re.finditer(r'\bdoLogoff\b', cbody)]
    if not logs: p3.append('doLogoff is never reached')
    for m in logs:
        pre = cbody[:m.start()]
        if not re.search(r'runOnUiThread\s*\(\s*(?:this\s*::\s*|\(\s*\)\s*->\s*(?:\{\s*)?(?:this\s*\.\s*)?)$', pre):
            p3.append('doLogoff not reached via runOnUiThread')
        elif not inside(ths, m.start()): p3.append('doLogoff not inside the worker body')
        elif m.start() < max(recs): p3.append('doLogoff before the last record')
    for name, fl in (('P1', p1), ('P2', p2), ('P3', p3)):
        if fl:
            for f in fl: print('FAIL %s: %s' % (name, f))
            fails.append(name)
        else: print('ok   %s' % name)
    return 1 if fails else 0

def sub1(t, old, new):
    if t.count(old) != 1: return None
    return t.replace(old, new)

def mutate(q, air, pa, od):
    ta = open(air, encoding='utf-8').read(); tp = open(pa, encoding='utf-8').read()
    na, np_ = ta, tp
    if q == 'Q1':
        na = sub1(ta, 'final PendingResult pending = goAsync();', 'final PendingResult pending = goAsync();\n        decide(context, "x.y", false, "broadcast");')
    elif q == 'Q2':
        na = sub1(ta, 'Executors.newSingleThreadExecutor(', 'Executors.newFixedThreadPool(4, ')
    elif q == 'Q3':
        na = sub1(ta, '                pending.finish();\n', '')
    elif q == 'Q4':
        call = '            AppInstallReceiver.applyDefaultsToUndecided(this);\n'
        np_ = sub1(tp, call, '')
        if np_ is not None:
            np_ = sub1(np_, '        finishMenuScreen(ll, this::showPreferences, head);', '        AppInstallReceiver.applyDefaultsToUndecided(this);\n        finishMenuScreen(ll, this::showPreferences, head);')
    elif q == 'Q5':
        np_ = sub1(tp, 'runOnUiThread(this::doLogoff);', 'doLogoff();')
    elif q == 'Q6':
        np_ = sub1(tp, '                    for (String pkg : pkgs) recordTurnedOff(pkg);\n                    runOnUiThread(this::doLogoff);',
                   '                    runOnUiThread(this::doLogoff);\n                    for (String pkg : pkgs) recordTurnedOff(pkg);')
    if na is None or np_ is None: return 2
    a = os.path.join(od, 'A.java'); p = os.path.join(od, 'P.java')
    open(a, 'w', encoding='utf-8').write(na); open(p, 'w', encoding='utf-8').write(np_)
    return 0

if __name__ == '__main__':
    try:
        if sys.argv[1] == 'check': rc = check(sys.argv[2], sys.argv[3])
        else: rc = mutate(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    except Exception as e:   # a scanner crash is BROKEN (2), never a conviction (1)
        print('CONTROL: scanner error: %r' % (e,)); rc = 2
    sys.exit(rc)
PYEOF

if [ "$1" = "--check-only" ]; then
  python3 -I "$W/scan.py" check "$2" "$3"
  exit $?
fi

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "FAIL: no shell found"; exit 2; }
BAD=0

for f in "$AIR" "$PA"; do [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 2; }; done

out=$(python3 -I "$W/scan.py" check "$AIR" "$PA" 2>&1); rc=$?
echo "$out"
[ $rc -eq 0 ] || BAD=1
for s in $SHELLS; do
  o=$("$s" "$0" --check-only "$AIR" "$PA" 2>&1); r=$?
  if [ $r -eq 0 ]; then echo "ok   under $s"; else echo "FAIL under $s (rc=$r)"; BAD=1; fi
done

if [ "$1" = "--mutate" ] && [ $BAD -eq 0 ]; then
  for q in Q1 Q2 Q3 Q4 Q5 Q6; do
    d=$(mktemp -d -p "$W") || exit 2
    python3 -I "$W/scan.py" mut "$q" "$AIR" "$PA" "$d"; mrc=$?
    if [ $mrc -ne 0 ]; then echo "BROKEN $q: mutant did not apply"; BAD=1; continue; fi
    for s in $SHELLS; do
      o=$("$s" "$0" --check-only "$d/A.java" "$d/P.java" 2>&1); r=$?
      if [ $r -eq 1 ]; then echo "convicted $q under $s"
      else echo "NOT CONVICTED $q under $s (rc=$r)"; BAD=1; fi
    done
  done
fi

if [ $BAD -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAILED"; exit 1
