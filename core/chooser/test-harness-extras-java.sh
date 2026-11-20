#!/usr/bin/env bash
# test-harness-extras-java.sh [--mutate] -- NWP-20261205-09: the gate signs in from its `profile`/`pass` Intent extras
# only on a debuggable build.
#
# WHY. ChooserActivity's onCreate ("Headless driving") and onNewIntent read the `profile` and `pass` extras and called
# unlock(ep, epw) on every build, so a release image still carried a test hook that any user-0 caller could drive, and
# `am start --es pass ...` put the passphrase on am's command line. DECIDED 2026-11-04 (h57 #8, docs/product-decisions.md
# "nine answers to harvest 57 -- every recommendation accepted", option 1): the gate honours the extras only when
# `ro.debuggable` is 1. A denied or empty property read counts as not debuggable (sysProp's default "0": fail closed).
#
# WHAT RUNS. HarnessExtras (pure Java) is compiled with tests/harness-extras/HarnessExtrasCases.java ALONE and RUN:
# (H1) honour("1", p, w) is true; (H2) "0", "", null, "true" and " 1" are false; (H3) a missing profile or pass is false.
# Anchor pins on comment-stripped ChooserActivity.java: (A1) exactly two getStringExtra("pass") reads, one in onCreate and
# one in onNewIntent; (A2) in each, after the read and before any unlock(, the guard
# `if (HarnessExtras.honour(sysProp("ro.debuggable", "0"), ep, epw)) {` opens the block that calls unlock(ep, epw);
# (A3) no unlock(ep, epw) outside those two blocks; (A4) the ignored-extras log line is in each method, after the block,
# and its statement names neither ep nor epw. (R1) docs/release-runbook.md's "Canary first" list says the sign-in is
# typed. The merger's full javac / `m NowhereChooser` covers ChooserActivity itself.
#
# What this does NOT prove: a user build seen ignoring the extras (the gate stays empty and logcat shows the ignored
# line) and a userdebug build still signing in from them. That is the merger's device follow-up.
#
#   bash test-harness-extras-java.sh              # the cases and the pins
#   bash test-harness-extras-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
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
  echo "test-harness-extras-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

HE="$SRC/HarnessExtras.java"; CA="$SRC/ChooserActivity.java"; RB="$HERE/../../docs/release-runbook.md"
CASES="$HERE/tests/harness-extras/HarnessExtrasCases.java"
for f in "$CASES" "$CA" "$RB"; do
  if [ ! -f "$f" ]; then echo "test-harness-extras-java: FAIL -- $f is missing"; exit 2; fi
done

cases() { # cases <HarnessExtras.java> [quiet]: 0 pass, 1 a case failed (or the class is missing), 2 did not compile
  local he=$1 quiet=${2:-} cls out rc=0
  cls=$(mktemp -d -p "$W") || return 2
  if [ ! -f "$he" ]; then
    [ -z "$quiet" ] && echo "FAIL H1-H3 $he is missing"
    rm -rf "$cls"; return 1
  fi
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$cls" "$he" "$CASES" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$cls"; return 2
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -cp "$cls" \
    com.nowhere.chooser.HarnessExtrasCases 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$cls"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

pins() { # pins <ChooserActivity.java> <release-runbook.md>: 0 hold, 1 failed, 2 extract
  python3 - "$1" "$2" <<'PY'
import io, re, sys
ca_path, rb_path = sys.argv[1:3]

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

def skip_lit(s, i):
    """If s[i] opens a string or char literal, the index just past it; else i."""
    c = s[i]
    if c != '"' and c != "'":
        return i
    j = i + 1
    while j < len(s) and s[j] != c:
        j += 2 if s[j] == '\\' else 1
    return j + 1

def block(s, at):
    """(start, end) of the brace block that opens at the first '{' at or after `at`; literals are skipped."""
    k = at
    while k < len(s) and s[k] != '{':
        nk = skip_lit(s, k)
        k = nk if nk != k else k + 1
    if k >= len(s):
        return None
    j, d = k, 0
    while k < len(s):
        nk = skip_lit(s, k)
        if nk != k:
            k = nk; continue
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: return j, k + 1
        k += 1
    return None

def statement_end(s, at):
    k = at
    while k < len(s) and s[k] != ';':
        nk = skip_lit(s, k)
        k = nk if nk != k else k + 1
    return k

src = strip(io.open(ca_path, encoding='utf-8').read())
bad = []

METHODS = [('onCreate', 'void onCreate(Bundle b)'), ('onNewIntent', 'void onNewIntent(Intent intent)')]
bodies = {}
for name, sig in METHODS:
    at = src.find(sig)
    if at < 0:
        print("EXTRACTION FAILED: no '%s'" % sig); sys.exit(2)
    b = block(src, at + len(sig))
    if b is None:
        print("EXTRACTION FAILED: no body for '%s'" % sig); sys.exit(2)
    bodies[name] = b

def inside(pos, span):
    return span[0] <= pos < span[1]

READ = 'getStringExtra("pass")'
GUARD = 'if (HarnessExtras.honour(sysProp("ro.debuggable", "0"), ep, epw)) {'
CALL = 'unlock(ep, epw)'
LOG = '"headless sign-in extras ignored: not a debuggable build (h57 #8)"'

reads = [m.start() for m in re.finditer(re.escape(READ), src)]
# A1
if len(reads) != 2:
    bad.append('A1 %d getStringExtra("pass") reads, want exactly 2' % len(reads))
for name, _ in METHODS:
    if sum(1 for r in reads if inside(r, bodies[name])) != 1:
        bad.append('A1 %s does not hold exactly one getStringExtra("pass") read' % name)

# A2
guarded = []
for name, _ in METHODS:
    body = bodies[name]
    rs = [r for r in reads if inside(r, body)]
    if not rs:
        bad.append('A2 %s: no pass read to guard' % name); continue
    r = rs[0]
    g = src.find(GUARD, r, body[1])
    if g < 0:
        bad.append('A2 %s: no `%s` after the pass read' % (name, GUARD)); continue
    if 'unlock(' in src[r:g]:
        bad.append('A2 %s: an unlock( runs between the pass read and the guard' % name)
    gb = block(src, g + len(GUARD) - 1)
    if gb is None or CALL + ';' not in src[gb[0]:gb[1]]:
        bad.append('A2 %s: the guarded block does not call %s' % (name, CALL)); continue
    guarded.append((name, gb))

# A3
calls = [m.start() for m in re.finditer(re.escape(CALL), src)]
if len(calls) != 2:
    bad.append('A3 %d %s calls, want exactly 2' % (len(calls), CALL))
for c in calls:
    if not any(inside(c, gb) for _, gb in guarded):
        bad.append('A3 %s at offset %d is outside the guarded blocks' % (CALL, c))

# A4
logs = [m.start() for m in re.finditer(re.escape(LOG), src)]
if len(logs) != 2:
    bad.append('A4 the ignored-extras line appears %d times, want 2' % len(logs))
for name, _ in METHODS:
    mine = [l for l in logs if inside(l, bodies[name])]
    if len(mine) != 1:
        bad.append('A4 %s does not log the ignored-extras line exactly once' % name); continue
    l = mine[0]
    gbs = [gb for n, gb in guarded if n == name]
    if gbs and l < gbs[0][1]:
        bad.append('A4 %s logs the ignored-extras line inside or before the guarded block' % name)
    start = max(src.rfind(ch, 0, l) for ch in ';{}') + 1
    stmt = src[start:statement_end(src, l)]
    if re.search(r'\b(ep|epw)\b', stmt):
        bad.append('A4 %s: the ignored-extras statement names ep or epw: %s' % (name, ' '.join(stmt.split())))

# R1
rb = io.open(rb_path, encoding='utf-8').read()
a = rb.find('**Canary first**')
z = rb.find('3. When the smoke passes', a if a >= 0 else 0)
SENT = ('The sign-in is typed by hand: a release build ignores the gate\'s `profile`/`pass` Intent extras (h57 #8), '
        'so `am start --es` cannot drive it.')
if a < 0 or z < 0:
    bad.append('R1 the runbook has no "Canary first" list')
elif SENT not in ' '.join(rb[a:z].split()):
    bad.append('R1 the "Canary first" list does not say the sign-in is typed')

for b in bad: print('PIN FAILED: ' + b)
if not bad: print('ok A1-A4 both extras sites honour the sign-in only on ro.debuggable=1 and log no value; '
                  'R1 the runbook says the sign-in is typed')
sys.exit(1 if bad else 0)
PY
}

suite() { # suite <HarnessExtras.java> <ChooserActivity.java> <release-runbook.md> [quiet]
  local he=$1 ca=$2 rb=$3 quiet=${4:-} rc=0 prc=0 pout
  cases "$he" "$quiet" || rc=$?
  [ "$rc" -eq 2 ] && return 2
  pout=$(pins "$ca" "$rb" 2>&1) || prc=$?
  [ -z "$quiet" ] && [ -n "$pout" ] && printf '%s\n' "$pout"
  [ "$prc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ] || [ "$prc" -ne 0 ]; then return 1; fi
  return 0
}

suite "$HE" "$CA" "$RB"; rc=$?
if [ "$rc" -ne 0 ]; then echo "test-harness-extras-java: FAIL (rc $rc)"; exit 1; fi
echo "test-harness-extras-java: cases and pins pass"
[ "$MUTATE" -eq 1 ] || exit 0

fails=0
mutant() { # mutant <name> <which: he|ca|rb> <python-regex> <replacement>
  local name=$1 which=$2 pat=$3 rep=$4 d src orig mhe mca mrb rc=0
  d=$(mktemp -d -p "$W") || return 1
  mhe="$d/HarnessExtras.java"; mca="$d/ChooserActivity.java"; mrb="$d/release-runbook.md"
  cp "$HE" "$mhe"; cp "$CA" "$mca"; cp "$RB" "$mrb"
  case "$which" in
    he) src=$mhe; orig=$HE ;;
    ca) src=$mca; orig=$CA ;;
    rb) src=$mrb; orig=$RB ;;
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
  suite "$mhe" "$mca" "$mrb" quiet; rc=$?
  if [ "$rc" -eq 1 ]; then echo "  $name: convicted"
  elif [ "$rc" -eq 0 ]; then echo "  $name: ⚠ SURVIVED"; fails=$((fails + 1))
  else echo "  $name: ⚠ DID NOT COMPILE/EXTRACT"; fails=$((fails + 1)); fi
  rm -rf "$d"
}

echo "mutants:"
mutant "X1 honour returns true when debuggable is \"0\" (H2)" he '"1"\.equals\(debuggable\)' '!"".equals(debuggable)'
mutant "X2 honour drops the pass null check (H3)" he ' && pass != null' ''
mutant "X3 the onCreate guard removed (A2)" ca '(void onCreate\(Bundle b\).*?)if \(HarnessExtras\.honour\(sysProp\("ro\.debuggable", "0"\), ep, epw\)\) \{' '\1if (ep != null \&\& epw != null) {'
mutant "X4 the onNewIntent guard removed (A2)" ca '(void onNewIntent\(Intent intent\).*?)if \(HarnessExtras\.honour\(sysProp\("ro\.debuggable", "0"\), ep, epw\)\) \{' '\1if (ep != null \&\& epw != null) {'
mutant "X5 one site reads ro.secure (A2)" ca 'sysProp\("ro\.debuggable", "0"\), ep, epw' 'sysProp("ro.secure", "0"), ep, epw'
mutant "X6 one site defaults to \"1\", fail-open (A2)" ca 'sysProp\("ro\.debuggable", "0"\), ep, epw' 'sysProp("ro.debuggable", "1"), ep, epw'
mutant "X7 the ignored-extras line appends epw (A4)" ca '("headless sign-in extras ignored: not a debuggable build \(h57 #8\)")' '\1 + epw'
mutant "X8 the runbook sentence removed (R1)" rb 'The sign-in is typed by hand:.*?cannot drive it\.\s*' ''

if [ "$fails" -ne 0 ]; then echo "test-harness-extras-java: FAIL -- $fails mutant(s) not convicted"; exit 1; fi
echo "test-harness-extras-java: all mutants convicted"
