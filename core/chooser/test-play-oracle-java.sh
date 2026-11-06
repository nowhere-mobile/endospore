#!/usr/bin/env bash
# test-play-oracle-java.sh [<ProfileActivity.java>] [--mutate] -- the Play-stack orphan oracle, run under javac
# (NWP-20261022-18).
#
# WHY THIS IS COMMITTED. Backlog row "Stop carrying the Play stack once nothing needs it (NWP-20260826-12 part 2)"
# (BUILT, UNPROVEN) says its final shape needs "a review round against the final shape, which the timebox did not
# allow", and states the rule a third attempt must keep: NEVER CACHE A NEGATIVE; every absence is UNKNOWN and
# abstains. playStackOrphanKnown gates the stack's data and code drop (setAppModeLocked's Off branch), so a tidy-up
# that trusts a record at another version, drops readsPlayServices' sourceDir guard, or reads a two-field line as an
# answer would declare the stack orphaned while a client still needs it, and gms's data would stop roaming. No suite
# executed any of it: test-playdep-lock.sh pins where the lock and binder reads sit, test-appmode-lock.sh what runs
# under APPKEEP_LOCK, test-yourapps-off-row.sh one call-site ordering.
#
# core/chooser/tests/play-oracle/run.sh lifts playStackOrphanKnown, playDependent, readsPlayServices, readPlaySeen,
# notePlaySeen, readPlayDeps, logNotOrphaned, the three package constants and PLAYDEP_LOCK out of ProfileActivity.java,
# and StoreInstaller's writeAtomic seam, into a harness class, and runs PlayOracleCases against it. This suite pins
# SHIPPED behaviour: its cases pass on main; what must fail is every mutant.
#
# NWP-20261111-06: a Play record that EXISTS but cannot be opened is unknown, and unknown abstains. Case 14 puts a
# non-empty directory where nowhere-playdeps (then nowhere-playseen) belongs, beside a stale determined-n answer that
# alone passes the walk: playStackOrphanKnown must answer false, where a read-as-empty record answered true. The run.sh
# lift adds readPlayDepsStrict and readPlaySeenStrict.
#
# What this does NOT prove: the on-device Off/On sequence with a real gms -- that device test stays on the row.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-play-oracle-java.sh            # the cases
#   bash test-play-oracle-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
SI="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/play-oracle/run.sh"
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
[ -f "$SRC" ] && [ -f "$SI" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC, $SI or $RUN" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# suite <ProfileActivity.java> -> run.sh's code: 0 pass, 1 a case failed (only this may convict a mutant), 2 a member
# did not extract, 3 the lifted classes did not compile.
suite() { bash "$RUN" "$1" "$SI"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr>   -- exactly one line must change
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/ProfileActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
  if [ "$changed" -ne 1 ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected 1"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "P1 the version-equality test on the record is removed" 's/rec != null && now >= 0 && rec\[0\]\.equals\(Long\.toString\(now\)\)/rec != null \&\& now >= 0/' || fails=$((fails+1))
mut "P2 readsPlayServices' sourceDir guard is removed" 's/if \(ai == null \|\| ai\.sourceDir == null \|\| ai\.sourceDir\.isEmpty\(\)\) return null;/if (ai == null) return null;/' || fails=$((fails+1))
mut "P3 the playdeps arm is removed" 's/if \(deps\.contains\(p\)\) \{ logNotOrphaned/if (false) { logNotOrphaned/' || fails=$((fails+1))
mut "P4 the stack-member skip is removed" 's/if \(GMS_PKG\.equals\(p\) \|\| GSF_PKG\.equals\(p\) \|\| VENDING_PKG\.equals\(p\)\) continue; \/\/ the stack itself/if (false) continue; \/\/ the stack itself/' || fails=$((fails+1))
mut "P5 readPlaySeen accepts a two-field line" 's/if \(f\.length != 3\) continue;/if (f.length == 2) { out.put(f[0].trim(), new String[] { f[1].trim(), "y" }); continue; } if (f.length != 3) continue;/' || fails=$((fails+1))
mut "P6 notePlaySeen's vc < 0 return is removed" 's/if \(vc < 0\) return;/if (false) return;/' || fails=$((fails+1))
mut "P7 playDependent's y test is inverted" 's/return rec != null && "y"\.equals\(rec\[1\]\);/return rec != null \&\& !"y".equals(rec[1]);/' || fails=$((fails+1))
mut "M4 playStackOrphanKnown reads an unreadable Play record as empty (NWP-20261111-06)" 's/if \(deps == null \|\| seen == null\) \{/if (deps == null) deps = new java.util.LinkedHashSet<>(); if (seen == null) seen = new java.util.HashMap<>(); if (false) {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
