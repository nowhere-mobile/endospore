#!/usr/bin/env bash
# test-unarchive-gate-java.sh [--mutate] -- NWP-20261104-20: UnarchiveReceiver is exported, so any app in the session can
# send it a broadcast; it must act only on the system's ACTION_UNARCHIVE_PACKAGE with a well-formed package name.
# Runs core/chooser/tests/unarchive-gate: the chooser's pure UnarchiveGate compiled against its cases ALONE and
# EXECUTED, plus source pins that the manifest filter carries the gate's action and that onReceive consults the gate
# before it starts anything or reports a status.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of the gate, receiver and manifest, each of which must FAIL a named
# case or pin. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-unarchive-gate-java.sh            # the cases and pins
#   bash test-unarchive-gate-java.sh --mutate   # ... plus the mutants
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
  echo "test-unarchive-gate-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/unarchive-gate/run.sh" "$1" "$(mktemp -d -p "$W")"; }
run "$ROOT" || { echo "FAILED"; exit 1; }

[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file under the repo> <perl-expr over it> <case or pin the mutant must fail>
  local d f out rc rel
  d=$(mktemp -d -p "$W")
  for rel in "$CH/UnarchiveGate.java" "$CH/UnarchiveReceiver.java" core/chooser/AndroidManifest.xml; do
    mkdir -p "$d/$(dirname "$rel")"
    cp "$ROOT/$rel" "$d/$rel"
  done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
G=$CH/UnarchiveGate.java
R=$CH/UnarchiveReceiver.java
mut "U1 the action check removed" "$G" 's/return ACTION\.equals\(action\) && validPkg\(pkg\);/return validPkg(pkg);/' \
  "MAIN action is refused" || fails=$((fails+1))
mut "U2 the package grammar removed (non-empty only)" "$G" 's/&& validPkg\(pkg\);/\&\& pkg != null \&\& !pkg.isEmpty();/' \
  "a..b is refused" || fails=$((fails+1))
mut "U3 the accept call moved after startForegroundService" "$R" \
  's/(\n[ \t]*if \(!UnarchiveGate\.accept\(.*?return;\n[ \t]*\})(.*?EXTRA_PKG, pkg\)\);)/$2$1/s' \
  "p2" || fails=$((fails+1))
mut "U4 ACTION misspelt" "$G" 's/"android\.intent\.action\.UNARCHIVE_PACKAGE"/"android.intent.action.UNARCHIVE_PACKAGES"/' \
  "p1" || fails=$((fails+1))
mut "U5 the refused branch reports an unarchival status" "$R" \
  's/(unarchive request"\);\s*)return;/$1ctx.getPackageManager().getPackageInstaller().reportUnarchivalStatus(intent.getIntExtra(PackageInstaller.EXTRA_UNARCHIVE_ID, -1), 1, 0, null);\n            return;/' \
  "p3" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
