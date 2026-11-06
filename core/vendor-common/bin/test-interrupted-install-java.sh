#!/usr/bin/env bash
# test-interrupted-install-java.sh [--mutate] -- NWP-20261127-13: the rule a resumed install uses to settle the
# sessions a lock left behind (NWP-20261005-11, backlog row "A lock that lands mid-install leaves the system's install
# of that app running, and the resumed sweep's second install of it is refused as a duplicate, so that app is counted
# failed"). Runs core/chooser/tests/interrupted-install: InterruptedInstall.settle, compiled and EXECUTED against a
# fake installer and a fake clock. Before this suite no test named awaitInterruptedInstall or getMySessions.
#
# The source pin (comments stripped): UnarchiveService.awaitInterruptedInstall calls InterruptedInstall.settle( with
# pkg, 600_000, 2_000, records the Play dependency on TRUE, and holds the file's only getMySessions() call; installApks
# still asks it before a new session; InterruptedInstall.java names no android type.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# Everything the suite creates lives under one root removed on exit.
#
# --mutate re-runs the suite against broken copies of InterruptedInstall.java and UnarchiveService.java (M1-M7), each
# of which must FAIL. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-interrupted-install-java.sh            # the cases and the pin
#   bash test-interrupted-install-java.sh --mutate   # ... plus the mutants
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
  echo "test-interrupted-install-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
CH=core/chooser/src/com/nowhere/chooser
command -v python3 >/dev/null 2>&1 || { echo "FAIL: this suite needs python3 for the source pin, and there is none" >&2; exit 1; }
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/interrupted-install/run.sh" "$1" "$W"; }

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

def body(t, sig):
    """The brace-matched body after sig in comment-stripped t (string and char literals skipped), or None."""
    a = t.find(sig)
    if a < 0 or t.find(sig, a + 1) >= 0: return None
    j = t.find('{', a + len(sig))
    depth, k, q = 0, j, None
    while k < len(t):
        c = t[k]
        if q:
            if c == '\\': k += 1
            elif c == q: q = None
        elif c in '"\'': q = c
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return t[j:k + 1]
        k += 1
    return None

us = strip_comments(open(d + '/UnarchiveService.java', encoding='utf-8').read())
ii = strip_comments(open(d + '/InterruptedInstall.java', encoding='utf-8').read())

b = body(us, 'private Boolean awaitInterruptedInstall(PackageInstaller pi, String pkg)')
if b is None:
    fail("UnarchiveService.awaitInterruptedInstall(PackageInstaller pi, String pkg) not found exactly once")
else:
    if b.count('InterruptedInstall.settle(') != 1: fail("awaitInterruptedInstall does not call InterruptedInstall.settle( exactly once")
    if not re.search(r'\},\s*pkg,\s*600_000,\s*2_000\);', b): fail("the settle call does not end with pkg, 600_000, 2_000)")
    if 'pi.getMySessions()' not in b: fail("awaitInterruptedInstall's adapter does not scan pi.getMySessions()")
    if 'ProfileActivity.recordPlayDepAtInstall(this, pkg)' not in b: fail("awaitInterruptedInstall no longer records the Play dependency on TRUE")
if us.count('getMySessions()') != 1: fail("UnarchiveService holds %d getMySessions() calls, not exactly one" % us.count('getMySessions()'))
inst = body(us, 'private boolean installApks(String pkg, List<File> apks) throws Exception')
if inst is None or 'Boolean earlier = awaitInterruptedInstall(pi, pkg);' not in inst:
    fail("installApks no longer asks awaitInterruptedInstall before a new session")
if re.search(r'\bimport\s+android', ii) or re.search(r'\bandroid\.', ii): fail("InterruptedInstall.java names an android type")
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
  for n in InterruptedInstall.java UnarchiveService.java; do cp "$ROOT/$CH/$n" "$d/$CH/"; done
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
I=InterruptedInstall.java
mut $I "M1 committed sessions are abandoned too" '(committed\.add\(m\.id\);\n\s*)\} else \{' '\1}\n                {' || fails=$((fails+1))
mut $I "M2 the package filter removed" '!pkg\.equals\(m\.pkg\)' 'false' || fails=$((fails+1))
mut $I "M3 the deadline check removed" 's\.nowMs\(\) > deadline' 'false' || fails=$((fails+1))
mut $I "M4 TRUE answered instead of installed()" 'boolean landed = s\.installed\(\);' 'boolean landed = true;' || fails=$((fails+1))
mut $I "M5 a throwing present read as still running" 'catch \(Throwable ignore\) \{ here = false; \}' 'catch (Throwable ignore) { here = true; }' || fails=$((fails+1))
mut $I "M6 only the first committed session waited" 'for \(int id : committed\)' 'for (int id : committed.subList(0, 1))' || fails=$((fails+1))
mut UnarchiveService.java "M7 the adapter passes 60_000 as the bound" '(pkg, )600_000(, 2_000\);)' '\g<1>60_000\2' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
