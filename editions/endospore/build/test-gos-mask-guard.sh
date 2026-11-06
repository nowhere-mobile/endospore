#!/usr/bin/env bash
# test-gos-mask-guard.sh -- exercise gos-chooser-grant.sh's carry-mask assertion (NWP-20261014-38).
#
# The assertion refuses a build whose upstream GosPackageStateFlag enum no longer holds every index in
# GosState.MASK (the editor is atomic: one retired index makes a package's whole apply write nothing). Its
# value is entirely in the refusal, which never fires on a healthy tree -- so this builds a fixture enum and a
# fixture GosState and runs the REAL patch script against them. The script is copied into a scratch repo layout
# (it resolves GosState.java relative to itself), so the fixture GosState is the one it reads.
#
#   bash test-gos-mask-guard.sh             # the behaviour cases
#   bash test-gos-mask-guard.sh --mutate    # ... plus mutants of the script that must each be CONVICTED
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/patches/gos-chooser-grant.sh}"
[ -f "$SRC" ] || { echo "no such script: $SRC"; exit 2; }
REAL_STATE="$HERE/../../../core/chooser/src/com/nowhere/chooser/GosState.java"
[ -f "$REAL_STATE" ] || { echo "no such GosState: $REAL_STATE"; exit 2; }
export TMPDIR="${TMPDIR:-$HOME}"

enum_fixture() {  # $1 = file; live {0,1,5,6..24,26,27,28}; 2/3/4/25 only inside comments
  {
    echo 'package app.grapheneos.fixture;'
    echo '/* retired: OLD_BLOCK = 25; */'
    echo 'public enum GosPackageStateFlag {'
    echo '    // RETIRED_A = 2; RETIRED_B = 3;'
    echo '    FLAG_0 = 0, FLAG_1 = 1,'
    echo '    /* RETIRED_C = 4, */'
    for i in 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 26 27 28; do echo "    FLAG_$i = $i,"; done
    echo '}'
  } > "$1"
}

SCRATCH=$(mktemp -d) || exit 2
trap 'rm -rf "$SCRATCH"' EXIT

run_suite() {  # $1 = script under test -> sets SUITE_FAIL
  local f="$1" pass=0 fail=0 n=0 repo tree out rc
  one() {  # name, want_rc, want_substring, [absent_substring]
    local ok=1
    [ "$rc" = "$2" ] || ok=0
    grep -qF -- "$3" <<<"$out" || ok=0
    if [ -n "${4:-}" ] && grep -qF -- "$4" <<<"$out"; then ok=0; fi
    if [ "$ok" = 1 ]; then pass=$((pass+1)); [ "$QUIET" = 1 ] || printf "  PASS  %-46s rc=%s\n" "$1" "$rc"
    else fail=$((fail+1)); [ "$QUIET" = 1 ] || printf "  FAIL  %-46s rc=%s (want %s, %s)\n%s\n" "$1" "$rc" "$2" "$3" "$out"; fi
  }
  fresh() {  # builds a scratch repo + tree; the grant target already carries the marker (the skip path)
    n=$((n+1)); repo="$SCRATCH/$n/repo"; tree="$SCRATCH/$n/tree"
    mkdir -p "$repo/editions/endospore/build/patches" "$repo/core/chooser/src/com/nowhere/chooser" \
             "$tree/frameworks/base/services/core/java/com/android/server/pm" \
             "$tree/frameworks/base/core/java/android/ext"
    cp "$f" "$repo/editions/endospore/build/patches/gos-chooser-grant.sh"
    cp "$REAL_STATE" "$repo/core/chooser/src/com/nowhere/chooser/GosState.java"
    enum_fixture "$tree/frameworks/base/core/java/android/ext/GosPackageStateFlag.java"
    echo '.apply("com.nowhere.chooser", computer);' > "$tree/frameworks/base/services/core/java/com/android/server/pm/GosPackageStatePermissions.java"
  }
  go() { out=$(bash "$repo/editions/endospore/build/patches/gos-chooser-grant.sh" "$tree" 2>&1); rc=$?; }
  flagfile() { echo "$tree/frameworks/base/core/java/android/ext/GosPackageStateFlag.java"; }

  # the real mask: sanity that the fixture and the shipped constant agree
  fresh; go
  one "(a) live fixture passes, reports the tell"    0 "mask 0x1ffffc2 ⊆ live flag indices (25 constants)"
  one "(a) the assertion runs BEFORE the skip exit"  0 "chooser grant already present -- skipped"

  fresh; sed -i '/FLAG_10 = 10,/d' "$(flagfile)"; go
  one "(b) index 10 retired -> exit 2, names bit 10" 2 "MASK BIT 10 "
  one "(b) ... and points at the Rebase watch"       2 "Rebase watch" "already present"

  fresh; sed -i 's/FLAG_24 = 24,/FLAG_25 = 25,/' "$(flagfile)"; go
  one "(c) 25 defined, 24 dropped -> exit 2, bit 24" 2 "MASK BIT 24 "

  fresh; rm -f "$(flagfile)"; go
  one "(d) missing flag file -> exit 2"              2 "CANNOT DETERMINE"

  fresh; mkdir -p "$tree/frameworks/base/other"; cp "$(flagfile)" "$tree/frameworks/base/other/GosPackageStateFlag.java"; go
  one "(d2) two flag files -> exit 2"                2 "CANNOT DETERMINE"

  fresh; sed -i 's/static final long MASK = /static final long MASKED = /' "$repo/core/chooser/src/com/nowhere/chooser/GosState.java"; go
  one "(e) GosState without MASK -> exit 2"          2 "CANNOT DETERMINE the carry mask"

  fresh
  sed -i 's/0x1FFFFC2L/0x1FFFFFAL/' "$repo/core/chooser/src/com/nowhere/chooser/GosState.java"
  sed -i 's/FLAG_28 = 28,/FLAG_28 = 28, \/\/ X = 3;/' "$(flagfile)"; go
  one "(f) commented 'X = 3;' is not live (bit 3)"   2 "MASK BIT 3 "

  SUITE_FAIL=$fail
  [ "$QUIET" = 1 ] || { echo; echo "  PASS=$pass FAIL=$fail"; }
  [ "$fail" = 0 ]
}

QUIET=0
echo "mask assertion ($SRC):"
run_suite "$SRC"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "mutations (each must CONVICT the suite above):"
W=$(mktemp); MRC=0
mutate() {  # name, python-or-sed transform via $2 (sed expr), which cases catch it
  cp "$SRC" "$W"; sed -i "$2" "$W"
  if cmp -s "$SRC" "$W"; then
    printf "  ⚠ NOT APPLIED  %-38s -- the expression matched nothing; this mutation proves NOTHING\n" "$1"
    MRC=1; return
  fi
  QUIET=1 SUITE_FAIL=0
  run_suite "$W" >/dev/null 2>&1
  if [ "${SUITE_FAIL:-0}" -gt 0 ]; then
    printf "  CONVICTED     %-38s (%s case(s) failed; via %s)\n" "$1" "$SUITE_FAIL" "$3"
  else
    printf "  ⚠ SURVIVED    %-38s -- the suite does not actually test this\n" "$1"
    MRC=1
  fi
  QUIET=0
}

mutate "comment stripping removed"          "s|^src = re.sub(r'/\\\\\*.*|pass|;s|^src = re.sub(r'//.*|pass|"  "(f) commented constants"
mutate "missing file exit 2 -> 0"           's|^  exit 2$|  exit 0|'                                           "(d)/(d2)"
mutate "subset test inverted"               's/and b not in live:/and b in live:/'                           "(a)-(c)"
mutate "check moved after the skip exit"    '/^T="\${1:?usage/a grep -q com.nowhere.chooser "$T/frameworks/base/services/core/java/com/android/server/pm/GosPackageStatePermissions.java" \&\& { echo "already present -- skipped"; exit 0; }'  "(b)/(c) rc"
rm -f "$W"
echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
