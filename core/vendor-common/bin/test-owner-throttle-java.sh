#!/usr/bin/env bash
# test-owner-throttle-java.sh [--mutate] -- the owner verify's back-off, run under javac (NWP-20261011-39).
#
# WHY THIS IS COMMITTED. The device passphrase is the only local admin credential -- it gates System settings and
# Leave Nowhere -- and five wrong tries arm a wait. That wait used to run on the wall clock, so setting the clock back
# skipped it entirely and setting it forward lifted it early (docs/backlog.md). It now runs on
# SystemClock.elapsedRealtime(), and owWaitSecs/owSinceMs, private static helpers in ChooserActivity.java, decide it:
# a reboot or a pre-NWP-20261011-39 wall-clock stamp must read as "since boot", never as "long ago". Nothing else
# executes them off a device. core/chooser/tests/owner-throttle/run.sh lifts them into a plain class and runs Cases
# against them; core/chooser/test-owner-conf.sh pins that verifyOwner calls them with elapsedRealtime.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. A suite that quietly passes because its tool is missing reads
# exactly like one that ran. javac comes from PATH, else from the build host's JDK below; the CI runner is the build
# VM, which has it. The version is printed first so the log proves which compiler ran.
#
#   bash test-owner-throttle-java.sh            # the cases
#   bash test-owner-throttle-java.sh --mutate   # ... plus broken copies of the helpers that must each FAIL the cases
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
RUN="$root/core/chooser/tests/owner-throttle/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

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

# suite <ChooserActivity.java> -> 0 pass, 1 a case failed, 2 a helper did not extract, 3 the lifted class did not
# compile. Only 1 may convict a mutant; 2 and 3 prove nothing about the logic.
suite() { bash "$RUN" "$1"; }

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d m rc; d=$(mktemp -d); m="$d/ChooserActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
S='return nowRt >= lastRt && lastRt >= 0 \? nowRt - lastRt : nowRt;'
fails=0
mut "M1 since is now - last unconditionally"          "s/$S/return nowRt - lastRt;/" || fails=$((fails+1))
mut "M2 a reboot or legacy stamp reads as long ago"   "s/$S/return nowRt >= lastRt \&\& lastRt >= 0 ? nowRt - lastRt : Long.MAX_VALUE;/" || fails=$((fails+1))
mut "M3 a reboot resets the wait to its full length"  "s/$S/return nowRt >= lastRt \&\& lastRt >= 0 ? nowRt - lastRt : 0;/" || fails=$((fails+1))
mut "M4 a negative stamp is trusted"                  "s/$S/return nowRt >= lastRt ? nowRt - lastRt : nowRt;/" || fails=$((fails+1))
mut "M5 the old wall-clock guard skips since < 0"     's/since = owSinceMs\(nowRt, lastRt\);/since = nowRt - lastRt;/; s/return since < wait \?/return since >= 0 \&\& since < wait ?/' || fails=$((fails+1))
mut "M6 the wait rounds down"                         's/\(int\) Math\.ceil\(\(wait - since\) \/ 1000\.0\)/(int) ((wait - since) \/ 1000)/' || fails=$((fails+1))
mut "M7 the wait ignores the last attempt"            's/since = owSinceMs\(nowRt, lastRt\);/since = owSinceMs(nowRt, 0);/' || fails=$((fails+1))
mut "M8 the first tier starts at six fails"           's/if \(fails < 5\) return 0;/if (fails < 6) return 0;/' || fails=$((fails+1))
mut "M9 the 30-minute tier is gone"                   's/if \(fails < 20\) return 300_000L; return 1_800_000L;/return 300_000L;/' || fails=$((fails+1))
mut "M10 four fails already wait"                     's/if \(fails < 5\) return 0;/if (fails < 4) return 0;/' || fails=$((fails+1))
mut "M11 the wait never lifts"                        's/\(wait - since\) \/ 1000\.0\) : 0;/(wait - since) \/ 1000.0) : 1;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
