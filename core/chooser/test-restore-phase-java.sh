#!/usr/bin/env bash
# test-restore-phase-java.sh [--mutate] -- the creating screen's progress labels, run under javac (NWP-20261027-11).
#
# WHY THIS IS COMMITTED. A create writes the first vault and then signs in, and that sign-in's restore streams PROGRESS
# lines; onRestoreProgress mirrored them onto "Creating your space…" with the restore labels, so a new user read
# "Restoring your profile — 100%" over a vault that had just been written. RestorePhase.label(phase, creating) is the pure
# label rule, run here; onRestoreProgress's two call sites (result line false, mirror true) are pinned in the source.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-restore-phase-java.sh            # the cases
#   bash test-restore-phase-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RP="$HERE/src/com/nowhere/chooser/RestorePhase.java"
CA="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/restore-phase/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$RP" ] || { echo "FAIL: missing $RP" >&2; exit 2; }
[ -f "$CA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $CA or $RUN" >&2; exit 2; }

suite() { bash "$RUN" "$1" "$2"; } # <RestorePhase.java> <ChooserActivity.java>

echo "== $RP"
suite "$RP" "$CA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the cases; one that does not apply or compile is a failure)"
mut() { # mut <label> <rp|ca> <perl-expr>
  local d f rp ca rc; d=$(mktemp -d -p "$W"); rp="$d/RestorePhase.java"; ca="$d/ChooserActivity.java"
  cp "$RP" "$rp"; cp "$CA" "$ca"
  if [ "$2" = rp ]; then f="$rp"; else f="$ca"; fi
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$RP" "$rp" && cmp -s "$CA" "$ca"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$rp" "$ca" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "P1 the mirror passes false" ca 's/mirrorCreate\(RestorePhase\.label\(phase, true\)/mirrorCreate(RestorePhase.label(phase, false)/' || fails=$((fails+1))
mut "P2 the result line passes true" ca 's/result\.setText\(RestorePhase\.label\(phase, false\)/result.setText(RestorePhase.label(phase, true)/' || fails=$((fails+1))
mut "P3 two creating labels collapse to one" rp 's/"Setting up secure data"/"Setting up app data"/' || fails=$((fails+1))
mut "P4 the creating default reads Restoring your profile" rp 's/creating \? "Setting up your profile"/creating ? "Restoring your profile"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
