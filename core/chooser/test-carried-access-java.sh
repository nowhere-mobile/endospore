#!/usr/bin/env bash
# test-carried-access-java.sh [--mutate] [<CarriedAccess.java> <ProfileActivity.java>] -- the Security screen's list of
# the accessibility services and usage-access apps that travel with the profile, and their off switches
# (NWP-20261207-17): CarriedAccess compiled UNCHANGED under javac and RUN, plus source pins on ProfileActivity.
#
# WHY THIS IS COMMITTED. Backlog row "Security-sensitive appops excluded from the roam"; decision NWP-20261022-31 #39
# (Q024): the Profile screen lists the accessibility and usage-access services that travel with the profile, each with
# an off switch. Both roam exactly as set, captured from the live state at seal, so an off in the live session is what
# stops one travelling. Cases (CarriedAccessCases): C1-C2 services() keeps only app services in roamd's grammar, no
# framework target, no malformed entry, each once; C3-C6 without() drops exactly one entry and keeps every other one,
# framework ones included, "" for the last; anyComponent() (C6, C6b: a framework component left keeps
# accessibility_enabled, though it is never listed); C7-C8 usageLines()/withoutUsage() over real nowhere-perms lines
# (flags: and other appop lines stay byte for byte); C9 the line round trip; C10-C13 usageOff() on a fake phone: an
# install and its restore landing between the screen read and the switch, the live grant and the next capture.
# Pins on ProfileActivity (comments stripped, literals kept, whitespace removed before matching):
#   P1 showSecurity adds the row (label CarriedAccess.ROW_LABEL, action showCarriedAccess) only under `!throwaway`;
#   P2 showCarriedAccess presents at once (LOADING, then finishMenuScreen, outside every lambda, then
#      `screen = shownView`, then the read on CARRIED_ACCESS) and fills only while `shownView == screen`, with no
#      menuScreen/finishMenuScreen/setContentView inside a runOnUiThread;
#   P3 carriedA11yOff puts CarriedAccess.without(...) through Settings.Secure on the session user's own resolver and
#      puts accessibility_enabled 0 only under `!CarriedAccess.anyComponent(next)`;
#   P4 carriedUsageOff runs CarriedAccess.usageOff, whose ops forget through carriedUsageForget, check the uid NOW
#      through getPackageUid and set OPSTR_GET_USAGE_STATS to MODE_IGNORED;
#   P5 carriedUsageForget reads, edits and writeAtomic's nowhere-perms inside synchronized (PERMS_CAPTURE_LOCK), and
#      writes nothing when the read is null;
#   P6 no log line of the new methods names a package, component, label or title;
#   P7 every usage row's switch runs carriedUsageOff: showCarriedAccess never calls carriedUsageForget itself.
# What it does NOT prove: the handset run (enable a screen reader and usage access, see both listed, switch each off,
# save, sign in again, both stay off) -- the chooser cannot be compiled off the build host.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC OR NO PYTHON3, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-carried-access-java.sh            # the cases and the pins
#   bash test-carried-access-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CA="$HERE/src/com/nowhere/chooser/CarriedAccess.java"
PA="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
CASES="$HERE/tests/carried-access/CarriedAccessCases.java"
MUTATE=no
pos=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) pos+=("$a") ;; esac; done
[ "${#pos[@]}" -ge 1 ] && CA="${pos[0]}"
[ "${#pos[@]}" -ge 2 ] && PA="${pos[1]}"
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
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 2; }
"$JAVAC" -version >/dev/null 2>&1 || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$CA" "$PA" "$CASES"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# One root for everything this suite creates (each compile, the scanner, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

cat > "$W/pins.py" <<'PYEOF'
import re, sys

def lit_end(src, i):
    """Index just past the string/char literal opening at i."""
    if src[i:i+3] == '"""':
        j = src.find('"""', i + 3); return len(src) if j < 0 else j + 3
    c = src[i]; j = i + 1
    while j < len(src) and src[j] != c:
        j += 2 if src[j] == '\\' else 1
    return j + 1

def strip(src):
    """Comments out, literals kept verbatim."""
    out = []; i = 0; n = len(src)
    while i < n:
        d = src[i:i+2]
        if d == '//':
            while i < n and src[i] != '\n': i += 1
        elif d == '/*':
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(' ')
        elif src[i] in '"\'':
            e = lit_end(src, i); out.append(src[i:e]); i = e
        else:
            out.append(src[i]); i += 1
    return ''.join(out)

def match(code, i, o, c):
    d = 0; j = i
    while j < len(code):
        ch = code[j]
        if ch in '"\'': j = lit_end(code, j); continue
        if ch == o: d += 1
        elif ch == c:
            d -= 1
            if d == 0: return j
        j += 1
    return -1

def stmt_end(code, i):
    d = 0; j = i
    while j < len(code):
        ch = code[j]
        if ch in '"\'': j = lit_end(code, j); continue
        if ch in '({[': d += 1
        elif ch in ')}]': d -= 1
        elif ch == ';' and d == 0: return j
        j += 1
    return -1

def norm(s): return re.sub(r'\s+', '', s)

def ifs(code):
    """(normalised condition, start, end) of every `if (...)` span: its braced block or its single statement."""
    res = []
    for m in re.finditer(r'\bif\s*\(', code):
        po = m.end() - 1; pc = match(code, po, '(', ')')
        if pc < 0: continue
        k = pc + 1
        while k < len(code) and code[k].isspace(): k += 1
        e = match(code, k, '{', '}') if code[k:k+1] == '{' else stmt_end(code, k)
        if e > 0: res.append((norm(code[po+1:pc]), k, e))
    return res

def innermost(spans, i):
    g = [s for s in spans if s[1] <= i <= s[2]]
    return min(g, key=lambda s: s[2] - s[1]) if g else None

def method(code, name):
    """The body (between its braces) of the method `name`, or None."""
    m = re.search(r'private\s+[\w.<>\[\]]+\s+' + name + r'\s*\(', code)
    if not m: return None
    pc = match(code, m.end() - 1, '(', ')')
    if pc < 0: return None
    o = code.find('{', pc)
    e = match(code, o, '{', '}')
    return None if o < 0 or e < 0 else code[o + 1:e]

def spans_of(nb, tok):
    """[start, end] of each call `tok(` ... `)` in the normalised text."""
    res = []
    for m in re.finditer(re.escape(tok), nb):
        po = m.end() - 1; pc = match(nb, po, '(', ')')
        if pc > 0: res.append((m.start(), pc))
    return res

def inside(sp, i): return any(a <= i <= b for a, b in sp)

def check(pa):
    code = strip(open(pa, encoding='utf-8').read())
    res = {}

    # P1
    fl = []
    body = method(code, 'showSecurity')
    if body is None: fl.append('showSecurity not found')
    else:
        spans = ifs(body)
        for tok in ('labels.add(CarriedAccess.ROW_LABEL)', 'actions.add(()->showCarriedAccess())'):
            hits = [mm.start() for mm in re.finditer(r'\s*'.join(map(re.escape, tok)), body)]
            if len(hits) != 1: fl.append('%s appears %d times, want 1' % (tok, len(hits))); continue
            g = innermost(spans, hits[0])
            if g is None: fl.append('%s is unconditional, want if (!throwaway)' % tok)
            elif g[0] != '!throwaway': fl.append('%s is under if (%s), want if (!throwaway)' % (tok, g[0]))
    res['P1 the Security row is added only under !throwaway'] = fl

    # P2
    fl = []
    body = method(code, 'showCarriedAccess')
    if body is None: fl.append('showCarriedAccess not found')
    else:
        nb = norm(body)
        ex = spans_of(nb, 'CARRIED_ACCESS.execute(')
        ui = spans_of(nb, 'runOnUiThread(')
        lam = ex + ui
        fms = [m.start() for m in re.finditer(re.escape('finishMenuScreen(ll,this::showSecurity)'), nb)]
        if len(ex) != 1: fl.append('CARRIED_ACCESS.execute( appears %d times, want 1' % len(ex))
        if len(fms) != 1: fl.append('finishMenuScreen(ll, this::showSecurity) appears %d times, want 1' % len(fms))
        if len(ex) == 1 and len(fms) == 1:
            f, x = fms[0], ex[0]
            if inside(lam, f): fl.append('(a) finishMenuScreen is inside a lambda: the screen waits for the read')
            if not f < x[0]: fl.append('(a) finishMenuScreen is not before CARRIED_ACCESS.execute(')
            ld = nb.find('CarriedAccess.LOADING')
            if ld < 0 or not ld < f: fl.append('(b) CarriedAccess.LOADING is not shown before finishMenuScreen')
            sc = nb.find('screen=shownView;')
            if sc < 0 or not (f < sc < x[0]): fl.append('(c) screen = shownView is not between finishMenuScreen and the read')
            rd = nb.find('CarriedAccess.services(')
            if rd < 0 or not inside(ex, rd): fl.append('(d) the read (CarriedAccess.services) is not on CARRIED_ACCESS')
            inner = [s for s in ui if x[0] <= s[0] <= x[1]]
            if len(inner) != 1: fl.append('(e) the read posts %d runOnUiThread, want 1' % len(inner))
            else:
                a, b = inner[0]; seg = nb[a:b + 1]
                g = seg.find('if(shownView!=screen)return;')
                adds = [i for i in (seg.find('addView('), seg.find('removeAllViews(')) if i >= 0]
                if g < 0: fl.append('(e) the fill does not check shownView != screen')
                elif adds and min(adds) < g: fl.append('(e) the fill touches a view before the still-shown check')
        for a, b in ui:
            seg = nb[a:b + 1]
            for bad in ('menuScreen(', 'finishMenuScreen(', 'setContentView('):
                if bad in seg: fl.append('(f) %s inside a runOnUiThread' % bad)
    res['P2 the screen is presented at once and filled only while shown'] = fl

    # P3
    fl = []
    body = method(code, 'carriedA11yOff')
    if body is None: fl.append('carriedA11yOff not found')
    else:
        nb = norm(body)
        for tok in ('cr=getContentResolver();', 'next=CarriedAccess.without(cur,component);',
                    'android.provider.Settings.Secure.putString(cr,"enabled_accessibility_services",next)'):
            if tok not in nb: fl.append('missing %s' % tok)
        if 'createContextAsUser' in nb: fl.append('the off writes through createContextAsUser, not the session user')
        spans = ifs(body)
        hits = [m.start() for m in re.finditer(r'putString\s*\(\s*cr\s*,\s*"accessibility_enabled"\s*,\s*"0"\s*\)', body)]
        if len(hits) != 1: fl.append('the accessibility_enabled 0 put appears %d times, want 1' % len(hits))
        else:
            g = innermost(spans, hits[0])
            if g is None or '!CarriedAccess.anyComponent(next)' not in g[0]:
                fl.append('accessibility_enabled 0 is under if (%s), want !CarriedAccess.anyComponent(next)'
                          % (g[0] if g else 'nothing'))
    res['P3 the a11y off edits the session user list and clears accessibility_enabled only on an empty list'] = fl

    # P4
    fl = []
    body = method(code, 'carriedUsageOff')
    if body is None: fl.append('carriedUsageOff not found')
    else:
        nb = norm(body)
        sm = [nb[a:b + 1] for a, b in spans_of(nb, 'setMode(')]
        if len(sm) != 1: fl.append('setMode( appears %d times, want 1' % len(sm))
        elif sm[0] != 'setMode(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,uid,pkg,android.app.AppOpsManager.MODE_IGNORED)':
            fl.append('the usage off is %s, want OPSTR_GET_USAGE_STATS to MODE_IGNORED' % sm[0])
        for tok in ('returnCarriedAccess.usageOff(newCarriedAccess.UsageOps(){',
                    'publicbooleanforget(){returncarriedUsageForget(pkg);}',
                    'try{returngetPackageManager().getPackageUid(pkg,0);}',
                    'catch(PackageManager.NameNotFoundExceptione){return-1;}'):
            if tok not in nb: fl.append('missing %s' % tok)
    res['P4 the usage off sets MODE_IGNORED'] = fl

    # P5
    fl = []
    body = method(code, 'carriedUsageForget')
    if body is None: fl.append('carriedUsageForget not found')
    else:
        nb = norm(body)
        k = nb.find('synchronized(PERMS_CAPTURE_LOCK){')
        if k < 0: fl.append('no synchronized (PERMS_CAPTURE_LOCK)')
        else:
            o = k + len('synchronized(PERMS_CAPTURE_LOCK)'); e = match(nb, o, '{', '}')
            for tok in ('SettingsText.read(', 'CarriedAccess.withoutUsage(', 'StoreInstaller.writeAtomic('):
                i = nb.find(tok)
                if i < 0: fl.append('missing %s' % tok)
                elif not (o < i < e): fl.append('%s is outside synchronized (PERMS_CAPTURE_LOCK)' % tok)
            n0 = nb.find('if(text==null)returnfalse;'); wa = nb.find('StoreInstaller.writeAtomic(')
            if n0 < 0 or not (o < n0 < wa): fl.append('an unreadable nowhere-perms does not return false before the write')
    res['P5 the perms edit holds PERMS_CAPTURE_LOCK and writes with writeAtomic'] = fl

    # P6
    fl = []
    for name in ('showCarriedAccess', 'carriedRow', 'carriedA11yOff', 'carriedUsageOff', 'carriedUsageForget'):
        body = method(code, name)
        if body is None: fl.append('%s not found' % name); continue
        nb = norm(body)
        for m in re.finditer(r'\bLog\.\w+\(', nb):
            pc = match(nb, m.end() - 1, '(', ')'); args = nb[m.end():pc]
            for bad in ('component', 'pkg', 'label', 'title', 'r[0]', 'r[1]'):
                if bad in re.sub(r'"(?:[^"\\]|\\.)*"', '""', args): fl.append('%s logs %s' % (name, bad))
    res['P6 no log line names a package, component, label or title'] = fl

    # P7
    fl = []
    body = method(code, 'showCarriedAccess')
    if body is None: fl.append('showCarriedAccess not found')
    else:
        nb = norm(body)
        if 'carriedUsageForget(' in nb: fl.append('a row calls carriedUsageForget, which never revokes a live grant')
        n = nb.count('()->carriedUsageOff(r[0])')
        if n != 1: fl.append('()->carriedUsageOff(r[0]) appears %d times, want 1 (every usage row)' % n)
    res['P7 every usage row switches off through carriedUsageOff'] = fl

    bad = 0
    for k, v in res.items():
        if v:
            print('--- FAIL: pin: %s: %s' % (k, '; '.join(v))); bad = 1
        else: print('--- PASS: pin: %s' % k)
    return bad

if __name__ == '__main__':
    try: rc = check(sys.argv[1])
    except Exception as e:   # a scanner crash is BROKEN (2), never a conviction (1)
        print('CONTROL: scanner error: %r' % (e,)); rc = 2
    sys.exit(rc)
PYEOF

# suite <CarriedAccess.java> <ProfileActivity.java> -> 0 pass, 1 a case or pin failed (only this may convict),
# 3 no compile / no run.
suite() {
  local d rc prc
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$1" "$d/src/com/nowhere/chooser/CarriedAccess.java"
  if ! "$JAVAC" -nowarn -d "$d/out" "$d/src/com/nowhere/chooser/CarriedAccess.java" "$CASES" 2>&1; then
    echo "COMPILE FAILED"; return 3
  fi
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.CarriedAccessCases; rc=$?
  [ "$rc" -le 1 ] || return 3
  python3 -I "$W/pins.py" "$2"; prc=$?
  [ "$prc" -le 1 ] || return 3
  [ "$rc" -eq 0 ] && [ "$prc" -eq 0 ] && return 0
  return 1
}

echo "== $CA + $PA"
out=$(suite "$CA" "$PA" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 2; }
echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
mut() { # mut <label> <kind: ca|pa> <convicting assertion> <perl-expr>
  local d m rc o orig c p
  d=$(mktemp -d -p "$W") || return 1
  c="$CA"; p="$PA"
  case "$2" in
    ca) orig="$CA"; m="$d/CarriedAccess.java"; c="$m" ;;
    pa) orig="$PA"; m="$d/ProfileActivity.java"; p="$m" ;;
    *) echo "  ERROR     $1 -- unknown mutant kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$4" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  o=$(suite "$c" "$p" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL: $3"* ]]; then echo "  convicted $1 (by $3)"; return 0
       else echo "  BROKEN    $1 -- failed, but not by $3:"; printf '%s\n' "$o" | grep -- '--- FAIL'; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the row shown for a throwaway" pa "pin: P1" \
  's/if \(!throwaway\) \{ (labels\.add\(CarriedAccess\.ROW_LABEL\); actions\.add\(\(\) -> showCarriedAccess\(\)\);) \}/$1/' \
  || fails=$((fails+1))
mut "M2 framework entries listed" ca "C1" \
  's/\n\s*if \(FRAMEWORK_PKG\.equals\(p\)\) continue;//' || fails=$((fails+1))
mut "M3 without() drops the framework entries too" ca "C3" \
  's/if \(e\.equals\(component\)\) continue;/if (e.equals(component) || e.startsWith(FRAMEWORK_PKG)) continue;/' \
  || fails=$((fails+1))
mut "M4 withoutUsage drops another appop line" ca "C8" \
  's/if \(!ln\.equals\(pkg \+ USAGE_SUFFIX\)\)/if (!ln.startsWith(pkg + " appop:"))/' || fails=$((fails+1))
mut "M5 accessibility_enabled 0 on a non-empty list" pa "pin: P3" \
  's/if \(ok && !CarriedAccess\.anyComponent\(next\)\)/if (ok)/' || fails=$((fails+1))
mut "M6 the perms edit outside the lock" pa "pin: P5" \
  's/synchronized \(PERMS_CAPTURE_LOCK\) \{(\n\s*java\.io\.File f = new java\.io\.File\(getFilesDir\(\), "nowhere-perms"\);)/{$1/' \
  || fails=$((fails+1))
mut "M7 the usage off sets MODE_ALLOWED" pa "pin: P4" \
  's/(\(android\.app\.AppOpsManager\.OPSTR_GET_USAGE_STATS, uid, pkg, android\.app\.AppOpsManager\.)MODE_IGNORED/$1MODE_ALLOWED/' \
  || fails=$((fails+1))
mut "M8 a late read fills any screen" pa "pin: P2" \
  's/\n\s*if \(shownView != screen\) return;\n\s*a11yBody\.removeAllViews\(\);/\n                a11yBody.removeAllViews();/' \
  || fails=$((fails+1))
mut "M9 the screen presented only after the read" pa "pin: P2" \
  's/\n        finishMenuScreen\(ll, this::showSecurity\);(.*?if \(shownView != screen\) return;\n)/$1                finishMenuScreen(ll, this::showSecurity);\n/s' \
  || fails=$((fails+1))
mut "M10 a placeholder row only edits nowhere-perms" pa "pin: P7" \
  's/carriedRow\(r\[1\], r\[2\], "usage", \(\) -> carriedUsageOff\(r\[0\]\)\)/r[2] == null ? carriedRow(r[1], null, "usage", () -> carriedUsageOff(r[0])) : carriedRow(r[1], r[2], "usage-carried", () -> carriedUsageForget(r[0]))/' \
  || fails=$((fails+1))
mut "M11 usageOff trusts the screen read, no installation recheck" ca "C10" \
  's/int uid = ops\.uid\(\);\n\s*if \(uid < 0\) return forgot;/if (forgot) return true;\n        int uid = ops.uid();/' \
  || fails=$((fails+1))
mut "M12 anyComponent applies the display filter" ca "C6" \
  's/(if \(PKG_RE\.matcher\(e\.substring\(0, s\)\)\.matches\(\))/if (FRAMEWORK_PKG.equals(e.substring(0, s))) continue;\n            $1/' \
  || fails=$((fails+1))
mut "M13 the off checks the uid before it forgets the line" ca "C13" \
  's/boolean forgot = ops\.forget\(\);\n(\s*)int uid = ops\.uid\(\);\n\s*if \(uid < 0\) return forgot;/int uid = ops.uid();\n$1if (uid < 0) return ops.forget();\n$1boolean forgot = ops.forget();/' \
  || fails=$((fails+1))
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails mutant(s) not convicted"; exit 1; fi
echo "PASS: every mutant convicted"
