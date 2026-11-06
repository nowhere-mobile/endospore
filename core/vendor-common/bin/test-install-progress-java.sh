#!/usr/bin/env bash
# test-install-progress-java.sh [--mutate] -- NWP-20261122-14: the add's notification shows a real bar and
# "<got> of <total>" from FETCH-APP's PROGRESS lines. Runs core/chooser/tests/install-progress: the chooser's pure
# InstallProgress (parse, text, bar), compiled against its cases ALONE and EXECUTED. Then:
#   - fmtB agreement: InstallProgress.fmtB and UnarchiveService.fmtB (extracted brace-matched, run under a real JVM)
#     give the same string on every boundary value, so an added app and a tapped one read the same figures;
#   - source pins: StoreService.getApp sends FETCH-APP with the `progress` opt-in through fetchVerdict, no other
#     chooser FETCH-APP sender sends it (UnarchiveService's one-line read gets one line only), and the old
#     "no byte counts for FETCH-APP" comment is gone.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of the chooser sources, each of which must FAIL a named check. A
# mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-install-progress-java.sh            # the cases, the agreement check and the pins
#   bash test-install-progress-java.sh --mutate   # ... plus the mutants
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
  echo "test-install-progress-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser

extract() { # extract <file> <signature-fragment> -- the member, brace-matched, with `private ` stripped
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + ' in ' + sys.argv[1] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1].replace('private ', '', 1)); sys.exit(0)
sys.stderr.write('UNBALANCED: ' + sys.argv[2] + '\n'); sys.exit(1)
PY
}

agree() { # agree <root> -- InstallProgress.fmtB and UnarchiveService.fmtB return the same string on every value
  local r=$1 d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  {
    echo 'package com.nowhere.chooser;'
    echo 'final class UnarchiveFmt {'
    extract "$r/$CH/UnarchiveService.java" 'private static String fmtB(long b)' || return 1
    echo '}'
  } > "$d/src/com/nowhere/chooser/UnarchiveFmt.java"
  cat > "$d/src/com/nowhere/chooser/FmtAgree.java" <<'JAVA'
package com.nowhere.chooser;
public class FmtAgree {
  public static void main(String[] a) {
    long K = 1024, M = K * K, G = M * K;
    long[] v = { -1, 0, 1, 1023, K, M - 1, M, (long) (9.94 * M), (long) (9.96 * M), 12 * M, 46 * M,
        (long) (1023.4 * M), (long) (1023.6 * M), G, 5 * G, Long.MAX_VALUE };
    int bad = 0;
    for (long b : v) {
      String u = UnarchiveFmt.fmtB(b), i = InstallProgress.fmtB(b);
      if (!u.equals(i)) { System.out.println("FAIL fmtB agreement at " + b + ": Unarchive " + u + ", Install " + i); bad++; }
    }
    System.out.println(bad == 0 ? "ok   fmtB agreement on " + v.length + " values" : "FAILED fmtB agreement");
    if (bad != 0) System.exit(1);
  }
}
JAVA
  "$JAVAC" -encoding UTF-8 -d "$d/cls" "$r/$CH/InstallProgress.java" "$d/src/com/nowhere/chooser/UnarchiveFmt.java" \
    "$d/src/com/nowhere/chooser/FmtAgree.java" || return 1
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/cls" com.nowhere.chooser.FmtAgree
}

pins() { # pins <root> -- the request bytes of every chooser FETCH-APP sender
  local r=$1 bad=0 hits store unarch
  store=$(cat "$r/$CH/StoreService.java")
  unarch=$(cat "$r/$CH/UnarchiveService.java")
  if [[ $store == *'fetchVerdict("FETCH-APP\n" + pkg + " 0 progress\n", FETCH_APP_CAP_MS,'* ]]; then
    echo "ok   p1 getApp sends FETCH-APP with the progress opt-in through fetchVerdict"
  else echo "FAIL p1 getApp sends FETCH-APP with the progress opt-in through fetchVerdict"; bad=1; fi
  hits=$(grep -rn --include='*.java' -F 'FETCH-APP\n' "$r/core/chooser/src" | grep -F 'progress' || true)
  if [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] && [[ $hits == *StoreService.java:* ]]; then
    echo "ok   p2 no other chooser FETCH-APP sender sends the progress opt-in"
  else echo "FAIL p2 no other chooser FETCH-APP sender sends the progress opt-in: $hits"; bad=1; fi
  if [[ $unarch == *'daemon("FETCH-APP\n" + pkg + " " + pin.vc + "\n");'* ]]; then
    echo "ok   p3 UnarchiveService's FETCH-APP request is unchanged"
  else echo "FAIL p3 UnarchiveService's FETCH-APP request is unchanged"; bad=1; fi
  if [[ $store != *'no byte counts for FETCH-APP'* && $store != *'byte counts for FETCH-APP, so a percentage'* ]]; then
    echo "ok   p4 the stale \"no byte counts for FETCH-APP\" comment is gone"
  else echo "FAIL p4 the stale \"no byte counts for FETCH-APP\" comment is gone"; bad=1; fi
  return "$bad"
}

suite() { # suite <root> -- the cases, the agreement check and the pins; non-zero on any failure
  local r=$1 rc=0
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/install-progress/run.sh" "$r" "$(mktemp -d -p "$W")" || rc=1
  agree "$r" || rc=1
  pins "$r" || rc=1
  return "$rc"
}

suite "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file under $CH> <perl-expr> <check the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/core/chooser"
  cp -R "$ROOT/core/chooser/src" "$d/core/chooser/src"
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(suite "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the check '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 the opt-in added to UnarchiveService's FETCH-APP" UnarchiveService.java \
  's/\+ " " \+ pin\.vc \+ "\\n"\);/+ " " + pin.vc + " progress\\n");/' \
  "p2 no other chooser FETCH-APP sender sends the progress opt-in" || fails=$((fails+1))
mut "M2 the text built without fmtB's rule" InstallProgress.java \
  's/return fmtB\(Math\.min\(got, total\)\) \+ " of " \+ fmtB\(total\);/return String.format(java.util.Locale.US, "%.1f MB of %.1f MB", Math.min(got, total) \/ 1048576.0, total \/ 1048576.0);/' \
  'text 12 MiB of 46 MiB is fmtB'"'"'s "12 MB of 46 MB"' || fails=$((fails+1))
mut "M3 the bar not scaled into an int" InstallProgress.java \
  's/long d = total \/ Integer\.MAX_VALUE \+ 1;/long d = 1;/' \
  "bar above Integer.MAX_VALUE is scaled into an int" || fails=$((fails+1))
mut "M4 parse accepts extra fields" InstallProgress.java \
  's/f\.length != 3 \|\|/f.length < 3 ||/' \
  "parse refuses PROGRESS 1 2 3" || fails=$((fails+1))
mut "M5 InstallProgress.fmtB drifts from UnarchiveService's" InstallProgress.java \
  's/Math\.round\(mb \* 10\) < 100\)/Math.round(mb * 10) < 1000)/' \
  "fmtB agreement" || fails=$((fails+1))
mut "M6 getApp drops the opt-in" StoreService.java \
  's/pkg \+ " 0 progress\\n", FETCH_APP_CAP_MS/pkg + "\\n", FETCH_APP_CAP_MS/' \
  "p1 getApp sends FETCH-APP with the progress opt-in through fetchVerdict" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
