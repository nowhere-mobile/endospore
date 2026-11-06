#!/usr/bin/env bash
# test-staged-claim-java.sh [--mutate] -- NWP-20261101-10 (Q122): a create that failed after its code was drained says the
# credit is held on the phone, for that exact name and passphrase, until it restarts. Runs core/chooser/tests/staged-claim:
# the chooser's reading of "BLANK STAGED" / "NOCREDIT STAGED", its copy, and the order of its branch in roamLogin,
# compiled and EXECUTED.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs the suite against broken copies of ChooserActivity.java, each of which must FAIL a named case; a
# mutant that does not apply (INERT) or does not compile/extract (BROKEN) counts as a failure, never a pass.
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-staged-claim-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRC="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
run() { TMPDIR=$W JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/staged-claim/run.sh" "$1"; }
run "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W"); f="$d/ChooserActivity.java"
  cp "$SRC" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$SRC" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  out=$(run "$f" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "S3 createReplyStaged is always false" 's/(private static boolean createReplyStaged\(String cr\) \{\n)/$1        if (true) return false;\n/' \
  "staged: BLANK STAGED" || fails=$((fails+1))
mut "S4 the staged branch moved after the NOCREDIT one" 's/(                if \(createReplyStaged\(cr\)\) \{.*?\n                \}\n)(                if \(cr\.startsWith\("NOCREDIT"\)\) \{.*?\n                \}\n)/$2$1/s' \
  "wiring: the staged branch precedes the NOCREDIT one" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
