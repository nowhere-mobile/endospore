#!/usr/bin/env bash
# test-coldlock-pending-java.sh [<ChooserActivity.java>] [--mutate] -- the gate's sign-in over a cold lock that is still
# waiting for the worker slot, run under javac (NWP-20261022-25).
#
# WHY THIS IS COMMITTED. A lock no unlock can revoke (the hand-switch's) writes .coldlock only once it holds the RW slot,
# so GET-COLDLOCK says NONE for the whole wait and the sign-in's #123 snapshot misses the session it is superseding. The
# sign-in now also asks GET-COLDLOCK-PENDING, and after a COMMITTED login reaps that user -- but only when it is no longer
# unlocked, because a revoked teardown (a logoff) leaves a LIVE session and removeUser would destroy it. The rules that
# decide this (the reply parser, pendingReapDue and the reap helper) run here; the wiring in the login thread (the probe
# only when the snapshot named no parked session, its result never reaching the create refusal or the credit probe, the
# reap after the commit and behind an isUserUnlocked read) is pinned in the source.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-coldlock-pending-java.sh            # the cases
#   bash test-coldlock-pending-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/coldlock-pending/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

# one root for everything this suite makes; run.sh's own mktemp lands in it through TMPDIR
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
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# suite <ChooserActivity.java> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may convict a mutant), 2 a
# member did not extract, 3 the lifted class did not compile.
suite() { bash "$RUN" "$1"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> [<lines-that-must-change>]
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/ChooserActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
  if [ "$changed" -ne "${3:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${3:-1}"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the pending probe is sent unconditionally" 's/            if \(supersedeColdUid <= 0\) \{\n(                try \{ pendingColdUid = )/            if (true) {\n$1/' || fails=$((fails+1))
mut "M2 pendingColdUid is fed to the credit probe" 's/parkedCreditProbeDue\(isCreate, supersedeColdUid, /parkedCreditProbeDue(isCreate, pendingColdUid > 0 ? pendingColdUid : supersedeColdUid, /' || fails=$((fails+1))
mut "M3 the pending reap runs before the commit check" 's/(            int pendingColdUid = -1;\n)/$1            if (pendingColdUid > 0) { reapSupersededColdLock(appCtx, pendingColdUid, -1); }\n/' || fails=$((fails+1))
mut "M4 the unlocked guard is dropped" 's/return pendingUid > 0 && pendingUid != newUid && !stillUnlocked;/return pendingUid > 0 \&\& pendingUid != newUid;/' || fails=$((fails+1))
mut "M5 the parser accepts uid 0" 's/return u > 0 \? u : -1;/return u >= 0 ? u : -1;/' || fails=$((fails+1))
mut "M6 the reap does not read isUserUnlocked at reap time" 's/stillUnlocked = pum == null \|\| pum\.isUserUnlocked\(android\.os\.UserHandle\.of\(pendingColdUid\)\);/stillUnlocked = false;/' || fails=$((fails+1))
mut "M7 a throwing read counts as locked" 's/\} catch \(Throwable t\) \{ stillUnlocked = true; \}/} catch (Throwable t) { stillUnlocked = false; }/' || fails=$((fails+1))
mut "M8 the pending probe's result feeds the create refusal" 's/createRefusedForColdLock\(coldLock0\)/createRefusedForColdLock(pendingColdUid > 0 ? "COLDLOCK " + pendingColdUid + " x" : coldLock0)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
