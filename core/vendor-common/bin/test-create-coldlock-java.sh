#!/usr/bin/env bash
# test-create-coldlock-java.sh [--mutate] -- NWP-20261010-16: the gate refuses Create while a cold-locked session is parked
# (docs/product-decisions.md, 2026-10-10). Runs core/chooser/tests/create-coldlock: the chooser's pure decision, its
# copy, the ERR-COLDLOCK compatibility of the create branch, and the wiring in roamLogin, compiled and EXECUTED.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate (NWP-20261014-44) re-runs the suite against broken copies of ChooserActivity.java, each of which must FAIL a
# named case: a wipe guard (the refusal) that no case was ever shown to catch is not pinned. A mutant that does not
# apply (INERT) or does not compile/extract (BROKEN) counts as a failure, never a pass.
#
#   bash test-create-coldlock-java.sh            # the cases
#   bash test-create-coldlock-java.sh --mutate   # ... plus the mutants
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
  echo "test-create-coldlock-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRC="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/create-coldlock/run.sh" "$1"; }
run "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d); f="$d/ChooserActivity.java"
  cp "$SRC" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$f" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "M1 the refusal returns false for a parsed COLDLOCK" 's/return reply != null && reply\.trim\(\)\.startsWith\("COLDLOCK"\);/return reply != null \&\& reply.trim().startsWith("COLDLOCK") \&\& parseColdLock(reply) == null;/' \
  "refuse: parked" || fails=$((fails+1))
mut "M2 the refusal returns false for a garbled COLDLOCK" 's/return reply != null && reply\.trim\(\)\.startsWith\("COLDLOCK"\);/return reply != null \&\& reply.trim().startsWith("COLDLOCK") \&\& parseColdLock(reply) != null;/' \
  "refuse: COLDLOCK that does not parse" || fails=$((fails+1))
mut "M3 a create-branch prefix also catches ERR-COLDLOCK" 's/if \(cr\.startsWith\("NOSTORE"\)\) \{/if (cr.startsWith("ERR")) { hideRestore(); showBlank(); return; }\n                if (cr.startsWith("NOSTORE")) {/' \
  "live create branch: 'ERR' does not catch ERR-COLDLOCK" || fails=$((fails+1))
mut "M4 the refusal moved after the network wait" 's/(            \/\/ NWP-20261010-16: no Create while[^\n]*\n[^\n]*\n)(            if \(isCreate && createRefusedForColdLock\(coldLock0\)\) \{\n.*?\n            \}\n)(.*?final boolean offline = !hasInternetWithGrace\(8000\);\n)/$1$3$2/s' \
  "wiring: the create is refused after the GET-COLDLOCK probe and before the network wait" || fails=$((fails+1))
mut "P1 the second paragraph removed" 's/\n\s*\+ "\\n\\nIf it isn.t yours:.*?lost\.";/;/s' \
  "text with the name, exact" || fails=$((fails+1))
mut "P2 the restart sentence moved before the sign-in sentence" 's/(ends that session once the "\n\s*\+ "sign-in succeeds, and you.ll be asked first if it holds credit that would be lost\. )(Restarting the "\n\s*\+ "phone also ends it, without asking, and so does the automatic wipe 12 hours after it locked\. )/$2$1/' \
  "text names signing in before a restart" || fails=$((fails+1))
mut "P3 the warning dropped" 's/, and you.ll be asked first if it holds credit that would be lost//' \
  "text promises the warning" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
