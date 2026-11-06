#!/usr/bin/env bash
# test-settings-save-java.sh [--mutate] -- the media and reclaim settings say when a change was not saved, under javac
# (NWP-20261124-23).
#
# WHY THIS IS COMMITTED. writePrefetchMetered (nowhere-prefetch-metered), writeBudgetBytes (nowhere-media-budget),
# setPinned (nowhere-pins), setTierOverride (nowhere-media-tiers) and setReclaimIdleMs (nowhere-reclaim) were void:
# a failed StoreInstaller.writeAtomic (a full /data, a temp that cannot be renamed) or a failed delete was logged and
# dropped. Their controls acted as if the write landed: the "Download over mobile data" switch showed On, told the
# daemon "1" and could toast "Saved. It takes effect from your next sign-in." while the roamed file still said Wi-Fi
# only; the per-app tier toasted "Keeping X on this phone"; the budget field and the "Re-archive idle apps" chip
# showed values the seal never carries. Now each writer returns whether its file holds the choice, and each control
# on false says SettingsSaveCopy.NOT_SAVED, tells the daemon nothing and shows what the file holds.
#
# WHAT IS PINNED. SettingsSaveCopy (java.lang only) is compiled with its cases (core/chooser/tests/settings-save) and
# executed: tierSaved's four cases and the NOT_SAVED words. The same run holds source checks on the real
# ProfileActivity.java (comments stripped): the five writers are `private boolean`, return true only after their one
# writeAtomic, false from every catch and `!f.exists()` after every delete; the switch, the budget field, the tier
# callback and the reclaim action each branch on the result, send nothing on false and change their state only on
# true; the "Saved. It takes effect" toast is reachable only after the write's result is known.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-settings-save-java.sh            # the cases and the source checks
#   bash test-settings-save-java.sh --mutate   # ... plus M1-M7, each of which must be CONVICTED
#
# SETTINGS_SAVE_SRC / PROFILE_SRC override the two sources (to prove the suite red on an older tree).
# Exit: 0 all pass, 1 a check failed or a mutant was not convicted, 2 the suite itself could not run.
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export SS_ROOT="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SS="${SETTINGS_SAVE_SRC:-$SRC/SettingsSaveCopy.java}"
PA="${PROFILE_SRC:-$SRC/ProfileActivity.java}"
RUN="$root/core/chooser/tests/settings-save/run.sh"
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
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

echo "== $SS against $PA"
bash "$RUN" "$SS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"
# mut <label> ss|pa <perl-expr>: mutate a copy of SettingsSaveCopy.java or ProfileActivity.java; the run must fail (rc 1).
mut() {
  local label="$1" which="$2" expr="$3" d orig c rc
  d=$(mktemp -d -p "$W") || return 1
  case "$which" in ss) orig="$SS" ;; pa) orig="$PA" ;; *) rm -rf "$d"; return 1 ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$which" = ss ]; then bash "$RUN" "$c" "$PA" >/dev/null 2>&1; rc=$?
  else bash "$RUN" "$SS" "$c" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  convicted $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 writePrefetchMetered's catch returns true (S1)" pa \
  's/("writePrefetchMetered", t\); )return false;/${1}return true;/' || fails=$((fails+1))
mut "M2 writePrefetchMetered's delete returns true while the file may still exist (S1)" pa \
  's/f\.delete\(\); return !f\.exists\(\); \} \/\/ absent/f.delete(); return true; } \/\/ absent/' || fails=$((fails+1))
mut "M3 the switch tells the daemon on a failed save (S3)" pa \
  's/(if \(!writePrefetchMetered\(on\)\) \{\n.*?\n)([ \t]*return;)/$1                new Thread(() -> sendDaemon("SET-PREFETCH-METERED\\n" + (on ? "1" : "0") + "\\n")).start();\n$2/s' \
  || fails=$((fails+1))
mut "M4 applyTier ignores setPinned's result (S2)" pa \
  's/boolean pinOk = setPinned\(app, essential\);/setPinned(app, essential);\n        boolean pinOk = true;/' || fails=$((fails+1))
mut "M5 tierSaved uses || (T2, T3)" ss \
  's/return pinOk && tierOk;/return pinOk || tierOk;/' || fails=$((fails+1))
mut "M6 the reclaim action assigns cur[0] before the check (S6)" pa \
  's/([ \t]*)(if \(!setReclaimIdleMs\(opts\[which\]\)\) \{.*?\n)[ \t]*cur\[0\] = opts\[which\];\n/$1cur[0] = opts[which];\n$1$2/s' \
  || fails=$((fails+1))
mut "M7 the budget field re-kicks mediad on a failed save (S4)" pa \
  's/(if \(!writeBudgetBytes\(b\)\) \{\n.*?\n)([ \t]*return;)/$1                new Thread(() -> sendDaemon("PIN-MATERIALIZE\\n")).start();\n$2/s' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
