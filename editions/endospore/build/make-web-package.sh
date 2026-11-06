#!/usr/bin/env bash
# make-web-package.sh -- build the BROWSER installer package: a whole `super`, flashed from the BOOTLOADER.
# DIA-20260806-08. Usage: make-web-package.sh <release-dir> <device> <build-number>
#
# WHY THIS EXISTS
#
# The web installer used to strand people mid-flash. The factory package ships `super_empty.img`, which
# makes the flasher reboot the phone into fastbootd, run `update-super`, and write the six LOGICAL
# partitions there. fastbootd re-enumerates the phone as a DIFFERENT USB interface, and a Windows machine
# that has never flashed this phone before cannot claim it -- so the browser's device chooser comes up
# EMPTY, halfway through an install, with the phone sitting at a screen the user was not warned about.
# Two testers, two machines, two devices, same stopping point. The only laptop that ever worked was one
# that had already flashed before.
#
# `super` itself is a PHYSICAL partition -- confirmed on hardware, `getvar is-logical:super` -> `no` in the
# bootloader (`is-logical:system` there returns "variable not found", which is the same fact from the other
# side: the bootloader has no concept of logical partitions, and that is exactly why the current layout has
# to detour through fastbootd). Write the whole thing from the bootloader and the detour disappears, on
# every OS, for every user -- rather than being explained in a recovery card.
#
# WHY IT DERIVES INSTEAD OF BUILDING
#
# `script/generate-release.sh` already runs `fastboot optimize-factory-image`, which already emits exactly
# what we need: `<device>-install-<bn>.zip`, containing `super_1.img .. super_N.img` (pre-split sparse
# pieces, each sized to that device's max-download-size) plus a `script.txt` that flashes them with NO
# `reboot fastboot` anywhere. The whole-super-from-the-bootloader flow is therefore not a new idea we are
# inventing -- it is the flow GrapheneOS's own CLI install already uses, and it is proven in-toolchain.
#
# So this script CONSUMES those outputs and touches nothing upstream. That matters:
#   - `script/` is part of the GrapheneOS tree, not our repo -- patches there are clobbered by `repo sync`.
#   - mutating the factory zip in place would silently break `flash-all.sh` (native fastboot classifies
#     partitions by reading `super_empty.img`) and could regress `optimize-factory-image` itself.
#   - OTA is generated from the same target-files and is completely unaffected.
# The original factory zip stays exactly as it is and remains the artifact for CLI installs.
#
# PIECES, NOT ONE super.img: a single super.img is ~3.9 GB (sparse; 8.5 GB raw). Handing that to a browser
# makes the flasher hold multi-GB buffers. Each pre-split piece is <= the device's max-download-size, so the
# flasher's fast path yields one buffer per piece and peak memory stays around ONE piece (~261 MB on lynx)
# regardless of how big the partition is.
#
# The resulting package is BROWSER-ONLY by construction: `flash-all.*` and `fastboot-info.txt` are removed,
# so nothing can feed it to native fastboot and get a half-flash from instructions that name images the
# package no longer contains. Consumed by cmd/storefront's flashZip (nowhere-cloud), which requires either
# this shape or the legacy one and REFUSES to flash anything else.
set -euo pipefail

REL_DIR="${1:?usage: make-web-package.sh <release-dir> <device> <build-number>}"
DEVICE="${2:?usage: make-web-package.sh <release-dir> <device> <build-number>}"
BN="${3:?usage: make-web-package.sh <release-dir> <device> <build-number>}"

IN_FACTORY="$REL_DIR/$DEVICE-factory-$BN.zip"
IN_INSTALL="$REL_DIR/$DEVICE-install-$BN.zip"
OUT="$REL_DIR/$DEVICE-webfactory-$BN.zip"

for f in "$IN_FACTORY" "$IN_INSTALL"; do
  [ -f "$f" ] || { echo "[web-package] MISSING $f -- run script/generate-release.sh first" >&2; exit 1; }
done

# THE PACKAGE MUST NOT CLAIM A BUILD NUMBER THE IMAGE DOES NOT CARRY.
#
# build/envsetup.sh resolves BUILD_NUMBER as
#     ${BUILD_NUMBER:-$(cat $OUT_DIR/soong/build_number.txt || date -u +%Y%m%d00)}
# -- it reads the OUT_DIR's EXISTING build number FIRST. So a warm out dir PINS the build number from the day
# it was created, forever, unless BUILD_NUMBER is exported before `m`. Only a cold out dir picks up today.
#
# The filenames come from this script's $BN argument, so nothing downstream notices the drift: you get
# <device>-webfactory-<new BN>.zip containing an image that identifies as <old BN>. That is how SEVEN distinct
# releases (2026080400 through 2026081000) all shipped images calling themselves 2026072800 -- a fielded
# device's reported build could be any one of them, which guts the issue-reporting channel, the only
# diagnostic available on a locked user build.
#
# Checked here because this is OUR script: script/ belongs to the GrapheneOS tree and is clobbered by repo
# sync, and the ad-hoc per-device build scripts on the box are copy-pasted forward (which is exactly how the
# bug propagated). Fail loudly instead -- the fix is cheap (269 actions, ~2 min: BUILD_NUMBER only invalidates
# build.prop and image assembly, not compilation), but only if you find out before signing.
TF="$REL_DIR/$DEVICE-target_files.zip"
[ -f "$TF" ] || { echo "[web-package] MISSING $TF -- cannot verify the image's build number" >&2; exit 1; }
IMG_BN="$(unzip -p "$TF" VENDOR/build.prop 2>/dev/null | sed -n 's/^ro\.vendor\.build\.fingerprint=.*\/\([^:]*\):user\/.*/\1/p' | head -1)"
[ -n "$IMG_BN" ] || { echo "[web-package] could not read a user build number from $TF -- a non-user (userdebug/eng) image cannot be packaged as a release" >&2; exit 1; }
if [ "$IMG_BN" != "$BN" ]; then
  echo "[web-package] BUILD NUMBER MISMATCH: packaging as '$BN' but the image identifies as '$IMG_BN'." >&2
  echo "[web-package] Rebuild with BUILD_NUMBER exported BEFORE 'source build/envsetup.sh':" >&2
  echo "[web-package]     export OUT_DIR=out-$DEVICE BUILD_NUMBER=$BN" >&2
  echo "[web-package]     source build/envsetup.sh && lunch $DEVICE-cur-user && m target-files-package otatools-package" >&2
  echo "[web-package] then re-run script/finalize.sh + script/generate-release.sh before this script." >&2
  exit 1
fi
echo "[web-package] build number verified: image and package both '$BN'"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[web-package] $DEVICE $BN"
unzip -q "$IN_FACTORY" -d "$WORK/factory"
DIR="$WORK/factory/$DEVICE-factory-$BN"
[ -d "$DIR" ] || { echo "[web-package] factory zip did not contain $DEVICE-factory-$BN/" >&2; exit 1; }
IMGZIP="$(ls "$DIR"/image-*.zip 2>/dev/null | head -1)"
[ -n "$IMGZIP" ] || { echo "[web-package] no nested image-*.zip in the factory zip" >&2; exit 1; }

unzip -q "$IMGZIP" -d "$WORK/img"

# Drop everything the bootloader cannot flash. The six logical partitions live INSIDE super; shipping them
# alongside a whole super would be dead weight at best and a second, conflicting source of truth at worst.
# fastboot-info.txt must go too: it still names `reboot fastboot`, `update-super` and six `flash` lines for
# images that are no longer here, and any native consumer that reads it would act on all of them.
rm -f "$WORK"/img/super_empty.img
rm -f "$WORK"/img/{system,system_ext,system_dlkm,product,vendor,vendor_dlkm,odm,odm_dlkm}.img
rm -f "$WORK"/img/fastboot-info.txt

# The pre-split sparse pieces, flattened out of the install zip's directory prefix.
unzip -q -j "$IN_INSTALL" '*/super_*.img' -d "$WORK/img"
PARTS=$(ls "$WORK"/img/super_*.img 2>/dev/null | wc -l)
[ "$PARTS" -ge 1 ] || { echo "[web-package] no super_N.img pieces in $IN_INSTALL" >&2; exit 1; }

# The pieces are a SEQUENCE: piece k covers the blocks piece k-1 did not. A gap does not fail the flash --
# it writes a super with a hole in it and the phone simply will not boot. Verify 1..N are all present.
for i in $(seq 1 "$PARTS"); do
  [ -f "$WORK/img/super_$i.img" ] || { echo "[web-package] super_$i.img missing -- pieces are not contiguous 1..$PARTS" >&2; exit 1; }
done

# Every piece must be a real sparse image. The sparse magic is 0xED26FF3A, which stored little-endian puts
# `3a ff 26 ed` on disk -- read the bytes in file order, not in the order the constant is written. A raw or
# truncated piece would make the flasher hold the whole thing in memory and then fail verification.
for f in "$WORK"/img/super_*.img; do
  magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
  [ "$magic" = "3aff26ed" ] || { echo "[web-package] $(basename "$f") is not a sparse image (magic=$magic)" >&2; exit 1; }
done

# Boot-critical images must have survived -- if a filter above ever over-matches, this catches it here
# rather than on a phone that flashed "successfully" and won't boot.
for req in boot.img vbmeta.img; do
  [ -f "$WORK/img/$req" ] || { echo "[web-package] $req missing from the image set" >&2; exit 1; }
done

rm -f "$IMGZIP"
( cd "$WORK/img" && zip -q -r "$IMGZIP" . )

# Browser-only by construction: native fastboot must not be able to run this package half-way.
rm -f "$DIR"/flash-all.sh "$DIR"/flash-all.bat

rm -f "$OUT"
( cd "$WORK/factory" && zip -q -r "$OUT" "$DEVICE-factory-$BN" )

echo "[web-package] super pieces : $PARTS (sparse, verified contiguous)"
echo "[web-package] wrote        : $OUT ($(stat -c %s "$OUT") bytes)"
echo "[web-package] factory zip  : $IN_FACTORY (UNCHANGED -- still the CLI artifact)"

# --- manifest.json (task #94) ------------------------------------------------------------------------------
# Until now the installer manifest was HAND-AUTHORED at publish time -- which is how publishing frankel
# 2026080601 failed five different ways on 2026-08-06, and how a release reported "complete" on 2026-08-11
# while the installer kept serving builds from days earlier. This is the only place that has the artifact,
# its hashes, and the device's PUBLIC AVB key together, so the manifest is emitted here, describing the zip
# just written. The remaining operator steps are then exactly two, and both cross-check rather than trust:
#     release sign -manifest <this file> -key <offline release key>          # the key box
#     publish-installer.sh endospore <dev> <webfactory zip> <manifest> <sig> # the storefront; it re-hashes
#
# The version segment in the image URL is decoration on the storefront's disk path (installer.go reads the
# flat <dir>/endospore/<device>/), but it is REAL in the browser/CDN cache key under immutable+max-age=1y,
# so it must move with every BUILD -- same-day re-cuts included. It is therefore the WHOLE build number,
# counter and all (NWP-20261011-06): the date-only form shipped before it rendered 2026091306 and
# 2026091307 as one segment, so a second cut on the same day would publish a new zip, pinned by a new
# signed sha256, at a URL every edge already held for a year, and the install page would fetch the stale
# body and fail its hash check (NWP-20260913-14). The BN is the right key because the guard above proved
# it is what the image itself says; the shape check next to REL_VER keeps a malformed BN from minting a
# segment that does not mean what it says. The live 2026081002 manifests carried a hand-typed version
# ("2026.08.11") that matched neither the build date nor the OS's self-reported version -- deriving here
# ends that class.
case "$DEVICE" in
  lynx)     LABEL="Pixel 7a"  ;;
  tegu)     LABEL="Pixel 9a"  ;;
  frankel)  LABEL="Pixel 10"  ;;
  stallion) LABEL="Pixel 10a" ;;
  husky)    LABEL="Pixel 8 Pro" ;;
  *) echo "[web-package] no display label for '$DEVICE' -- add one line to the case in $0. Deliberate hard stop: the label prints on the public install page." >&2; exit 1 ;;
esac

# sha256(avb_pkmd.bin) -- the PUBLIC key only; verified 2026-08-13 to match all three live manifests. The
# page shows it so a relocking user can compare against what their bootloader reports. Never derived from
# avb.pem: that file is the passphrase-encrypted PRIVATE key and this script must not touch it.
AVB_PKMD="${KEYS_DIR:-$REL_DIR/../../../keys/$DEVICE}/avb_pkmd.bin"
[ -f "$AVB_PKMD" ] || { echo "[web-package] $AVB_PKMD missing -- cannot pin avb_key_sha256" >&2; exit 1; }
AVB_SHA=$(sha256sum "$AVB_PKMD" | cut -d' ' -f1)

OUT_SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
OUT_LEN=$(stat -c %s "$OUT")
# URL segment = the WHOLE build number, counter included; see the comment above the device-label case.
case "$BN" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "[web-package] BN '$BN' is not 10 digits (YYYYMMDDNN) -- refusing to derive a URL segment from it" >&2; exit 1 ;;
esac
REL_VER="${BN:0:4}.${BN:4:2}.${BN:6:2}.${BN:8:2}"
MANIFEST="$REL_DIR/$DEVICE-manifest-$BN.json"

# NWP-20261011-05: the release's OTA metadata -- the OS version the image bakes and whether installing it is mandatory
# (editions/endospore/ota-mandatory/<version>, committed before the build). It rides THIS manifest because this is the
# file the operator already signs with the release key, and that signature is what a phone checks before it shows a
# word of the reason. The version comes from the image, never the tree: the tree may have moved since the build.
OTA_VER="$(unzip -p "$TF" SYSTEM/etc/nowhere-ota-version 2>/dev/null | tr -d '[:space:]')"
[ -n "$OTA_VER" ] || { echo "[web-package] could not read SYSTEM/etc/nowhere-ota-version from $TF" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
OTA_JSON="$(bash "$HERE/ota-release-fields.sh" "$OTA_VER" "$HERE/../ota-mandatory/$OTA_VER")" \
  || { echo "[web-package] the release's OTA metadata is not valid (above)" >&2; exit 1; }
echo "[web-package] ota          : $OTA_JSON"

cat > "$MANIFEST" <<EOF
{
  "edition": "endospore",
  "device": {
    "product": "$DEVICE",
    "label": "$LABEL",
    "codename": "$DEVICE"
  },
  "version": "$REL_VER",
  "build": "$BN",
  "recipe": "factory-zip",
  "avb_key_sha256": "$AVB_SHA",
  "images": [
    {
      "partition": "factory",
      "url": "/install/endospore/$DEVICE/$REL_VER/img/factory.zip",
      "size": $OUT_LEN,
      "sha256": "$OUT_SHA"
    }
  ],
  "flash": {
    "unlock_required": true,
    "wipe_on_unlock": true,
    "target_slot": "current",
    "reboot": true,
    "relock": true
  },
  "min_installer": "1.0.0",
  "notes": "signed release — the page verifies the .sig against the baked-in release key before flashing.",
  "ota": $OTA_JSON
}
EOF

# A manifest that does not parse is a signature request for garbage; release sign would also catch it, but
# catch it here, before the file leaves the box it was generated on.
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFEST" \
  || { echo "[web-package] generated manifest does not parse as JSON: $MANIFEST" >&2; exit 1; }

echo "[web-package] manifest     : $MANIFEST"
echo "[web-package] next (key box): release sign -manifest $MANIFEST -key <offline release key>"
echo "[web-package] then (storefront): publish-installer.sh endospore $DEVICE $OUT $MANIFEST $MANIFEST.sig"
echo "[web-package] and (build host): copy $(basename "$MANIFEST").sig back beside $MANIFEST -- e4-ota-publish.sh publishes the signed manifest with the OTA (NWP-20261011-05)"
