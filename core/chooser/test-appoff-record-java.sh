#!/usr/bin/env bash
# test-appoff-record-java.sh [--mutate] -- the two writers of files/nowhere-appoff.list read it RAW and STRICTLY
# (NWP-20261025-06).
#
# WHY THIS IS COMMITTED. roamd's appcode_stage_play_dormant reads the raw Off record for the Play-stack lines
# (com.android.vending, gms, gsf) that ProfileActivity.explicitlyTurnedOff filters out for the chooser's own readers
# (NWP-20260830-08); DECIDED 2026-09-26: a user's Off of Play Store keeps its code. recordTurnedOff and clearTurnedOff
# used to read the file through that filtered, swallowing view and write the result back, so the next Off of any app
# deleted the vending line, a re-keep could never retire it, and a read that failed part-way rewrote the file with only
# what it had read -- losing every other Off line. Now both read it raw, and a failed read writes nothing.
#
# WHAT RUNS. core/chooser/tests/appoff-record/run.sh lifts recordTurnedOff, clearTurnedOff, turnedOffLinesRaw,
# clearUninstalled, APPKEEP_LOCK and writeAtomic with its seam from StoreInstaller.java, and keepSetAll,
# explicitlyTurnedOff and the *_PKG constants from ProfileActivity.java, by signature, and runs AppoffRecordCases.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-appoff-record-java.sh            # the cases
#   bash test-appoff-record-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PA0="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
SI0="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
PA="${PA:-$PA0}"
SI="${SI:-$SI0}"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/appoff-record/run.sh"
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
[ -f "$PA" ] && [ -f "$SI" ] && [ -f "$RUN" ] || { echo "FAIL: missing $PA, $SI or $RUN" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# suite <ProfileActivity.java> <StoreInstaller.java> -> 0 pass, 1 a case failed (only this may convict a mutant),
# 2 a member did not extract, 3 the lifted classes did not compile.
suite() { local rc=0; bash "$RUN" "$1" "$2" || rc=$?; return "$rc"; }

echo "== $PA"
suite "$PA" "$SI"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> <lines-that-must-change>
  local d m rc changed; d=$(mktemp -d -p "$W")
  m="$d/StoreInstaller.java"
  if ! perl -0pe "$2" "$SI" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SI" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SI" "$m" | grep -c "^[<>]")
  if [ "$changed" -ne "$3" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected $3"; rm -rf "$d"; return 1; fi
  suite "$PA" "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 recordTurnedOff reads ProfileActivity.explicitlyTurnedOff again" 's/s = turnedOffLinesRaw\(f\);/s = ProfileActivity.explicitlyTurnedOff(ctx);/' 2 || fails=$((fails+1))
mut "M2 recordTurnedOff treats a read error as an empty record" 's/Log\.w\("NowhereChooser", "Off record unreadable[^\n]*\n\s*return;/s = new java.util.LinkedHashSet<>();/' 3 || fails=$((fails+1))
mut "M3 clearTurnedOff reads the filtered view" 's/s = turnedOffLinesRaw\(new File\(ctx\.getFilesDir\(\), "nowhere-appoff\.list"\)\);/s = ProfileActivity.explicitlyTurnedOff(ctx);/' 2 || fails=$((fails+1))
mut "M4 clearTurnedOff treats a read error as an empty record" 's/(static void clearTurnedOff.*?)Log\.w\("NowhereChooser", "Off record unreadable[^\n]*\n\s*return;/$1s = new java.util.LinkedHashSet<>();/s' 3 || fails=$((fails+1))
mut "M5 the raw reader filters the three stack packages" 's/(turnedOffLinesRaw\(File f\).*?)if \(!ln\.isEmpty\(\)\) out\.add\(ln\);/$1if (!ln.isEmpty() && !ProfileActivity.VENDING_PKG.equals(ln) && !ProfileActivity.GMS_PKG.equals(ln) && !ProfileActivity.GSF_PKG.equals(ln)) out.add(ln);/s' 2 || fails=$((fails+1))
mut "M6 recordTurnedOff rewrites even when the package is already listed" 's/if \(!s\.add\(pkg\)\) return;/s.add(pkg);/' 2 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
