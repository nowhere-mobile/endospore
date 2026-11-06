#!/bin/sh
# assert-baked-ring.sh <staged-etc> <ring> <repo> -- check the stage baked exactly this build's ring (NWP-20261104-01, Q006).
#
# WHY. stage-vendor.sh only LOGS the ring it baked; nothing checked it (lynx 2026091901/02 shipped the wrong ring). <ring>
# may be empty, meaning "no ring": then no nowhere.conf may be staged.
#   Empty ring: CONTROL at least one os-ref-* is staged (so a wrong path cannot pass as "no conf"); CHECK no nowhere.conf.
#   Ring set:   CONTROL the staged nowhere.conf is byte-identical to rings/<ring>.conf (a check that compared nothing
#               cannot pass); MARKER beta needs GATEWAY_URL and no NOWHERE_GATEWAY_DEFAULT, beta-setup the reverse, any other
#               ring exactly one of the two.
#   exit 0  ok    exit 1  mismatch    exit 2  usage
# POSIX sh: it runs under bash, dash and mksh. Writes nothing.
set -u

[ "$#" -eq 3 ] || { echo "usage: assert-baked-ring.sh <staged-etc> <ring> <repo>" >&2; exit 2; }
ETC="$1"; RING="$2"; REPO="$3"
[ -d "$ETC" ] || { echo "assert-baked-ring: $ETC is not a directory" >&2; exit 2; }

if [ -z "$RING" ]; then
  FOUND=0
  for f in "$ETC"/os-ref-*; do [ -f "$f" ] && FOUND=1; done
  [ "$FOUND" = 1 ] || { echo "assert-baked-ring: no os-ref-* staged in $ETC -- wrong path, nothing was checked" >&2; exit 1; }
  [ -e "$ETC/nowhere.conf" ] && { echo "assert-baked-ring: build has no ring but $ETC/nowhere.conf is staged" >&2; exit 1; }
  echo "assert-baked-ring: no ring, no nowhere.conf staged"
  exit 0
fi

case "$RING" in *[!a-z0-9-]*) echo "assert-baked-ring: bad ring '$RING'" >&2; exit 2 ;; esac
TPL="$REPO/core/vendor-common/etc/rings/$RING.conf"
[ -f "$TPL" ] || { echo "assert-baked-ring: no template $TPL" >&2; exit 2; }
[ -f "$ETC/nowhere.conf" ] || { echo "assert-baked-ring: ring '$RING' but no nowhere.conf staged in $ETC" >&2; exit 1; }
cmp -s "$ETC/nowhere.conf" "$TPL" || { echo "assert-baked-ring: staged nowhere.conf differs from its template for ring '$RING'" >&2; exit 1; }

GU=$(grep -c '^GATEWAY_URL=' "$ETC/nowhere.conf")
GD=$(grep -c '^NOWHERE_GATEWAY_DEFAULT=' "$ETC/nowhere.conf")
case "$RING" in
  beta)       if [ "$GU" -ge 1 ] && [ "$GD" -eq 0 ]; then M=GATEWAY_URL; else M=""; fi ;;
  beta-setup) if [ "$GD" -ge 1 ] && [ "$GU" -eq 0 ]; then M=NOWHERE_GATEWAY_DEFAULT; else M=""; fi ;;
  *)          if [ $((GU + GD)) -eq 1 ]; then M=either; else M=""; fi ;;
esac
[ -n "$M" ] || { echo "assert-baked-ring: ring '$RING' has the wrong gateway key (GATEWAY_URL=$GU NOWHERE_GATEWAY_DEFAULT=$GD)" >&2; exit 1; }
echo "assert-baked-ring: ring '$RING' baked, matches its template ($M)"
