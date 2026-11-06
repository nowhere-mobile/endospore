#!/usr/bin/env bash
# test-claims-login-apply.sh [--mutate] -- a sign-in applies the seeded claim map right after provisionRoamedApps.
#
# WHY THIS IS COMMITTED. Backlog row "EVERY LOGIN STARTS WITH THE OTHER HANDSET’S APPS TAPPABLE". NWP-20261029-06
# seeds nowhere-claims at sign-in; nothing read it until the first seal's kick (~40 s). The sign-in path now kicks
# the roamed user's own CredentialService with the extra claimsLogin. The order is load-bearing and silent when
# wrong: canSuspendPackageForUser refuses a package not installed for the user, so an apply that runs before
# provisionRoamedApps refuses everything and writes no receipt. Pinned, in FUNCTIONAL form (comments are stripped
# before any match; braces are matched, never line-counted):
#   P1 the claimsLogin kick sits in roamLogin AFTER `provisionRoamedApps(uid);`, occurs once in ChooserActivity
#      (so not in kickResumeTelingest or any resume path: a resume keeps its holds), and CredentialService
#      reads the very same extra name.
#   P2 CredentialService's claimsLogin branch calls AppClaim.applyFromFile and neither AppHeld.refresh nor
#      relayNextAlarm (seal-cycle work).
#   P3 that call is inside a `new Thread(` lambda, off the main thread.
#   P4 AppClaim.applyFromFile is serialized: `synchronized` on the method, or one synchronized block covering
#      its whole body.
#   P5 the worker calls finishUnit() in a finally, and the branch returns START_NOT_STICKY.
# python3 is required and the suite FAILS without it.
# Mutants (each must be CONVICTED under every shell found of bash, sh, dash, mksh; one that does not apply is a
# failure): Q1 kick before provisionRoamedApps; Q2 branch also calls AppHeld.refresh; Q3 apply on the calling
# thread; Q4 serialization removed; Q5 extra renamed in one file only; Q6 finishUnit removed from the branch.
#
#   bash test-claims-login-apply.sh            # the pins
#   bash test-claims-login-apply.sh --mutate   # ... plus the mutants
# Override the sources with CLA_CA / CLA_CS / CLA_AC.

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
SRC=$HERE/src/com/nowhere/chooser
CA=${CLA_CA:-$SRC/ChooserActivity.java}
CS=${CLA_CS:-$SRC/CredentialService.java}
AC=${CLA_AC:-$SRC/AppClaim.java}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 2; }

cat > "$W/scan.py" <<'PYEOF'
import re, sys, os

def strip(src):
    """Drop comments; keep string and char literals (the extra's name is one)."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]; d = src[i:i+2]
        if d == '//':
            while i < n and src[i] != '\n': i += 1
        elif d == '/*':
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(' ')
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j+1]); i = j + 1
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

def methods(code, sig):
    res = []
    for m in re.finditer(sig + r'[^;{]*\{', code):
        o = m.end() - 1; e = match(code, o, '{', '}')
        if e > 0: res.append((m.start(), o, e))
    return res

def check(ca, cs, ac):
    ca = strip(open(ca, encoding='utf-8').read())
    cs = strip(open(cs, encoding='utf-8').read())
    ac = strip(open(ac, encoding='utf-8').read())
    fails = []
    # ---- P1
    p1 = []
    names = re.findall(r'putExtra\s*\(\s*"(claims\w*)"\s*,\s*true\s*\)', ca)
    ext = [n for n in names if n != 'claims']
    if len(ext) != 1: p1.append('want exactly one claims-login putExtra in ChooserActivity, found %d' % len(ext))
    else:
        nm = ext[0]
        rl = [m for m in methods(ca, r'\bvoid\s+roamLogin\s*\(') if 'provisionRoamedApps(uid);' in ca[m[1]:m[2]]]
        if not rl: print('CONTROL: roamLogin with provisionRoamedApps(uid); not found'); return 2
        hit = False
        for _, o, e in rl:
            b = ca[o:e]
            k = b.find('putExtra("%s"' % nm)
            if k >= 0:
                hit = True
                if k < b.find('provisionRoamedApps(uid);'): p1.append('the kick precedes provisionRoamedApps(uid);')
        if not hit: p1.append('the kick is not inside roamLogin')
        for _, o, e in methods(ca, r'\bkickResumeTelingest\s*\('):
            if nm in ca[o:e]: p1.append('the kick is in kickResumeTelingest')
        if ca.count('"%s"' % nm) != 1: p1.append('the extra name appears %d times in ChooserActivity' % ca.count('"%s"' % nm))
        if 'getBooleanExtra("%s"' % nm not in cs: p1.append('CredentialService does not read the extra "%s"' % nm)
    # ---- P2..P5
    p2 = []; p3 = []; p5 = []
    m = re.search(r'getBooleanExtra\s*\(\s*"claimsLogin"\s*,\s*false\s*\)\s*\)\s*\{', cs)
    if not m: p2.append('no claimsLogin branch in CredentialService'); p3.append('no branch'); p5.append('no branch')
    else:
        o = m.end() - 1; e = match(cs, o, '{', '}'); br = cs[o:e+1]
        if 'AppClaim.applyFromFile(' not in br: p2.append('the branch does not call AppClaim.applyFromFile')
        for bad in ('AppHeld.refresh', 'relayNextAlarm'):
            if bad in br: p2.append('the branch calls ' + bad)
        t = re.search(r'new\s+Thread\s*\(', br)
        lam = None
        if t:
            k = re.compile(r'->\s*\{').search(br, t.end())
            if k:
                lo = k.end() - 1; lam = (lo, match(br, lo, '{', '}'))
        if not lam: p3.append('no new Thread( lambda in the branch')
        else:
            c = br.find('AppClaim.applyFromFile(')
            if not (lam[0] < c < lam[1]): p3.append('applyFromFile is not inside the Thread lambda')
            if not re.search(r'finally\s*\{[^{}]*\bfinishUnit\s*\(\s*\)', br[lam[0]:lam[1]+1]):
                p5.append('the worker has no finally calling finishUnit()')
            if not re.search(r'return\s+START_NOT_STICKY\s*;', br[lam[1]:]): p5.append('the branch does not return START_NOT_STICKY after the thread')
    # ---- P4
    p4 = []
    ms = methods(ac, r'\bstatic\b[^;{(=]*\bResult\s+applyFromFile\s*\(')
    if len(ms) != 1: print('CONTROL: applyFromFile not found'); return 2
    s, o, e = ms[0]
    if not re.search(r'\bsynchronized\b', ac[s:o]):
        body = ac[o+1:e].strip()
        mm = re.match(r'synchronized\s*\(\s*[\w.]+\s*\)\s*\{', body)
        if not (mm and match(body, mm.end() - 1, '{', '}') == len(body) - 1):
            p4.append('applyFromFile is neither synchronized nor wholly inside one synchronized block')
    for name, fl in (('P1', p1), ('P2', p2), ('P3', p3), ('P4', p4), ('P5', p5)):
        if fl:
            for f in fl: print('FAIL %s: %s' % (name, f))
            fails.append(name)
        else: print('ok   %s' % name)
    return 1 if fails else 0

def sub1(t, old, new):
    if t.count(old) != 1: return None
    return t.replace(old, new)

KICK = '''                try {
                    appCtx.startServiceAsUser(new android.content.Intent(appCtx, CredentialService.class)
                            .putExtra("claimsLogin", true), android.os.UserHandle.of(fuid));
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "claims-login kick", t); }
'''

def mutate(q, ca, cs, ac, od):
    a = open(ca, encoding='utf-8').read(); s = open(cs, encoding='utf-8').read(); c = open(ac, encoding='utf-8').read()
    if q == 'Q1':
        a = sub1(a, KICK, '')
        if a is not None: a = sub1(a, '                provisionRoamedApps(uid);', KICK + '                provisionRoamedApps(uid);')
    elif q == 'Q2':
        s = sub1(s, 'android.util.Log.i("NowhereChooser", "claims-login apply -> "', 'AppHeld.refresh(this);\n                    android.util.Log.i("NowhereChooser", "claims-login apply -> "')
    elif q == 'Q3':
        s = sub1(s, '''            new Thread(() -> {
                try {
                    AppClaim.Result r''', '''            ((Runnable) () -> {
                try {
                    AppClaim.Result r''')
        if s is not None: s = sub1(s, '}, "nowhere-claims-login").start();', '}).run();')
    elif q == 'Q4':
        c = sub1(c, 'static synchronized Result applyFromFile(', 'static Result applyFromFile(')
    elif q == 'Q5':
        s = sub1(s, 'getBooleanExtra("claimsLogin"', 'getBooleanExtra("claimsLoginX"')
    elif q == 'Q6':
        s = sub1(s, '''                } finally { finishUnit(); }
            }, "nowhere-claims-login")''', '''                }
            }, "nowhere-claims-login")''')
    if a is None or s is None or c is None: return 2
    for n, t in (('A', a), ('S', s), ('C', c)):
        open(os.path.join(od, n + '.java'), 'w', encoding='utf-8').write(t)
    return 0

if __name__ == '__main__':
    try:
        if sys.argv[1] == 'check': rc = check(sys.argv[2], sys.argv[3], sys.argv[4])
        else: rc = mutate(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    except Exception as e:   # a scanner crash is BROKEN (2), never a conviction (1)
        print('CONTROL: scanner error: %r' % (e,)); rc = 2
    sys.exit(rc)
PYEOF

if [ "$1" = "--check-only" ]; then
  python3 -I "$W/scan.py" check "$2" "$3" "$4"
  exit $?
fi

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "FAIL: no shell found"; exit 2; }
BAD=0

for f in "$CA" "$CS" "$AC"; do [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 2; }; done

out=$(python3 -I "$W/scan.py" check "$CA" "$CS" "$AC" 2>&1); rc=$?
echo "$out"
[ $rc -eq 0 ] || BAD=1
for s in $SHELLS; do
  o=$("$s" "$0" --check-only "$CA" "$CS" "$AC" 2>&1); r=$?
  if [ $r -eq 0 ]; then echo "ok   under $s"; else echo "FAIL under $s (rc=$r)"; BAD=1; fi
done

if [ "$1" = "--mutate" ] && [ $BAD -eq 0 ]; then
  for q in Q1 Q2 Q3 Q4 Q5 Q6; do
    d=$(mktemp -d -p "$W") || exit 2
    python3 -I "$W/scan.py" mut "$q" "$CA" "$CS" "$AC" "$d"; mrc=$?
    if [ $mrc -ne 0 ]; then echo "BROKEN $q: mutant did not apply"; BAD=1; continue; fi
    for s in $SHELLS; do
      o=$("$s" "$0" --check-only "$d/A.java" "$d/S.java" "$d/C.java" 2>&1); r=$?
      if [ $r -eq 1 ]; then echo "convicted $q under $s"
      else echo "NOT CONVICTED $q under $s (rc=$r)"; BAD=1; fi
    done
  done
fi

if [ $BAD -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAILED"; exit 1
