#!/bin/sh
# ota-field-guard.sh <device> <stamp> <store-conf> <agent> -- refuse a release stamp the field already has (NWP-20261101-06).
#
# WHY. A device is offered an update only when semverLess(running, published), and e4-ota-publish.sh refuses any marker
# that is not exactly the stamp baked into the image it publishes. So a second build carrying a version already published
# is UNREACHABLE over the air: on 2026-08-18 the #732 hotfix baked 0.5.4, the version frankel already ran, was published,
# and was never offered to the one device that needed it. The version stays hand-bumped; this makes forgetting it a refusal
# at the START of build-device.sh --release, before the passphrase prompt, instead of a dead release.
#
# WHAT. Reads the marker of every ring for <device> -- stable, each distinct OTA_RING= in
# core/vendor-common/etc/rings/*.conf, and each retired ring in RETIRED_RINGS whose marker may still be published
# (beta, Q002) -- the way e4-ota-publish.sh `read_ring` does (a copy: same regexes, same three
# outcomes, present / absent / unreadable; that script was itself copied from e4-ota-promote.sh). <stamp> must be strictly
# above the highest present marker.
#   exit 0  stamp is above every published marker (or nothing is published)
#   exit 1  stamp is not above a published marker
#   exit 2  usage error, a bad ring name, or a ring that could not be read (an unreadable marker cannot be compared)
# The store conf is sourced only inside a subshell and never printed. POSIX sh: it runs under bash, dash and mksh.
set -u

[ "$#" -eq 4 ] || { echo "usage: ota-field-guard.sh <device> <stamp> <store-conf> <agent>" >&2; exit 2; }
DEV="$1"; STAMP="$2"; CONF="$3"; AGENT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

case "$DEV" in '' | *[!a-z0-9]* ) echo "ota-field-guard: bad device '$DEV' -- use lowercase alphanumerics" >&2; exit 2 ;; esac
printf '%s\n' "$STAMP" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  || { echo "ota-field-guard: stamp '$STAMP' is not a semver" >&2; exit 2; }
[ -f "$CONF" ] || { echo "ota-field-guard: no store conf at $CONF" >&2; exit 2; }
[ -x "$AGENT" ] || { echo "ota-field-guard: no agent at $AGENT" >&2; exit 2; }

vlt() { [ "$1" = "$2" ] && return 1; [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }  # $1 < $2 ?

# The rings: stable, then every distinct OTA_RING value the tree's ring confs name, then the retired ones.
RINGS="stable"
for f in "$REPO"/core/vendor-common/etc/rings/*.conf; do
  [ -f "$f" ] || continue
  # The R: prefix keeps a trailing empty assignment alive: command substitution strips trailing newlines.
  # One complete line per value, validated whole: word-splitting here would let `beta bad` pass as two rings.
  grep -q '^OTA_RING=' "$f" || continue
  vals="$(grep -h '^OTA_RING=' "$f" | sed 's/^OTA_RING=/R:/' | tr -d "\"'")"
  while IFS= read -r r; do
    r="${r#R:}"
    case "$r" in
      '' | *[!a-z0-9]* ) echo "ota-field-guard: bad OTA_RING '$r' in $f -- use lowercase alphanumerics; refusing" >&2; exit 2 ;;
    esac
    case " $RINGS " in *" $r "*) ;; *) RINGS="$RINGS $r" ;; esac
  done <<EOF
$vals
EOF
done

# Retired rings, read while a marker may still exist. Q002 (docs/product-decisions.md, 2026-10-20) retired the device ring
# and NWP-20261105-11 took OTA_RING= out of the ring confs, but ota/<dev>/version-beta stays in the store until Chester
# levels it (e4-ota-promote.sh <store-conf> --device <dev> --from stable --to beta) or deletes it. An absent marker is
# skipped as today (read_ring 3), so this entry costs nothing after a delete. A later staged-rollout ring with its own
# conf is still read from that conf's OTA_RING= line, above.
RETIRED_RINGS="beta"
for r in $RETIRED_RINGS; do
  case " $RINGS " in *" $r "*) ;; *) RINGS="$RINGS $r" ;; esac
done

# read_ring <ring>: prints the version; return 0 present, 3 absent, 4 unreadable.
read_ring() {
  case "$1" in stable) vref="ota/$DEV/version" ;; *) vref="ota/$DEV/version-$1" ;; esac
  res="$( ( . "$CONF"; export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
            o="$(NOWHERE_OTA_VERSION_REF="$vref" "$AGENT" ota-check s3 2>/dev/null)"; c=$?
            printf 'RC=%s\n%s\n' "$c" "$o" ) 2>/dev/null )"
  rc="$(printf '%s\n' "$res" | sed -n '1s/^RC=//p')"
  out="$(printf '%s\n' "$res" | sed '1d')"
  re=""
  case "$rc" in
    0) re='^ota-check: UPDATE -> [0-9]+\.[0-9]+(\.[0-9]+)?$' ;;
    1) re='^ota-check: UPTODATE \(latest [0-9]+\.[0-9]+(\.[0-9]+)?\)$' ;;
    3) if printf '%s\n' "$out" | grep -qxF 'ota-check: no published OS version'; then return 3; fi ;;
  esac
  if [ -n "$re" ]; then
    line="$(printf '%s\n' "$out" | grep -E "$re" | tail -1)"
    if [ -n "$line" ]; then
      printf '%s\n' "$line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1
      return 0
    fi
  fi
  return 4
}

MAX=""; MAXRING=""
for ring in $RINGS; do
  if cur="$(read_ring "$ring")"; then
    echo "ota-field-guard: $DEV '$ring' ring publishes $cur"
    if [ -z "$MAX" ] || vlt "$MAX" "$cur"; then MAX="$cur"; MAXRING="$ring"; fi
  else
    case $? in
      3) echo "ota-field-guard: $DEV '$ring' ring has no published version" ;;
      *) echo "ota-field-guard: could not read the '$ring' ring -- refusing; an unreadable marker cannot be compared" >&2; exit 2 ;;
    esac
  fi
done

if [ -n "$MAX" ] && ! vlt "$MAX" "$STAMP"; then
  echo "refusing --release: the tree stamp $STAMP is not above $MAX, already published on '$MAXRING' for $DEV -- bump core/vendor-common/etc/nowhere-ota-version in its own PR" >&2
  exit 1
fi
echo "ota-field-guard: stamp $STAMP is above every published marker for $DEV (${MAX:-none published})"
