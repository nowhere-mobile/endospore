#!/bin/sh
# support-guard.sh <device> -- refuse a release of a device past GrapheneOS's full support (NWP-20261124-19).
#
# Decided 2026-11-02 (#23, docs/product-decisions.md): no release for a device in GrapheneOS's extended support.
# Releases stop when a device leaves full support. Chester records that by committing
# editions/endospore/support-ended/<device> (format: that directory's README). build-device.sh --release,
# sign-release.sh, e4-ota-publish.sh and e4-ota-promote.sh run this before anything is written or prompted.
# There is no override: deleting the marker in a reviewed commit is the only way back.
#
#   0  no marker for <device>: the device is in full support
#   2  a marker for <device> (refusal), a malformed marker, no support-ended directory, or usage / a bad device name
#
# NOWHERE_SUPPORT_ENDED_DIR changes only where it looks (tests). Unset, it reads the support-ended directory of the
# checkout it runs from, so the marker and the calling script always come from one tree.
# Writes nothing. POSIX sh: it runs under bash, dash and mksh.
set -u
[ "$#" -eq 1 ] || { echo "usage: support-guard.sh <device>" >&2; exit 2; }
DEV="$1"
case "$DEV" in '' | *[!a-z0-9]* ) echo "support-guard: bad device '$DEV' -- use lowercase alphanumerics" >&2; exit 2 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 2
DIR="${NOWHERE_SUPPORT_ENDED_DIR:-$HERE/../support-ended}"
[ -d "$DIR" ] || { echo "support-guard: no support-ended directory at $DIR -- this is not a full checkout; refusing" >&2; exit 2; }
F="$DIR/$DEV"
[ -e "$F" ] || exit 0
bad() {
  echo "support-guard: malformed support-ended marker $F: $1 -- it must be exactly 'ended YYYY-MM-DD' and 'source <text>'; refusing" >&2
  exit 2
}
[ -f "$F" ] || bad "not a regular file"
N=$(grep -c '' "$F")
[ "$N" = 2 ] || bad "$N line(s), not 2"
L1=$(sed -n 1p "$F")
L2=$(sed -n 2p "$F")
printf '%s\n' "$L1" | grep -Eq '^ended [0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' || bad "line 1 is not 'ended YYYY-MM-DD'"
printf '%s\n' "$L2" | grep -Eq '^source [^[:space:]]' || bad "line 2 is not 'source <text>'"
echo "refusing: $DEV left GrapheneOS's full support on ${L1#ended } (editions/endospore/support-ended/$DEV); releases stop there (docs/product-decisions.md, 2026-11-02 #23)" >&2
exit 2
