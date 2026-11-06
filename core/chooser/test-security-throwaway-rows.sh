#!/usr/bin/env bash
# test-security-throwaway-rows.sh [--mutate] -- a throwaway's Security screen lists no standby or wipe control and
# says it runs on the standard times; an offline stored session keeps both.
#
# WHY THIS IS COMMITTED. Backlog row "A throwaway session's Security screen offers "Auto standby when idle" and
# "Auto-wipe when left locked", but changing either does nothing" (NWP-20261112-22 builds the throwaway half). The
# gate reads both values only at sign-in (ChooserActivity.applyRoamedPrefs) and a throwaway is never signed into
# again, so the two pickers saved a choice nothing read. An OFFLINE sign-in of a stored profile reports LOCAL too,
# so the guard is `local && !offlineSession`, the Profile menu's rule. Pinned in ProfileActivity.showSecurity:
#   s1 `final boolean throwaway = local && !offlineSession;` (and `local` is still "LOCAL".equals(sessionType));
#   s2 the "Auto standby when idle" row (label and showIdlePicker action) is added only under `!throwaway`;
#   s3 the "Auto-wipe when left locked" row (label and showWipePicker action) likewise;
#   s4 the "Always-on VPN" row (label and showVpnPicker action) is under no `if`;
#   s5 the note "This session isn't saved, so it uses the standard standby and wipe times." is set once, only under
#      `throwaway`, MUTED at 13 sp and added to the screen, between sectionCard( and finishMenuScreen(;
#   s6 Change passphrase (`!local && name != null`), Use a security key, Session PIN and Tie to this phone (`!local`)
#      keep their guards.
# All in FUNCTIONAL form: comments are stripped (string literals kept, they are what is matched) before any match,
# and the method and every `if` span are found by string-aware bracket matching. python3 is required and the suite
# FAILS without it.
#
# Mutants (each must be CONVICTED under every shell found of bash, sh, dash, mksh; one that does not apply is a
# failure): M1 the idle row's guard removed; M2 the wipe row's guard removed; M3 the VPN row guarded; M4 the note's
# condition inverted; M5 the note's text changed; M6 `&& !offlineSession` dropped from throwaway.
#
#   bash test-security-throwaway-rows.sh            # the pins
#   bash test-security-throwaway-rows.sh --mutate   # ... plus the mutants
# Override the source with SECROWS_PA.

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
PA=${SECROWS_PA:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 2; }

cat > "$W/scan.py" <<'PYEOF'
import re, sys, os

NOTE = "This session isn't saved, so it uses the standard standby and wipe times."

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
    """Index of the `;` ending the statement starting at i (depth 0)."""
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

def guards(spans, i):
    return [s for s in spans if s[1] <= i <= s[2]]

def innermost(spans, i):
    g = guards(spans, i)
    return min(g, key=lambda s: s[2] - s[1]) if g else None

def check(pa):
    code = strip(open(pa, encoding='utf-8').read())
    m = re.search(r'private\s+void\s+showSecurity\s*\(\s*\)\s*\{', code)
    if not m: print('CONTROL: showSecurity not found'); return 2
    o = m.end() - 1; e = match(code, o, '{', '}')
    if e < 0: print('CONTROL: showSecurity body unmatched'); return 2
    body = code[o + 1:e]
    nb = norm(body)
    spans = ifs(body)
    res = {}

    def row(label, action, want):
        """The row's label and its action are each added once, and each sits innermost under `want` (None = no if)."""
        fl = []
        for tok in ('labels.add("%s")' % label, 'actions.add(()->%s())' % action):
            hits = [mm.start() for mm in re.finditer(r'\s*'.join(map(re.escape, tok)), body)]
            if len(hits) != 1: fl.append('%s appears %d times, want 1' % (tok, len(hits))); continue
            g = innermost(spans, hits[0])
            if want is None:
                if guards(spans, hits[0]): fl.append('%s is under if (%s)' % (tok, g[0]))
            elif g is None: fl.append('%s is unconditional, want if (%s)' % (tok, want))
            elif g[0] != want: fl.append('%s is under if (%s), want if (%s)' % (tok, g[0], want))
        return fl

    # s1
    fl = []
    if nb.count('finalbooleanthrowaway=local&&!offlineSession;') != 1:
        fl.append('throwaway is not defined once as `local && !offlineSession`')
    if nb.count('finalbooleanlocal="LOCAL".equals(sessionType);') != 1:
        fl.append('control: local is not "LOCAL".equals(sessionType)')
    res['s1'] = fl
    res['s2'] = row('Auto standby when idle', 'showIdlePicker', '!throwaway')
    res['s3'] = row('Auto-wipe when left locked', 'showWipePicker', '!throwaway')
    res['s4'] = row('Always-on VPN', 'showVpnPicker', None)
    # s5
    fl = []
    lit = '"' + NOTE.replace('\\', '\\\\').replace('"', '\\"') + '"'
    hits = [mm.start() for mm in re.finditer(re.escape(lit), body)]
    if len(hits) != 1: fl.append('the note text appears %d times, want 1' % len(hits))
    else:
        h = hits[0]
        sm = re.search(r'(\w+)\s*\.\s*setText\s*\(\s*$', body[:h])
        g = innermost(spans, h)
        if not sm: fl.append('the note text is not the argument of a .setText(')
        if g is None: fl.append('the note is unconditional, want if (throwaway)')
        elif g[0] != 'throwaway': fl.append('the note is under if (%s), want if (throwaway)' % g[0])
        if sm and g is not None:
            v = re.escape(sm.group(1)); blk = norm(body[g[1]:g[2] + 1])
            if not re.search(v + r'\.setTextSize\(TypedValue\.COMPLEX_UNIT_SP,13\);', blk): fl.append('the note is not 13 sp')
            if not re.search(v + r'\.setTextColor\(MUTED\);', blk): fl.append('the note is not MUTED')
            if not re.search(r'll\.addView\(' + v + r'[,)]', blk): fl.append('the note is never added to the screen')
            sc = body.find('sectionCard('); fm = body.find('finishMenuScreen(')
            if sc < 0 or fm < 0: fl.append('control: sectionCard( or finishMenuScreen( missing')
            elif not (sc < g[1] and g[2] < fm): fl.append('the note block is not between sectionCard( and finishMenuScreen(')
    res['s5'] = fl
    # s6
    fl = []
    for label, action, want in (('Use a security key', 'showAddSecurityKey', '!local'),
                                ('Session PIN', 'showSessionPin', '!local'),
                                ('Tie to this phone', 'showPhoneTie', '!local')):
        fl += row(label, action, want)
    cp = [mm.start() for mm in re.finditer(re.escape('labels.add("Change passphrase")'), body)]
    ca = [mm.start() for mm in re.finditer(r'actions\.add\(\s*\(\s*\)\s*->\s*showChangePass\s*\(\s*name\s*\)\s*\)', body)]
    for what, hs in (('Change passphrase label', cp), ('showChangePass(name) action', ca)):
        if len(hs) != 1: fl.append('%s appears %d times, want 1' % (what, len(hs))); continue
        g = innermost(spans, hs[0])
        if g is None or g[0] != '!local&&name!=null':
            fl.append('%s is under if (%s), want if (!local && name != null)' % (what, g[0] if g else 'nothing'))
    res['s6'] = fl

    bad = 0
    for k in ('s1', 's2', 's3', 's4', 's5', 's6'):
        if res[k]:
            for f in res[k]: print('FAIL %s: %s' % (k, f))
            bad = 1
        else: print('ok   %s' % k)
    return bad

def sub1(t, old, new):
    if t.count(old) != 1: return None
    return t.replace(old, new)

def mutate(q, pa, out):
    t = open(pa, encoding='utf-8').read(); n = None
    if q == 'M1':
        n = sub1(t, 'if (!throwaway) { labels.add("Auto standby when idle");', '{ labels.add("Auto standby when idle");')
    elif q == 'M2':
        n = sub1(t, 'if (!throwaway) { labels.add("Auto-wipe when left locked");', '{ labels.add("Auto-wipe when left locked");')
    elif q == 'M3':
        n = sub1(t, 'labels.add("Always-on VPN");                actions.add(() -> showVpnPicker());',
                 'if (!throwaway) { labels.add("Always-on VPN"); actions.add(() -> showVpnPicker()); }')
    elif q == 'M4':
        n = sub1(t, '        if (throwaway) {\n            TextView note', '        if (!throwaway) {\n            TextView note')
    elif q == 'M5':
        n = sub1(t, 'so it uses the standard standby and wipe times."', 'so it uses the default standby and wipe times."')
    elif q == 'M6':
        n = sub1(t, 'final boolean throwaway = local && !offlineSession;', 'final boolean throwaway = local;')
    if n is None: return 2
    open(out, 'w', encoding='utf-8').write(n)
    return 0

if __name__ == '__main__':
    try:
        if sys.argv[1] == 'check': rc = check(sys.argv[2])
        else: rc = mutate(sys.argv[2], sys.argv[3], sys.argv[4])
    except Exception as e:   # a scanner crash is BROKEN (2), never a conviction (1)
        print('CONTROL: scanner error: %r' % (e,)); rc = 2
    sys.exit(rc)
PYEOF

if [ "$1" = "--check-only" ]; then
  python3 -I "$W/scan.py" check "$2"
  exit $?
fi

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "FAIL: no shell found"; exit 2; }
BAD=0

[ -r "$PA" ] || { echo "FAIL: cannot read $PA"; exit 2; }

out=$(python3 -I "$W/scan.py" check "$PA" 2>&1); rc=$?
echo "$out"
[ $rc -eq 0 ] || BAD=1
for s in $SHELLS; do
  o=$("$s" "$0" --check-only "$PA" 2>&1); r=$?
  if [ $r -eq 0 ]; then echo "ok   under $s"; else echo "FAIL under $s (rc=$r)"; BAD=1; fi
done

if [ "$1" = "--mutate" ] && [ $BAD -eq 0 ]; then
  for q in M1 M2 M3 M4 M5 M6; do
    f=$(mktemp -p "$W") || exit 2
    python3 -I "$W/scan.py" mut "$q" "$PA" "$f"; mrc=$?
    if [ $mrc -ne 0 ]; then echo "BROKEN $q: mutant did not apply"; BAD=1; continue; fi
    for s in $SHELLS; do
      o=$("$s" "$0" --check-only "$f" 2>&1); r=$?
      if [ $r -eq 1 ]; then echo "convicted $q under $s"
      else echo "NOT CONVICTED $q under $s (rc=$r)"; BAD=1; fi
    done
  done
fi

if [ $BAD -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAILED"; exit 1
