#!/usr/bin/env bash
# E.4 -- Endospore OTA publish (build host). Seals a signed lynx A/B OTA payload into the SAME content-
# addressed store as user data, under the Pixel edition's OWN ref (os-lynx), and marks the version -- so a
# relocked Endospore device's nowhere_otad pulls it (CDC, delta via the chunk cache) and update_engine
# applies it, with NO GrapheneOS update server. Mirrors the FP3 editions/diaspore/build/p4.4b-ota-cdc.sh,
# adapted for lynx + the per-edition os-ref / version-ref (os-lynx -> ota/lynx/version; see
# core/vendor-common/bin/nowhere_otad.sh OSREF + the agent's otaVersionRef()).
#
# Usage: e4-ota-publish.sh --device <dev> [--ring <name>|--beta] [--stable-current] [--force] [--without-canary] <<dev>-ota_update-<BN>.zip> <version eg 0.2.0> <store-conf> [agent_host]
#   <ota_update zip>  signed A/B OTA from generate-release: releases/<BN>/release-<dev>-<BN>/<dev>-ota_update-<BN>.zip
#   <version>         semver to publish; MUST EQUAL the version baked into that image
#                     (read from <dev>-target_files.zip beside the OTA zip; see the check below)
#   --device <dev>    REQUIRED, no default (NWP-20260901-08). Which device/edition to publish for. Sets BOTH
#                     the payload ref (os-<dev>, what nowhere_otad restores) and the marker (ota/<dev>/version).
#                     Publishing frankel/tegu/stallion was IMPOSSIBLE before this flag existed -- and then, for
#                     as long as it defaulted to lynx, OMITTING it published their images to the lynx fleet.
#   <store-conf>      a file with the S3_* creds for the store (R2; same store/bucket the device uses)
#   [agent_host]      native-linux agent build (default /tmp/agent_host); build it once with:
#                       (cd core/agent && CGO_ENABLED=0 GOOS=linux go build -o /tmp/agent_host .)
#   --first-notes     NWP-20261006-12: this release STARTS the notes chain -- its `previous` version has no published
#                     notes (only 0.5.43, the first release with them). Without it the publish refuses a release whose
#                     previous version's notes are not in the store, so the chain a phone walks cannot break silently.
#   (no flag)         NWP-20261011-05: the SIGNED installer manifest <dev>-manifest-<BN>.json + its .sig, read from beside
#                     the OTA zip, carries whether the release is mandatory. Copy the .sig back from the operator machine
#                     first; a release flagged in editions/endospore/ota-mandatory/<version> is refused without it.
#   --ring <name>     STAGED ROLLOUT (#83): which version marker to advance. Default "stable" writes the
#     (or --beta)     general marker ota/lynx/version -- every device picks it up on its next ota-check.
#                     "--ring beta" (== --beta) writes ota/lynx/version-beta instead, so ONLY opted-in canary
#                     devices see it. The general MARKER stays on the current release, but the OS payload
#                     (os-lynx) is pushed EITHER way and is ONE head for every ring: a stable phone behind the
#                     stable marker that checks now downloads and installs THIS build (nowhere_otad.sh never
#                     compares the payload with the offered version). So a ring other than stable is REFUSED,
#                     before the agent is run and before any store call, unless --stable-current attests that every
#                     stable phone runs the current stable release (NWP-20261112-18) -- until Q126's per-release
#                     payload is built (docs/backlog.md section E, "The OS payload ref os-<dev> is one head ...").
#                     Promote-to-all is a marker copy: e4-ota-promote.sh (no re-upload).
#   --stable-current  NWP-20261112-18: the operator's word that every stable phone runs the current stable release,
#                     which a ring publish needs (above). Accepted and ignored on a stable publish.
#   --force           NWP-20261026-04: allow a marker move that is NOT forward -- publishing a version LOWER than the
#                     one the ring already offers (a deliberate rollback). Without it that is refused. It never
#                     overrides an UNREADABLE ring marker: a marker that cannot be read cannot be compared.
#   --without-canary  NWP-20261202-12: publish a fleet device with no canary pass for <version>. Without it a device
#                     that is not the canary (husky) is refused until editions/endospore/canary-pass/<version> records
#                     the canary's passed smoke test (canary-guard.sh). Chester's call only; the guard logs it on stderr.
#
# After publishing, on the device (or via the gate "Check for updates"): nowhere_otad ota-checks ota/lynx/version,
# CDC-restores os-lynx into /data/ota_package, and update_engine applies it -> reboots into the new slot, yellow,
# /data intact. (The chunk cache makes a later v2->v3 fetch only the changed chunks.)
#
# Staged-rollout flow: publish --beta -> verify on a canary (point it at ota/lynx/version-beta; see
# docs/ota-staged-rollout.md) -> e4-ota-promote.sh to copy the beta marker to the general ring.
set -euo pipefail

# Pull the ring flag out of the arg list first, so the positional args below stay backward-compatible
# (a caller with no --ring keeps the exact old signature and the old "stable" behaviour).
RING=stable
# NWP-20260901-08: NO DEFAULT. This used to be `DEV=lynx`, "so the pair reads the same way" as
# e4-ota-promote.sh -- and that convenience is the whole footgun. The natural invocation (the one in every
# doc example and every muscle-memory paste) omits --device, so publishing frankel silently pushed a frankel
# payload under os-lynx and marked ota/lynx/version: a frankel image offered to every lynx device.
#
# ⚠ AND THE IMAGE-STAMP GUARD BELOW CANNOT BACK THIS UP -- it is DISABLED BY IT. That guard only runs when
# IMG_STAMP is non-empty, and IMG_STAMP is read from "$DEV-target_files.zip" beside the OTA zip. Get the
# device wrong and the file is looked for under the WRONG NAME, is not found, IMG_STAMP is empty, and the
# exact-match check is skipped entirely. Filed 2026-08-20 after publishing frankel 0.5.6: what actually
# stopped it was incidental -- the fallback tree-stamp check happened to refuse "0.5.6 not > 0.5.6". Had the
# version been one above the tree stamp, the frankel payload would have gone out under os-lynx.
DEV=""
FIRST_NOTES=0
FORCE=0
STABLE_CURRENT=0
WITHOUT_CANARY=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --beta)     RING=beta ;;
    --ring)     RING="${2:?--ring needs a name, e.g. beta}"; shift ;;
    --ring=*)   RING="${1#--ring=}" ;;
    --device)   DEV="${2:?--device needs a name, e.g. frankel}"; shift ;;
    --device=*) DEV="${1#--device=}" ;;
    --first-notes) FIRST_NOTES=1 ;;
    --force)    FORCE=1 ;;
    --stable-current) STABLE_CURRENT=1 ;;
    --without-canary) WITHOUT_CANARY=1 ;;
    *)          POS+=("$1") ;;
  esac
  shift
done
set -- "${POS[@]}"
case "$DEV" in
  '' ) echo "refusing: --device is REQUIRED (e.g. --device frankel)."
       echo "          usage: e4-ota-publish.sh --device <dev> [--ring <name>|--beta] [--stable-current] [--force] [--without-canary] <<dev>-ota_update-<BN>.zip> <version> <store-conf> [agent_host]"
       echo "          It sets BOTH the payload ref (os-<dev>) and the marker (ota/<dev>/version). There is no"
       echo "          default on purpose: guessing it wrong publishes one device's image to another's fleet,"
       echo "          and the image-stamp guard below cannot catch that -- a wrong device makes it look for"
       echo "          <dev>-target_files.zip under the wrong name, find nothing, and skip itself."
       exit 2 ;;
  *[!a-z0-9]* ) echo "bad --device '$DEV' -- use lowercase alphanumerics (e.g. frankel)"; exit 2 ;;
esac
# NWP-20261124-19 (#23): no release for a device past GrapheneOS's full support (editions/endospore/support-ended/).
sh "$(dirname "$0")/support-guard.sh" "$DEV" || exit 2

OTAZIP="${1:?usage: e4-ota-publish.sh --device <dev> [--ring <name>|--beta] [--stable-current] [--force] [--without-canary] <ota_update zip> <version> <store-conf> [agent_host]}"
VERSION="${2:?need <version> (semver, strictly > the baked device stamp; enforced below)}"
CONF="${3:?need <store-conf with S3_* creds>}"
AGENT="${4:-/tmp/agent_host}"
# NWP-20261202-12 (docs/product-decisions.md, 2026-11-04 h57 #2): a fleet device publishes <version> only after husky's
# smoke passed for it (editions/endospore/canary-pass/<version>, read from this checkout), or with --without-canary,
# logged. Before the agent is run and before any store call.
sh "$(dirname "$0")/canary-guard.sh" "$DEV" "$VERSION" ${WITHOUT_CANARY:+--without-canary} || exit 2
# ⚠ OSREF WAS HARDCODED os-lynx (and DEV derived FROM it), so this script could only ever publish for lynx.
# The device pulls the ref baked at /system/etc/nowhere/os-ref (nowhere_otad.sh:20) -- os-frankel on frankel --
# so no frankel/tegu/stallion payload was ever pushed and ota/<dev>/version was never marked: those devices
# correctly reported "no update" forever. Worse, running this with ANOTHER device's OTA zip pushed THAT image
# under os-lynx and marked ota/lynx/version -- offering a frankel build to lynx devices. Derive both from $DEV.
OSREF="os-$DEV" ; OSPASS=nowhere-os
case "$RING" in
  stable)             VREF="ota/$DEV/version" ;;     # general ring: the marker every device reads by default
  '' | *[!a-z0-9]* )  echo "bad --ring '$RING' -- use lowercase alphanumerics (e.g. beta)"; exit 2 ;;
  *)                  VREF="ota/$DEV/version-$RING" ;;  # canary ring: only opted-in devices read this marker
esac
export NOWHERE_OTA_VERSION_REF="$VREF"               # agent ota-mark writes THIS ring's marker (otaVersionRef override)
# NWP-20261112-18: THE PAYLOAD IS ONE HEAD FOR EVERY RING. A ring publish pushes os-<dev> exactly as a stable one does,
# so it replaces what every stable phone downloads (nowhere_otad.sh never compares the payload with the offered
# version). Until Q126's per-release payload under os/<dev>/ exists, a ring publish needs the operator's word that the
# stable fleet is current -- and without it, it is refused here, before the agent is run and before any store call.
if [ "$RING" != stable ] && [ "$STABLE_CURRENT" != 1 ]; then
  echo "refusing: publishing to the '$RING' ring pushes the payload $OSREF, which is ONE head for every ring:"
  echo "          this push replaces what every stable phone downloads, whatever the stable marker offers."
  echo "          Publish to a ring only once every stable phone runs the current stable release, and pass"
  echo "          --stable-current to attest that (docs/backlog.md section E, \"The OS payload ref os-<dev> is one"
  echo "          head for every ring and every release ...\"; until Q126's per-release payload is built)."
  exit 2
fi

[ -x "$AGENT" ] || { echo "agent_host not at $AGENT -- build: (cd core/agent && CGO_ENABLED=0 GOOS=linux go build -o $AGENT .)"; exit 2; }
# NWP-20260914-08: and is it THIS code? `-x` answers "a file is there", not "it is current". A binary built
# weeks ago publishes silently, and what it writes is the marker every fielded device reads. Rebuilt by hand
# before three consecutive releases purely because someone remembered.
#
# ⚠ THREE OUTCOMES, AND "CANNOT DETERMINE" IS NOT "FINE". That is the whole bug class this guard is part
# of: on 2026-09-13/14 three separate checks could not run and printed like passes.
AGENT_FRESH="$(dirname "$0")/check-agent-fresh.sh"
if [ -x "$AGENT_FRESH" ]; then
  "$AGENT_FRESH" "$AGENT"; FRESHRC=$?
  case "$FRESHRC" in
    0) : ;;
    1) echo "REFUSING: $AGENT is STALE. Rebuild it, then re-run:"
       echo "  (cd core/agent && CGO_ENABLED=0 GOOS=linux go build -o $AGENT .)"
       exit 2 ;;
    *) echo "⚠ could not check whether $AGENT is current (see the line above). Proceeding, but if this"
       echo "  publish behaves oddly, rebuild the agent FIRST and rule it out." ;;
  esac
else
  echo "⚠ check-agent-fresh.sh not found beside this script -- agent freshness was NOT checked."
fi
[ -f "$OTAZIP" ] || { echo "ota zip not found: $OTAZIP"; exit 2; }

# The version that matters is the one baked INTO THE IMAGE BEING PUBLISHED, so read it from that image --
# the target-files sitting beside the OTA zip -- rather than from the source tree.
#
# The old check compared against repo/core/vendor-common/etc/nowhere-ota-version and demanded STRICTLY
# GREATER. That made the correct release sequence impossible: bump the tree to 0.5.1 -> build (image bakes
# 0.5.1) -> publish 0.5.1 was REFUSED as "not > 0.5.1". The only way to satisfy it was to publish a version
# the image does not carry, which is the very bug it meant to prevent. It also could not detect the reverse
# (tree bumped after the build), because the tree is not evidence of what the image contains.
HERE="$(cd "$(dirname "$0")" && pwd)"
vlt() { [ "$1" = "$2" ] && return 1; [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }  # $1 < $2 ?
TFZIP="$(dirname "$OTAZIP")/$DEV-target_files.zip"
IMG_STAMP=""
[ -f "$TFZIP" ] && IMG_STAMP="$(unzip -p "$TFZIP" SYSTEM/etc/nowhere-ota-version 2>/dev/null | tr -d '[:space:]')"
REPO_STAMP="$(tr -d '[:space:]' < "$HERE/../../../core/vendor-common/etc/nowhere-ota-version" 2>/dev/null)"

if [ -n "$IMG_STAMP" ]; then
  # ota-check gates on semverLess(running, latest). A device that applies THIS payload then runs $IMG_STAMP,
  # so the published marker must equal it. Publish higher and every updated device is re-offered the same OTA
  # forever; publish lower and no device is ever offered it at all.
  [ "$IMG_STAMP" = "$VERSION" ] || {
    echo "refusing: publishing '$VERSION' but this image bakes '$IMG_STAMP' (from $TFZIP)."
    echo "          They must be equal -- higher re-offers the update forever, lower is never offered."
    exit 2; }
  [ "$REPO_STAMP" = "$IMG_STAMP" ] || \
    echo "[e4-ota-publish] note: tree says '$REPO_STAMP', image bakes '$IMG_STAMP' -- the tree moved since this build; the IMAGE is authoritative."
else
  # NWP-20260901-08: REFUSE. This used to warn and fall back to comparing against the source tree, and that
  # fallback was strictly worse than nothing: the tree is not evidence of what an image contains (this file's
  # own comment above says exactly that), so it "passed" builds it could not see while reading as a check.
  #
  # ⚠ IT ALSO PAPERED OVER THE WRONG-DEVICE CASE, which is the far more expensive one. $TFZIP is
  # "$DEV-target_files.zip"; the single most likely reason it is missing is that $DEV names a DIFFERENT device
  # than the release dir holds -- exactly the mistake that publishes one fleet's image to another. Falling
  # back turned that into a soft warning behind a check that no longer applied.
  #
  # There is no override flag, deliberately: every legitimate path here has the target-files beside the OTA
  # zip, because generate-release puts them there. If you are publishing something it did not produce, the
  # question to answer is what that artifact actually is -- not how to skip the check.
  echo "refusing: $TFZIP not found, so the image's own baked version cannot be read."
  echo "          generate-release puts <dev>-target_files.zip beside <dev>-ota_update-<BN>.zip, so if it is"
  echo "          missing the usual cause is that --device ('$DEV') does not match this release directory."
  echo "          Publishing blind is how one device's image reaches another device's fleet."
  [ -n "$REPO_STAMP" ] && echo "          (for reference, the source tree currently says '$REPO_STAMP')"
  exit 2
fi
echo "[e4-ota-publish] device $DEV (payload ref $OSREF, marker $VREF); publishing $VERSION to the '$RING' ring"

# NWP-20261026-04: ONE scratch dir and ONE trap, before the first temp file -- every temp this script makes (the baked
# notes, the ring read's rc and stderr, the extracted payload) lives inside it, so a publish killed anywhere leaves nothing.
SCRATCH="$(mktemp -d)" || exit 2; trap 'rm -rf "$SCRATCH"' EXIT
READ_RC_FILE="$SCRATCH/read-rc"

# NWP-20261006-12: THE RELEASE'S NOTES (the gate's "what's in this update"). Required, valid, and the very file the
# image baked -- a notes edit after the build would otherwise describe something the image does not say about itself.
NOTES="$HERE/../../../core/vendor-common/etc/ota-notes/$VERSION"
[ -f "$NOTES" ] || { echo "refusing: no OTA notes for $VERSION at core/vendor-common/etc/ota-notes/$VERSION"
                     echo "          (draft them from the merged PRs, Chester edits; format in that directory's README)"; exit 2; }
"$AGENT" ota-notes-check "$NOTES" "$VERSION" || { echo "refusing: the notes for $VERSION are not valid (above)"; exit 2; }
IMG_NOTES="$(mktemp -p "$SCRATCH")"
unzip -p "$TFZIP" SYSTEM/etc/nowhere-ota-notes > "$IMG_NOTES" 2>/dev/null || true
if ! cmp -s "$IMG_NOTES" "$NOTES"; then
  rm -f "$IMG_NOTES"
  echo "refusing: the image's baked notes (SYSTEM/etc/nowhere-ota-notes in $TFZIP) are missing or differ from"
  echo "          core/vendor-common/etc/ota-notes/$VERSION -- the notes changed after this build. Rebuild."
  exit 2
fi
rm -f "$IMG_NOTES"
NOTES_PREV="$(sed -n 's/^previous //p' "$NOTES" | tr -d '[:space:]')"

# NWP-20261011-05: THE RELEASE'S SIGNED METADATA -- whether installing it is mandatory, by when, and why. It rides the
# installer manifest the operator signed with the release key (make-web-package.sh wrote its "ota" object), so the
# signed copy has to come back here, beside the manifest: <dev>-manifest-<BN>.json.sig. It is checked with the very
# code and key a phone uses (ota-release-check: the signature, this device, this version, and agreement with the
# committed editions/endospore/ota-mandatory/<version>) and published BEFORE the marker, like the notes.
#   - flagged mandatory and no signed manifest -> REFUSE: published without it, the flag would silently not exist.
#   - a signed manifest that does not verify -> REFUSE: the same failure would reject it on the install page.
#   - ordinary and no signed manifest -> publish without it; a phone reads that as "not mandatory", which it is.
OTA_BASE="$(basename "$OTAZIP")"
BN="${OTA_BASE#"$DEV"-ota_update-}"; BN="${BN%.zip}"
REL_MAN="$(dirname "$OTAZIP")/$DEV-manifest-$BN.json"
REL_SIG="$REL_MAN.sig"
MAND_SRC="$HERE/../ota-mandatory/$VERSION"
REL_PUBLISH=0
if [ -f "$REL_SIG" ]; then
  [ -f "$REL_MAN" ] || { echo "refusing: $REL_SIG is here but the manifest it signs ($REL_MAN) is not"; exit 2; }
  if ! "$AGENT" ota-release-check "$REL_MAN" "$REL_SIG" "$DEV" "$VERSION" "$MAND_SRC"; then
    echo "refusing: the signed manifest for $DEV $VERSION does not pass the phone's own check (above)."
    echo "          A wrong signing key, a manifest from another build, or a flag edited after signing all land here."
    exit 2
  fi
  REL_PUBLISH=1
elif [ -f "$MAND_SRC" ]; then
  echo "refusing: $VERSION is flagged $(sed -n 's/^severity //p' "$MAND_SRC") (editions/endospore/ota-mandatory/$VERSION),"
  echo "          but there is no signed manifest at $REL_SIG. Copy the .sig the operator machine produced back"
  echo "          beside the manifest: without it no phone would ever learn this update is required."
  exit 2
else
  echo "[e4-ota-publish] no signed manifest at $REL_SIG -- an ordinary release, so phones read it as not mandatory"
fi

. "$CONF"; export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY

# NWP-20261026-04: READ THE RING BEFORE WRITING IT. This script used to overwrite $VREF with whatever $VERSION it was
# given -- re-running last month's release dir moved the stable ring BACK, and phones ahead of it were offered nothing.
# A copy of e4-ota-promote.sh's three-outcome read_ring (NWP-20261024-05; same regexes, same outcomes): a version only
# from exit 0 + the UPDATE line or exit 1 + the UPTODATE line, absent only from exit 3 + its exact line, anything else
# is UNREADABLE -- never "absent". The agent's stderr is kept in the scratch dir and shown when a read is refused.
#   return 0  present: version on stdout       return 3  absent       return 4  could not read
read_ring() {
  local out rc line="" re=""
  if out="$(NOWHERE_OTA_VERSION_REF="$VREF" "$AGENT" ota-check s3 2>"$SCRATCH/ota-check.err")"; then rc=0; else rc=$?; fi
  printf '%s' "$rc" > "$READ_RC_FILE"
  case "$rc" in
    0) re='^ota-check: UPDATE -> [0-9]+\.[0-9]+(\.[0-9]+)?$' ;;
    1) re='^ota-check: UPTODATE \(latest [0-9]+\.[0-9]+(\.[0-9]+)?\)$' ;;
    3) if printf '%s\n' "$out" | grep -qxF 'ota-check: no published OS version'; then return 3; fi ;;
  esac
  if [ -n "$re" ]; then
    line="$(printf '%s\n' "$out" | grep -E "$re" | tail -1 || true)"
  fi
  if [ -n "$line" ]; then
    printf '%s\n' "$line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1
    return 0
  fi
  {
    echo "[e4-ota-publish] could not read the '$RING' ring ($VREF): agent exit $rc, stdout: ${out:-<empty>}"
    echo "[e4-ota-publish] agent stderr:"
    sed 's/^/    /' "$SCRATCH/ota-check.err"
  } >&2
  return 4
}

if CUR="$(read_ring)"; then :; else
  case $? in
    3) CUR="" ;;
    *) echo "refusing: could not read the '$RING' ring ($VREF, agent exit $(cat "$READ_RC_FILE")) -- retry; nothing was written"
       echo "          (--force does not override this: an unreadable marker cannot be compared.)"
       exit 2 ;;
  esac
fi
CURDISP="${CUR:-<none>}"
if [ -n "$CUR" ] && vlt "$VERSION" "$CUR"; then
  if [ "$FORCE" != 1 ]; then
    echo "refusing: '$RING' already offers $CUR; publishing $VERSION would move it back. Use --force to roll the ring back deliberately."
    exit 2
  fi
  echo "[e4-ota-publish] --force: moving '$RING' back from $CUR to $VERSION (a NON-forward move; phones on $CUR will be offered nothing)."
elif [ "$CUR" = "$VERSION" ]; then
  echo "[e4-ota-publish] note: '$RING' already offers $VERSION -- phones already running $VERSION will NOT be offered this payload."
fi

# NWP-20261006-12 (moved before the push by NWP-20261026-04, so a refusal can no longer follow a payload swap): the previous
# version's notes must already be published (the chain a phone walks), unless this release starts the chain.
set +e
"$AGENT" ota-notes-get s3 "$DEV" "$NOTES_PREV"; PREV_RC=$?
set -e
case "$PREV_RC" in
  0) : ;;
  3) if [ "$FIRST_NOTES" = 1 ]; then
       echo "[e4-ota-publish] --first-notes: $VERSION starts the notes chain ($NOTES_PREV has none)"
     else
       echo "refusing: $NOTES_PREV (this release's previous) has no published notes for $DEV, so the chain would break."
       echo "          Publish that version's notes first, or pass --first-notes if $VERSION genuinely starts the chain."
       exit 2
     fi ;;
  *) echo "refusing: could not read $NOTES_PREV's notes from the store (rc $PREV_RC) -- not the same as 'none'"; exit 2 ;;
esac

# 1. Extract the A/B payload from the GrapheneOS OTA zip (a standard update_engine A/B package).
STAGE="$SCRATCH/payload"; mkdir "$STAGE"
unzip -o "$OTAZIP" payload.bin payload_properties.txt -d "$STAGE" >/dev/null
[ -s "$STAGE/payload.bin" ] && [ -s "$STAGE/payload_properties.txt" ] || { echo "no payload.bin/properties in $OTAZIP"; exit 1; }

# 2. Push to the store as CDC chunks (content-addressed -> a later v2->v3 sharing bytes dedups; the store
#    grows by the delta only). The OS is PUBLIC, so OSPASS just keys the convergent seal -- no user creds.
"$AGENT" push s3 "$OSREF" "$OSPASS" "$STAGE"

# 3a. NWP-20261006-12: the notes, BEFORE the marker, so a phone that sees the marker can fetch them. (The previous
#     version's notes were already read above, before the push: NWP-20261026-04.)
"$AGENT" ota-notes-put s3 "$DEV" "$NOTES"
# 3b. NWP-20261011-05: the signed release metadata, also BEFORE the marker -- a phone that sees the marker must find it.
if [ "$REL_PUBLISH" = 1 ]; then
  "$AGENT" ota-release-put s3 "$REL_MAN" "$REL_SIG" "$DEV" "$VERSION" "$MAND_SRC"
fi

# 3. Publish the version so the device's ota-check (reads ota/lynx/version) sees an update available.
"$AGENT" ota-mark s3 "$VERSION"
echo "[e4-ota-publish] published $(basename "$OTAZIP") as $OSREF, version $VERSION on the '$RING' ring (ref $VREF, was $CURDISP)"
if [ "$RING" != stable ]; then
  echo "[e4-ota-publish] the general MARKER is unchanged, but the payload $OSREF is not: a stable phone behind the stable marker now downloads THIS build."
  echo "                 Verify a canary against $VREF, then promote to all:"
  echo "                 editions/endospore/build/e4-ota-promote.sh <store-conf> --from $RING --device $DEV"
fi
