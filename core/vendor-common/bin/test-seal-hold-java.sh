#!/usr/bin/env bash
# test-seal-hold-java.sh [--mutate] -- NWP-20261011-01: the Profile screen's "Backups while apps set up" choice. Runs
# core/chooser/tests/seal-hold: the chooser's pure option mapping, default and copy, and that the chooser, roamd and
# the daemon agree on the four stored values, compiled and EXECUTED.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate (NWP-20261014-44) re-runs the suite against broken copies of SealHold.java, each of which must FAIL a named
# case: the option mapping and the default were pinned by cases never shown to fail. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-seal-hold-java.sh            # the cases
#   bash test-seal-hold-java.sh --mutate   # ... plus the mutants
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
  echo "test-seal-hold-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/seal-hold/run.sh" "$1"; }
run "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr over SealHold.java> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d)
  # a tree of symlinks to the real files, but for the one mutated copy of SealHold.java
  mkdir -p "$d/$CH" "$d/core/vendor-common/bin" "$d/core/agent"
  ln -s "$ROOT/$CH/ProfileActivity.java" "$d/$CH/ProfileActivity.java"
  ln -s "$ROOT/core/vendor-common/bin/nowhere_roamd.sh" "$d/core/vendor-common/bin/nowhere_roamd.sh"
  ln -s "$ROOT/core/agent/seal_hold.go" "$d/core/agent/seal_hold.go"
  f="$d/$CH/SealHold.java"
  cp "$ROOT/$CH/SealHold.java" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/SealHold.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "M1 the default is 10 minutes" 's/DEFAULT = "30";/DEFAULT = "10";/' \
  "the default is 30 minutes" || fails=$((fails+1))
mut "M2 two stored values swapped in the picker order" 's/\{ "2", "10", "30", "run" \}/{ "10", "2", "30", "run" }/' \
  "four values in picker order" || fails=$((fails+1))
mut "M3 two stored values swapped in the copy" 's/case "2": return "About 2 minutes";\n            case "10": return "10 minutes";/case "10": return "About 2 minutes";\n            case "2": return "10 minutes";/' \
  "label 2" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
