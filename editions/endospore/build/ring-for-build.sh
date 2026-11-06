#!/bin/sh
# ring-for-build.sh <device> <kind> -- print the ring a build bakes, from ring-record.tsv (NWP-20261104-01, Q006).
#
# WHY. build-device.sh used to take `${NOWHERE_RING:-beta-setup}`: a guess whose wrong answer is silent both ways.
# lynx builds 2026091901/02 shipped beta-setup instead of beta (activation jitter back, device not marked enrolled)
# and only Chester noticed. The record keys the ring on device and build kind (<kind> is release or dev) and a
# NOWHERE_RING that disagrees with it is refused.
#
# stdout carries exactly the ring (an empty line for `none`); every message goes to stderr. Writes nothing.
#   NOWHERE_RING unset or empty  -> the record's ring.   Set and equal -> it.
#   Set and different            -> exit 1, unless NOWHERE_RING_OVERRIDE=1 (then NOWHERE_RING).
#   Set with NOWHERE_RING_OVERRIDE=1, equal or not -> an "override:" line on stderr: build-device.sh's RING_HOW rule.
# RING_RECORD=<path> names another record (for the tests).
#   exit 0  ring printed
#   exit 1  NOWHERE_RING disagrees with the record and there is no override
#   exit 2  usage, bad device/kind/ring name, no or garbled record, no matching row, or a ring with no template
# POSIX sh: it runs under bash, dash and mksh.
set -u

[ "$#" -eq 2 ] || { echo "usage: ring-for-build.sh <device> <release|dev>" >&2; exit 2; }
DEV="$1"; KIND="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
REC="${RING_RECORD:-$HERE/ring-record.tsv}"
TAB=$(printf '\t')

case "$DEV" in '' | *[!a-z0-9]* ) echo "ring-for-build: bad device '$DEV' -- use lowercase alphanumerics" >&2; exit 2 ;; esac
case "$KIND" in release | dev ) ;; *) echo "ring-for-build: bad kind '$KIND' -- release or dev" >&2; exit 2 ;; esac
[ -r "$REC" ] || { echo "ring-for-build: no readable ring record at $REC" >&2; exit 2; }

# Validate the WHOLE record first: a record that is partly garbled cannot be trusted for any key.
EXACT=""; STAR=""; SEEN=" "; N=0
while IFS="$TAB" read -r d k r extra || [ -n "$d" ]; do
  N=$((N + 1))
  case "$d" in '' | '#'*) continue ;; esac
  if [ -n "$extra" ] || [ -z "$k" ] || [ -z "$r" ]; then echo "ring-for-build: record line $N is not three fields" >&2; exit 2; fi
  case "$d" in '*') ;; *[!a-z0-9]*) echo "ring-for-build: record line $N: bad device" >&2; exit 2 ;; esac
  case "$k" in release | dev) ;; *) echo "ring-for-build: record line $N: bad kind" >&2; exit 2 ;; esac
  case "$r" in *[!a-z0-9-]*) echo "ring-for-build: record line $N: bad ring" >&2; exit 2 ;; esac
  case "$SEEN" in *" $d/$k "*) echo "ring-for-build: record line $N repeats $d $k" >&2; exit 2 ;; esac
  SEEN="$SEEN$d/$k "
  if [ "$k" = "$KIND" ]; then
    if [ "$d" = "$DEV" ]; then EXACT="$r"; fi
    if [ "$d" = '*' ]; then STAR="$r"; fi
  fi
done < "$REC"

WANT="$EXACT"
if [ -z "$WANT" ]; then WANT="$STAR"; fi
if [ -z "$WANT" ]; then echo "ring-for-build: no record row for $DEV $KIND in $REC" >&2; exit 2; fi

GIVEN="${NOWHERE_RING:-}"
RING="$WANT"
if [ -z "${NOWHERE_RING:-}" ]; then
  :
elif [ "$GIVEN" = "$WANT" ]; then
  if [ "${NOWHERE_RING_OVERRIDE:-}" = 1 ]; then echo "ring-for-build: override: NOWHERE_RING=$GIVEN (the record says $WANT for $DEV $KIND)" >&2; fi
else
  case "$GIVEN" in *[!a-z0-9-]*) echo "ring-for-build: bad NOWHERE_RING '$GIVEN'" >&2; exit 2 ;; esac
  if [ "${NOWHERE_RING_OVERRIDE:-}" = 1 ]; then
    echo "ring-for-build: override: NOWHERE_RING=$GIVEN (the record says $WANT for $DEV $KIND)" >&2
    RING="$GIVEN"
  else
    echo "ring-for-build: NOWHERE_RING=$GIVEN disagrees with the record: $DEV $KIND bakes '$WANT'." >&2
    echo "  Unset NOWHERE_RING to take the record, or set NOWHERE_RING_OVERRIDE=1 to bake '$GIVEN' on purpose." >&2
    exit 1
  fi
fi

if [ "$RING" = none ]; then
  echo ""
  exit 0
fi
[ -f "$REPO/core/vendor-common/etc/rings/$RING.conf" ] \
  || { echo "ring-for-build: ring '$RING' has no template core/vendor-common/etc/rings/$RING.conf" >&2; exit 2; }
echo "$RING"
