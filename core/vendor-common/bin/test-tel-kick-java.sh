#!/usr/bin/env bash
# test-tel-kick-java.sh [--mutate] -- NWP-20261019-04: the failed-logoff delivery re-kick. Runs core/chooser/tests/tel-kick:
# the pure TelKick loop (8 kicks, 2 s apart, a throwing kick does not end it, an interrupt does) and the pins on its
# call site in ProfileActivity.doLogoffImpl's sealFailed block, compiled and EXECUTED.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of TelKick.java and ProfileActivity.java, each of which must FAIL.
# A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-tel-kick-java.sh            # the cases
#   bash test-tel-kick-java.sh --mutate   # ... plus the mutants
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
  echo "test-tel-kick-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/tel-kick/run.sh" "$1"; }
run "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v python3 >/dev/null 2>&1 || { echo "FAIL: --mutate needs python3, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file: TelKick.java|ProfileActivity.java> <python-regex> <replacement>
  local d out rc
  d=$(mktemp -d)
  mkdir -p "$d/$CH"
  cp "$ROOT/$CH/TelKick.java" "$ROOT/$CH/ProfileActivity.java" "$d/$CH/"
  if ! python3 - "$d/$CH/$2" "$3" "$4" <<'PY'; then echo "  INERT     $1 -- the mutation did not apply"; rm -rf "$d"; return 1; fi
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -q 'error:' <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -q '^FAIL ' <<<"$out"; then echo "  BROKEN    $1 -- it failed, but no case reported FAIL (rc=$rc)"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 the loop bound is off by one" TelKick.java 'i < times;' 'i < times - 1;' || fails=$((fails+1))
mut "M2 the catch removed" TelKick.java 'try \{\n\s*kick\.run\(\);\n\s*\} catch \(Throwable ignored\) \{\n[^\n]*\n\s*\}' 'kick.run();' || fails=$((fails+1))
mut "M3 a break after the first kick" TelKick.java '(kick\.run\(\);\n\s*\} catch \(Throwable ignored\) \{\n[^\n]*\n\s*\})' '\1\n            break;' || fails=$((fails+1))
mut "M4 the call site says 7, 2000" ProfileActivity.java '\}, 8, 2000, Thread::sleep\)' '}, 7, 2000, Thread::sleep)' || fails=$((fails+1))
mut "M5 the call removed from the sealFailed block" ProfileActivity.java '(if \(sealFailed\) \{\n(?:[^\n]*SignOutGate\.end\(\);[^\n]*\n)?)\s*// NWP-20261019-04 \(.*?"nowhere-logoff-telkick"\)\.start\(\);\n' '\1' || fails=$((fails+1))
mut "M6 the call moved inside runOnUiThread" ProfileActivity.java '(if \(sealFailed\) \{\n(?:[^\n]*SignOutGate\.end\(\);[^\n]*\n)?)(\s*// NWP-20261019-04 \(.*?"nowhere-logoff-telkick"\)\.start\(\);\n)(.*?runOnUiThread\(\(\) -> \{\n)' '\1\3\2' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
