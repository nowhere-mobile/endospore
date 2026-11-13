#!/bin/sh
# canary-guard.sh <device> <version> [--without-canary] -- a fleet device publishes <version> only after the canary's
# smoke test passed for it (NWP-20261202-12).
#
# Decided 2026-10-30 (docs/product-decisions.md, "every release is proved on a canary first -- husky joins the release
# devices on a user build, publishes alone, and the rest of the fleet publishes only after its smoke test passes") and
# 2026-11-04 h57 #2 ("nine answers to harvest 57 -- every recommendation accepted"): e4-ota-publish.sh and
# e4-ota-promote.sh run this before any store write. A canary device publishes alone, with no pass file. Any other
# device needs editions/endospore/canary-pass/<version> (format: that directory's README), which the operator writes in
# the publishing checkout after the canary's smoke passes and commits in the marker-bump PR. --without-canary is the
# only bypass; it is logged on stderr, and that line is quoted in the release's worklog row. A malformed pass file
# refuses even with --without-canary (fail closed).
#
#   0  a canary device; a fleet device with a valid pass file for <version>; or no pass file and --without-canary
#   2  no pass file and no flag (refusal), a malformed pass file, no canary-pass directory, or usage / a bad argument
#
# NOWHERE_CANARY_PASS_DIR changes only where it looks (tests). Unset, it reads the canary-pass directory of the checkout
# it runs from, as e4-ota-publish.sh reads ota-mandatory/<version>, so the pass and the calling script come from one tree.
# Writes nothing. POSIX sh: it runs under bash, dash and mksh.
set -u
# The canary devices, a word list (2026-10-30: husky publishes alone, first; long term the canary is named devices, not
# a model).
CANARY_DEVICES="husky"
USAGE="usage: canary-guard.sh <device> <version> [--without-canary]"
case "$#" in
  2 ) WITHOUT="" ;;
  3 ) [ "$3" = --without-canary ] || { echo "$USAGE" >&2; exit 2; }; WITHOUT=1 ;;
  * ) echo "$USAGE" >&2; exit 2 ;;
esac
DEV="$1"
VER="$2"
case "$DEV" in '' | *[!a-z0-9]* ) echo "canary-guard: bad device '$DEV' -- use lowercase alphanumerics" >&2; exit 2 ;; esac
# Digits and dots only first (this also stops a newline, a slash and '..'), then the exact shape.
case "$VER" in '' | *[!0-9.]* ) echo "canary-guard: bad version '$VER' -- use N.N or N.N.N" >&2; exit 2 ;; esac
printf '%s\n' "$VER" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || { echo "canary-guard: bad version '$VER' -- use N.N or N.N.N" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 2
DIR="${NOWHERE_CANARY_PASS_DIR:-$HERE/../canary-pass}"
[ -d "$DIR" ] || { echo "canary-guard: no canary-pass directory at $DIR -- this is not a full checkout; refusing" >&2; exit 2; }
is_canary() { case " $CANARY_DEVICES " in *" $1 "*) return 0 ;; esac; return 1; }
is_canary "$DEV" && exit 0
F="$DIR/$VER"
bad() {
  echo "canary-guard: malformed canary pass $F: $1 -- it must be exactly 'canary <device>', 'build <10 digits>' and 'smoke pass YYYY-MM-DD'; refusing" >&2
  exit 2
}
if [ -e "$F" ] || [ -L "$F" ]; then
  [ -f "$F" ] || bad "not a regular file"
  ! grep -q "$(printf '\r')" "$F" || bad "it holds a CR"
  N=$(grep -c '' "$F")
  [ "$N" = 3 ] || bad "$N line(s), not 3"
  L1=$(sed -n 1p "$F")
  L2=$(sed -n 2p "$F")
  L3=$(sed -n 3p "$F")
  printf '%s\n' "$L1" | grep -Eq '^canary [a-z0-9]+$' || bad "line 1 is not 'canary <device>'"
  is_canary "${L1#canary }" || bad "line 1 names '${L1#canary }', which is not a canary device ($CANARY_DEVICES)"
  printf '%s\n' "$L2" | grep -Eq '^build [0-9]{10}$' || bad "line 2 is not 'build <10 digits>'"
  printf '%s\n' "$L3" | grep -Eq '^smoke pass [0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' || bad "line 3 is not 'smoke pass YYYY-MM-DD'"
  echo "canary-guard: $DEV $VER follows canary ${L1#canary } build ${L2#build }, smoke passed ${L3#smoke pass }"
  exit 0
fi
if [ -n "$WITHOUT" ]; then
  echo "canary-guard: WITHOUT CANARY: $DEV $VER is published with no canary pass (--without-canary)" >&2
  exit 0
fi
echo "refusing: $DEV $VER has no canary pass -- commit editions/endospore/canary-pass/$VER after husky's smoke passes, or pass --without-canary (docs/product-decisions.md, 2026-11-04 h57 #2)" >&2
exit 2
