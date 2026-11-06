#!/usr/bin/env bash
# test-nfc-shuttle-java.sh [--mutate] -- NWP-20261020-22: the gate's NFC security-key APDU shuttle. Runs
# core/chooser/tests/nfc-shuttle: NfcShuttle.run's lazy connect, setTimeout-always, fail-fast, reply mapping and
# malformed-APDU refusal, compiled and EXECUTED against a recording fake tap.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# NWP-20261109-05 adds the lost-link mapping (NfcShuttle.LINK_LOST: a drop inside the exchange, told apart from the
# daemon's bare ERR), the NfcTapVerdict texts the gate paints for a failed tap (the resume never blames the entry;
# the fresh gate's lines are unchanged), and a source pin: gateNfcResult calls NfcTapVerdict.failText and holds no
# `.contains("` of its own, and RESUME_KEY_FAIL equals the NEEDKEY text of ChooserActivity.resume up to "no rush."
# (its `v.kind == ResumeReply.NEEDKEY` arm since NWP-20261109-19).
# NWP-20261127-18 widens the refusal to any APDU that is not even-length ASCII hex (N7-N10).
# Everything the suite creates lives under one root removed on exit.
#
# --mutate re-runs the suite against broken copies of NfcShuttle.java, NfcTapVerdict.java and ChooserActivity.java
# (M1-M6, N1-N10), each of which must FAIL. A mutant that does not
# apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-nfc-shuttle-java.sh            # the cases
#   bash test-nfc-shuttle-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-nfc-shuttle-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
CH=core/chooser/src/com/nowhere/chooser
command -v python3 >/dev/null 2>&1 || { echo "FAIL: this suite needs python3 for the source pin, and there is none" >&2; exit 1; }
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/nfc-shuttle/run.sh" "$1" "$W"; }

# pin <root>: the source pin over <root>/$CH. Prints FAIL pin lines and returns non-zero on a miss.
pin() {
  python3 -I - "$1/$CH" <<'PY'
import re, sys
d = sys.argv[1]
fails = []
def fail(m): fails.append("FAIL pin: " + m)

def strip_comments(t):
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c in '"\'':
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == '\\' else 1
            out.append(t[i:j + 1]); i = j + 1
        elif t.startswith('//', i):
            while i < n and t[i] != '\n': i += 1
        elif t.startswith('/*', i):
            k = t.find('*/', i + 2)
            i = n if k < 0 else k + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def lits(t):
    return ''.join(m.group(1).replace('\\n', '\n').replace('\\u2014', '—') for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', t))

act = open(d + '/ChooserActivity.java', encoding='utf-8').read()
ver = open(d + '/NfcTapVerdict.java', encoding='utf-8').read()

a = act.find('private NfcFido2.Result gateNfcResult()')
b = act.find('private void disarmGateNfc()')
if a < 0 or b < a:
    fail("gateNfcResult not found")
else:
    g = act[a:b]
    if 'NfcTapVerdict.failText(resumeMode, detail)' not in g: fail("gateNfcResult does not call NfcTapVerdict.failText(resumeMode, detail)")
    if '.contains("' in g: fail('gateNfcResult holds a .contains(" of its own')

# resume() reads the RESUME reply through ResumeReply.of (NWP-20261109-19), so its NEEDKEY arm is the one
# `v.kind == ResumeReply.NEEDKEY` branch.
if act.count('v.kind == ResumeReply.NEEDKEY') != 1: fail('ChooserActivity does not hold exactly one v.kind == ResumeReply.NEEDKEY')
r0 = act.find('private void resume(final String pass, final boolean keyAlreadyAsserted)')
if r0 < 0:
    fail("resume() not found")
else:
    st = strip_comments(act[r0:])
    k = st.find('else if (v.kind == ResumeReply.NEEDKEY)')
    if k < 0:
        fail("the NEEDKEY arm of resume() not found")
    else:
        e = st.find('else if', k + 10)
        arm = st[k:e if e > 0 else len(st)]
        s0 = arm.find('result.setText(')
        if s0 < 0:
            fail("the NEEDKEY arm has no result.setText(")
        else:
            depth, j, q = 0, s0 + len('result.setText'), None
            while j < len(arm):
                c = arm[j]
                if q:
                    if c == '\\': j += 1
                    elif c == q: q = None
                elif c in '"\'': q = c
                elif c == '(': depth += 1
                elif c == ')':
                    depth -= 1
                    if depth == 0: break
                j += 1
            need = lits(arm[s0:j])
            if "no rush." not in need:
                fail('the NEEDKEY text is empty or lacks "no rush."')
            else:
                m = re.search(r'RESUME_KEY_FAIL\s*=([^;]*);', strip_comments(ver))
                rk = lits(m.group(1)) if m else ''
                if not rk: fail("RESUME_KEY_FAIL not found or empty")
                elif rk != need[:need.index("no rush.") + len("no rush.")]:
                    fail("RESUME_KEY_FAIL differs from the NEEDKEY text up to 'no rush.': %r" % rk)
for f in fails: print(f)
if not fails: print("pin: ok")
sys.exit(1 if fails else 0)
PY
}

run "$ROOT" || { echo "FAILED"; exit 1; }
pin "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <file> <label> <python-regex> <replacement>
  local d out rc f n r1 r2
  f=$1
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in NfcShuttle.java NfcTapVerdict.java ChooserActivity.java; do cp "$ROOT/$CH/$n" "$d/$CH/"; done
  if ! python3 -I - "$d/$CH/$f" "$3" "$4" <<'PY'; then echo "  INERT     $2 -- the mutation did not apply"; rm -rf "$d"; return 1; fi
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p,encoding='utf-8').read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w',encoding='utf-8').write(n)
PY
  out=$( { run "$d"; r1=$?; pin "$d"; r2=$?; [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ]; } 2>&1 ); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $2"; return 1; fi
  if grep -q 'error:' <<<"$out"; then echo "  BROKEN    $2 -- it did not compile"; return 1; fi
  if ! grep -q '^FAIL ' <<<"$out"; then echo "  BROKEN    $2 -- it failed, but no case reported FAIL (rc=$rc)"; return 1; fi
  echo "  convicted $2"
}
fails=0
S=NfcShuttle.java; V=NfcTapVerdict.java
mut $S "M1 linkDead is never set" 'linkDead = true; // NWP-20260825-01[^\n]*\n' '' || fails=$((fails+1))
mut $S "M2 connect hoisted above the loop" '(String line;\n)' 'tap.connect(); tap.setTimeout(apduTimeoutMs);\n        \1' || fails=$((fails+1))
mut $S "M3 setTimeout only on the connect branch" 'if \(!tap\.isConnected\(\)\) tap\.connect\(\);[^\n]*\n\s*tap\.setTimeout\(apduTimeoutMs\);' 'if (!tap.isConnected()) { tap.connect(); tap.setTimeout(apduTimeoutMs); }' || fails=$((fails+1))
mut $S "M4 OK and ERR swapped" 'startsWith\("OK"\)\) \{\n\s*return new String\[\]\{"OK", line\};(.*?)return new String\[\]\{"ERR", tagFailed \? LINK_LOST : line\};' 'startsWith("OK")) {\n                return new String[]{"ERR", line};\1return new String[]{"OK", line};' || fails=$((fails+1))
mut $S "M5 bytesToHex upper-case" '"0123456789abcdef"' '"0123456789ABCDEF"' || fails=$((fails+1))
mut $S "M6 the malformed-APDU guard removed" '!isHexApdu\(hex\)' 'false' || fails=$((fails+1))
mut $S "N1 the malformed-APDU guard also sets tagFailed" '(linkDead = true;\n)(\s*)(log\.warn\("nfc: malformed APDU refused)' '\1\2tagFailed = true;\n\2\3' || fails=$((fails+1))
mut $S "N2 LINK_LOST returned even when the daemon said OK" '(return new String\[\]\{"OK", line\};)' 'if (tagFailed) return new String[]{"ERR", LINK_LOST};\n                \1' || fails=$((fails+1))
mut $V "N3 resume treats LINK_LOST as a plain ERR" '(if \(NfcShuttle\.LINK_LOST\.equals\(detail\)\) return )DROP_LINE;' '\1RESUME_KEY_FAIL;' || fails=$((fails+1))
mut $V "N4 the resume ERR text is today's check-your-PIN line" '(RESUME_KEY_FAIL = )"[^;]*;' '\1"Couldn'"'"'t sign in with that key — check your PIN and try again.";' || fails=$((fails+1))
mut $V "N5 the fresh gate's LINK_LOST test removed" 'if \(NfcShuttle\.LINK_LOST\.equals\(detail\)\) return FRESH_FAIL;' '' || fails=$((fails+1))
mut ChooserActivity.java "N6 gateNfcResult's failText call replaced by a literal" 'NfcTapVerdict\.failText\(resumeMode, detail\)' '"Couldn'"'"'t sign in with that key."' || fails=$((fails+1))
mut $S "N7 isHexApdu checks only the length" '\n\s*for \(int i = 0; i < hex\.length\(\); i\+\+\) \{\n\s*if \(nibble\(hex\.charAt\(i\)\) < 0\) return false;\n\s*\}' '' || fails=$((fails+1))
mut $S "N8 the guard moved below the lazy connect" '(\n\s*if \(!isHexApdu\(hex\)\) \{.*?continue;\n\s*\})(\n\s*if \(!connected\) \{.*?connected = true;[^\n]*\n(?:\s*//[^\n]*\n)*\s*\})' '\2\1' || fails=$((fails+1))
mut $S "N9 hexToBytes back to Integer.parseInt, isHexApdu length-only" '\n\s*for \(int i = 0; i < hex\.length\(\); i\+\+\) \{\n\s*if \(nibble\(hex\.charAt\(i\)\) < 0\) return false;\n\s*\}(.*?)int hi = nibble\(h\.charAt\(2 \* i\)\), lo = nibble\(h\.charAt\(2 \* i \+ 1\)\);\n\s*if \(hi < 0 \|\| lo < 0\) throw [^\n]*\n\s*b\[i\] = \(byte\) \(\(hi << 4\) \| lo\);' '\1b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);' || fails=$((fails+1))
mut $S "N10 nibble is Character.digit (takes non-ASCII digits)" '(private static int nibble\(char c\) \{\n).*?(\n    \})' '\1        return Character.digit(c, 16);\2' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
