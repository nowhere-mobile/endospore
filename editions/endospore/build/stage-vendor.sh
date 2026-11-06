#!/usr/bin/env bash
# stage-vendor.sh -- assemble the GrapheneOS build tree's vendor/endospore from the restructured repo
# (E.2). Mirrors editions/diaspore/build/stage-vendor.sh, but targets the GrapheneOS tree and a
# vendor/endospore dest. The repo is product-shaped (core/ shared + editions/ per OS); the build expects
# a single vendor/endospore tree, so we merge the pieces into it before `m`:
#
#   core/vendor-common/*               -> vendor/endospore/          (Android.bp, bin/, etc/, sepolicy/,
#                                                                     default-permissions/, prebuilts/, media/)
#   core/chooser/                      -> vendor/endospore/chooser/   (the gate app; Android.bp globs chooser/src)
#   core/napps/                        -> vendor/endospore/napps/     (#747 nApps; Android.bp globs napps/src+res)
#   editions/endospore/vendor/         -> vendor/endospore/           (edition delta: GrapheneOS rc override,
#                                                                     sepolicy delta, overlays -- added in E.2b)
#   editions/endospore/endospore.mk    -> vendor/endospore/endospore.mk  (inherited by the lynx product via
#                                                                     build/inject-product.sh)
#
# The agent BINARY is built FROM SOURCE below -- it is NOT a committed prebuilt (core/vendor-common/bin/
# nowhere_agent is gitignored), so it can never drift from core/agent. Fetched default-app APKs + generated
# JNI (when an endospore default-apps fetch is added) live ONLY in the build tree (gitignored) and are
# PRESERVED across re-stages.
#
# Tiers (see AGENTS.md "Repository layout"): core/ = common (nowhere), editions/endospore = OS (GrapheneOS),
# editions/endospore/devices/<device> = device (lynx/...). This assembles all three into one vendor/endospore.
# Usage: stage-vendor.sh <repo-root> <dest = $GRAPHENE_TREE/vendor/endospore> [device=lynx]
set -euo pipefail
REPO="${1:?usage: stage-vendor.sh <repo-root> <dest vendor/endospore> [device]}"
DEST="${2:?usage: stage-vendor.sh <repo-root> <dest vendor/endospore> [device]}"
DEV="${3:-lynx}"

# NWP-20261011-16: one stage per destination tree. Closes the backlog row "`stage-vendor.sh` has no lock --
# two concurrent device builds silently corrupt `file_contexts`": this script assembles into the SINGLE shared
# vendor/<edition>, and the file_contexts generator below APPENDS, so two stages interleaved duplicate entries
# and sepolicy dies with "Multiple same specifications" -- which reads like a sepolicy bug, and the next clean
# stage overwrites the evidence. The lock lives BESIDE the destination so no --delete rsync below can remove
# it; fd 9 stays open until this process exits, so the lock spans the whole stage, agent build included.
# Non-blocking on purpose: the second stage must FAIL, not queue -- the parallel pattern is ONE prep, then
# PREP=0 builds (build-device.sh header), never two preps.
LOCK="$(dirname "$DEST")/.$(basename "$DEST").stage.lock"
mkdir -p "$(dirname "$DEST")"
command -v flock >/dev/null 2>&1 || { echo "[stage-vendor] ERROR: flock not found -- cannot guard against a concurrent stage" >&2; exit 1; }
exec 9>"$LOCK"
flock -n 9 || { echo "[stage-vendor] ERROR: another stage-vendor.sh is writing $DEST (lock $LOCK). Two concurrent stages corrupt file_contexts; run ONE prep, then PREP=0 builds." >&2; exit 1; }

mkdir -p "$DEST"
# Shared core. --delete keeps DEST in sync with the repo, but PROTECT the fetched prebuilts (APKs, extracted
# JNI, generated fragment) -- they're not in the repo and are expensive to re-fetch.
rsync -a --delete \
  --exclude 'prebuilts/*.apk' \
  --exclude 'prebuilts/jni/' \
  --exclude 'prebuilts/default-apps-jni.mk' \
  --exclude '/chooser' --exclude '/pushd' --exclude '/napps' --exclude '/overlay' --exclude '/endospore.mk' \
  "$REPO/core/vendor-common/" "$DEST/"
# >>> tracked prebuilt APKs (NWP-20261011-22)
# The rsync above excludes prebuilts/*.apk to protect the FETCHED ones, which also kept out the APKs the repo
# COMMITS (WireGuard: not on F-Droid, a `manual` row in default-apps.manifest), so a fresh stage failed Soong on
# "prebuilts/WireGuard.apk does not exist". Copy every git-tracked prebuilts/*.apk in after it. When $REPO is not a
# checkout's root (a source export), fall back to WireGuard.apk, the one committed APK, if it is there.
mkdir -p "$DEST/prebuilts"
if [ "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$REPO" && pwd -P)" ]; then
  git -C "$REPO" ls-files -- 'core/vendor-common/prebuilts/*.apk'
elif [ -f "$REPO/core/vendor-common/prebuilts/WireGuard.apk" ]; then
  echo core/vendor-common/prebuilts/WireGuard.apk
fi | while IFS= read -r f; do
  install -m644 "$REPO/$f" "$DEST/prebuilts/"
  echo "[stage-vendor] staged tracked prebuilt ${f##*/}"
done
# <<< tracked prebuilt APKs
# The chooser app (kept as a top-level core component; Android.bp expects it at vendor/endospore/chooser).
rsync -a --delete "$REPO/core/chooser/" "$DEST/chooser/"
# NowherePush (#157): the UnifiedPush distributor -- another top-level core app; Android.bp globs pushd/src.
rsync -a --delete "$REPO/core/pushd/" "$DEST/pushd/"
# NowhereApps (#747, DIA-20260818-08): the nApps storefront as its own package. Same shape as the two above --
# Android.bp globs napps/src and napps/res, so it must land at vendor/endospore/napps. Missing this is a hard
# build failure ("module source path vendor/endospore/napps/AndroidManifest.xml does not exist"), not a silent
# stale-file bug, which is the good kind of failure.
rsync -a --delete "$REPO/core/napps/" "$DEST/napps/"
# Edition (Pixel + GrapheneOS) delta, if present: the rc override + sepolicy + overlays land in E.2b, so
# this directory may not exist yet on a pure E.2a checkout -- overlay it only when it does.
if [ -d "$REPO/editions/endospore/vendor" ]; then
  rsync -a "$REPO/editions/endospore/vendor/" "$DEST/"
fi
# Device tier: overlay the per-device vendor delta (os-ref, the Launcher3 home overlay) on TOP of the
# OS-common, so vendor/endospore ends up identical to the old single-device layout. Each new Endospore
# device adds editions/endospore/devices/<device>/vendor without touching the OS-common edition root.
if [ -d "$REPO/editions/endospore/devices/$DEV/vendor" ]; then
  rsync -a "$REPO/editions/endospore/devices/$DEV/vendor/" "$DEST/"
  echo "[stage-vendor] overlaid device '$DEV' vendor delta"
else
  echo "[stage-vendor] WARNING: no device delta at editions/endospore/devices/$DEV/vendor" >&2
fi

# EVERY device's os-ref, under its own name -- this is what makes CONCURRENT per-device builds safe.
#
# os-ref is the only genuinely per-device file in the staged tree, and endospore.mk bakes it to
# /system/etc/nowhere/os-ref, where the agent reads it to derive its OTA channel (os-<dev> ->
# ota/<dev>/version). The device delta above writes it to ONE shared path, so two builds staging at the
# same time meant last-writer-wins and the loser shipped an image pointing at ANOTHER DEVICE'S OTA feed --
# silently, with no build error and a correct-looking image. Staging all of them under os-ref-<dev> and
# having endospore.mk select by TARGET_PRODUCT removes the shared write entirely.
osrefs=0
for d in "$REPO"/editions/endospore/devices/*/; do
  dev=$(basename "$d")
  [ -f "$d/vendor/etc/os-ref" ] || continue
  install -D -m 0644 "$d/vendor/etc/os-ref" "$DEST/etc/os-ref-$dev"
  osrefs=$((osrefs+1))
done
echo "[stage-vendor] staged $osrefs per-device os-ref file(s) (os-ref-<device>); endospore.mk picks by TARGET_PRODUCT"
[ "$osrefs" -gt 0 ] || { echo "[stage-vendor] ERROR: no per-device os-ref staged -- the OTA channel would be wrong" >&2; exit 1; }
# Drop the shared copy the device-delta rsync just wrote. Nothing reads it any more, and leaving a stale,
# last-writer-wins os-ref sitting in the staged tree is an invitation to reference it again by accident --
# which is the exact bug above. Removing it makes any such reference fail at build time instead.
rm -f "$DEST/etc/os-ref"
# >>> support-end (NWP-20261125-04)
# h55 #2 (docs/product-decisions.md, 2026-11-03): the date GrapheneOS full support for a device ends, from
# editions/endospore/devices/<dev>/support-end, staged beside os-ref so the gate and Profile can say, offline, that
# the phone no longer gets security updates. Each device stages under its own name for the os-ref reason above
# (two concurrent stages, last writer wins), and endospore.mk picks by TARGET_PRODUCT. A device without the file
# stages nothing and raises no error here: refusing a release without one is build-device.sh's guard, not this loop's.
supends=0
for d in "$REPO"/editions/endospore/devices/*/; do
  dev=$(basename "$d")
  [ -f "$d/support-end" ] || continue
  install -D -m 0644 "$d/support-end" "$DEST/etc/support-end-$dev"
  supends=$((supends+1))
done
echo "[stage-vendor] staged $supends per-device support-end file(s) (support-end-<device>); endospore.mk picks by TARGET_PRODUCT"
# No shared copy may exist, for the same reason as the os-ref removal above.
rm -f "$DEST/etc/support-end"
# <<< support-end

cp -a "$REPO/editions/endospore/endospore.mk" "$DEST/endospore.mk"

# NWP-20261006-12: this image's own OTA notes -- the file for exactly the version it bakes, staged as one path that
# endospore.mk copies to /system/etc/nowhere-ota-notes (the gate's "what's in the version I run", offline). The
# history of every version's notes stays in the repo, not the image. A dev build between releases may have none;
# a RELEASE must (verify-release.sh refuses an image without them).
OTA_STAMP="$(tr -d '[:space:]' < "$DEST/etc/nowhere-ota-version")"
rm -f "$DEST/etc/nowhere-ota-notes"
if [ -n "$OTA_STAMP" ] && [ -f "$DEST/etc/ota-notes/$OTA_STAMP" ]; then
  install -m 0644 "$DEST/etc/ota-notes/$OTA_STAMP" "$DEST/etc/nowhere-ota-notes"
  echo "[stage-vendor] staged the OTA notes for $OTA_STAMP"
else
  echo "[stage-vendor] no OTA notes for '$OTA_STAMP' (fine for a dev build; a release needs them)"
fi
rm -rf "$DEST/etc/ota-notes"

# Build the agent FROM SOURCE into the staged tree. core/vendor-common/bin/nowhere_agent is GITIGNORED, so a
# fresh checkout has no binary at all and a dirty one ships whatever happens to be on disk -- exactly the
# stale-prebuilt footgun (DIA-20260629-26). DIA-20260629-05 fixed that for diaspore's stage-vendor.sh but was
# never ported here, so endospore builds could silently ship a months-old agent. Static arm64 / CGO off (the
# device target). MUST come after the rsyncs above: they use --delete, which would remove a staged binary.
# Fails LOUDLY rather than shipping something stale.
GO_BIN="$(command -v go || true)"
[ -z "$GO_BIN" ] && [ -x /usr/local/go/bin/go ] && GO_BIN=/usr/local/go/bin/go
if [ -z "$GO_BIN" ]; then
  echo "[stage-vendor] ERROR: 'go' not found -- needed to build vendor/endospore/bin/nowhere_agent from core/agent" >&2
  exit 1
fi
mkdir -p "$DEST/bin"
# DIA-20260806-05: the rc of this build MUST be checked. It ran in a subshell whose status nobody read, so a
# failed `go build` would leave the PREVIOUS binary sitting in $DEST/bin and the build would carry on and ship
# it -- the exact stale-agent footgun the comment above says this code exists to prevent, reintroduced one
# line below it. Removing the old binary first means a silent failure can only ever produce a MISSING agent
# (loud, unbootable-obvious) rather than a stale one (silent, and indistinguishable from "my fix didn't
# work").
#
# CORRECTION (DIA-20260806-06): the original commit message for this change said the hazard had been "caught
# on frankel" -- a compile dying under memory pressure and an image shipping a three-hour-old agent. That did
# not happen. Both frankel builds compiled fine; the feature was missing because its CALL SITE was never
# added (avcDenials was defined and never invoked, so the linker dropped it), and the real fault was
# diagnosed backwards from the symptom. This guard remains correct and worth having on its own merits -- an
# unchecked build in a subshell is a genuine hazard -- but it was written from a wrong story, and a wrong
# story in a comment is worse than no comment, because the next reader trusts it.
rm -f "$DEST/bin/nowhere_agent"
if ! ( cd "$REPO/core/agent" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 "$GO_BIN" build -o "$DEST/bin/nowhere_agent" . ); then
  echo "[stage-vendor] ERROR: building the agent failed -- refusing to stage (a stale agent is worse than no build)" >&2
  exit 1
fi
[ -s "$DEST/bin/nowhere_agent" ] || { echo "[stage-vendor] ERROR: agent build produced no binary" >&2; exit 1; }
chmod 755 "$DEST/bin/nowhere_agent"
echo "[stage-vendor] built agent ($("$GO_BIN" version | awk '{print $3}')) -> $(file "$DEST/bin/nowhere_agent" | grep -oE 'BuildID\[sha1\]=[0-9a-f]+' || echo ok)"

# E.2c: retarget the four privileged init workers (provision/roamd/otad/gate) off the userdebug-only
# su:s0 onto the real endospore_priv domain (defined in vendor/sepolicy/endospore.te), so they function
# on a USER build where GrapheneOS neuters su. Every worker stanza but the login daemon -- provision, roamd (and its ro and cred lanes), otad, mediad and gate -- uses `seclabel u:r:su:s0`. The login daemon
# uses u:r:nowhere:s0 and is untouched. Done as a staged transform (one rc source in core/) rather than a
# forked nowhere.rc copy, so the rc can't drift between editions.
#
# E.5x: the retarget is now per-SERVICE, not a blanket sed. nowhere_mediad needs a DIFFERENT domain from the
# other workers: it is the only service that mounts, so it is the only one that may hold CAP_SYS_ADMIN (see
# vendor/sepolicy/endospore_mediad.te for why that capability must not sit in endospore_priv). The SOURCE rc
# keeps seclabel u:r:su:s0 -- diaspore/FP3 shares that file and mediad stays su:s0 there.
if [ -f "$DEST/etc/nowhere.rc" ]; then
  awk '
    /^service /          { svc = $2 }
    /seclabel u:r:su:s0/ { dom = (svc == "nowhere_mediad") ? "endospore_mediad" : "endospore_priv"
                           sub(/u:r:su:s0/, "u:r:" dom ":s0") }
                         { print }
  ' "$DEST/etc/nowhere.rc" > "$DEST/etc/nowhere.rc.tmp"
  mv "$DEST/etc/nowhere.rc.tmp" "$DEST/etc/nowhere.rc"
  echo "[stage-vendor] retargeted su:s0 -> endospore_priv / endospore_mediad in nowhere.rc"
  # A survivor would mean a service still tries to enter su on a user build, where GrapheneOS has neutered it:
  # the service would simply never run, silently. Fail the build instead.
  if grep -q 'u:r:su:s0' "$DEST/etc/nowhere.rc"; then
    echo "[stage-vendor] ERROR: u:r:su:s0 survives the retarget in nowhere.rc" >&2; exit 1
  fi
fi

# E.2c: label the four worker scripts with the dedicated endospore_priv_exec type so init enters the
# endospore_priv domain via a specific core entrypoint (not the broad system_file, which trips the
# Treble/coredomain sepolicy_test). Appended to core's file_contexts (one file_contexts per sepolicy dir),
# idempotent. The agent + nowhere_login.sh keep their core nowhere_exec label.
#
# DIA-20260806-09: this list is DERIVED from nowhere.rc, not hardcoded. It used to name four scripts by
# hand while the sed above retargeted FIVE services -- nowhere_mediad.sh was missing, so on an enforcing
# build init could not enter endospore_priv through it: `avc: denied { entrypoint } for
# /system/bin/nowhere_mediad.sh ... tclass=file` (23 times in one roam), and the on-demand media daemon
# never started at all. Nothing failed loudly; media was simply absent. Two lists that must agree, kept in
# two places, is the bug -- so now there is one list, and adding a sixth service to nowhere.rc labels it
# automatically. Fails loudly if the rc and the labels ever disagree again.
#
# E.5x: generalised over DOMAINS, same principle. The domain list is derived from the rc too, so adding a
# service -- or a third domain -- needs no edit here, and a domain named in the rc but declared in no staged
# .te fails the build rather than silently falling back to system_file.
FC="$DEST/sepolicy/file_contexts"
RC="$DEST/etc/nowhere.rc"
if [ -f "$FC" ] && [ -f "$RC" ] && ! grep -q endospore_priv_exec "$FC"; then
  DOMAINS=$(grep -oE 'seclabel u:r:endospore_[a-z_]+:s0' "$RC" | sed 's/.*u:r://; s/:s0//' | sort -u)
  [ -n "$DOMAINS" ] || { echo "[stage-vendor] ERROR: no endospore_* services found in $RC -- the seclabel retarget above must run first" >&2; exit 1; }
  {
    echo "# Endospore (E.2c/E.5x): the privileged init workers enter their own domains."
    echo "# Generated by stage-vendor.sh from nowhere.rc -- do not hand-edit; add the service to the rc instead."
  } >> "$FC"
  LABELLED=0
  for DOM in $DOMAINS; do
    if ! grep -qE "^type $DOM, domain" "$DEST/sepolicy/"*.te; then
      echo "[stage-vendor] ERROR: nowhere.rc puts a service in $DOM, but no staged .te declares that domain" >&2; exit 1
    fi
    DOM_SCRIPTS=$(awk -v want="seclabel u:r:$DOM:s0" '/^service /{path=$3} index($0, want){if (path ~ /^\/system\/bin\//) print path}' "$RC" | sort -u)
    [ -n "$DOM_SCRIPTS" ] || { echo "[stage-vendor] ERROR: $DOM has no /system/bin entrypoint in $RC" >&2; exit 1; }
    for s in $DOM_SCRIPTS; do
      printf '%-42s u:object_r:%s_exec:s0\n' "$(echo "$s" | sed 's/\./\\./g')" "$DOM" >> "$FC"
      LABELLED=$((LABELLED + 1))
    done
    echo "[stage-vendor] labelled $(echo "$DOM_SCRIPTS" | wc -l) $DOM entrypoint(s) from nowhere.rc:"
    echo "$DOM_SCRIPTS" | sed 's/^/[stage-vendor]   /'
  done
  # The count check is the point of the whole generator: two lists that must agree, kept in two places, is the
  # bug (DIA-20260806-09). One list now, and it is asserted against itself.
  WANTED=$(awk '/^service /{path=$3} /seclabel u:r:endospore_/{if (path ~ /^\/system\/bin\//) print path}' "$RC" | sort -u | wc -l)
  [ "$LABELLED" -eq "$WANTED" ] || { echo "[stage-vendor] ERROR: labelled $LABELLED entrypoints but nowhere.rc names $WANTED" >&2; exit 1; }
fi

# E.5x harvest gate. A brand-new domain starts with no rules, so it needs one permissive run on hardware to
# collect its denial set. That permissive line lives OUTSIDE vendor/ so the sepolicy rsync cannot stage it;
# it is copied in only when explicitly asked, and any stale copy is removed on EVERY other build -- so a
# harvest build followed by an ordinary one cannot leave a permissive domain in the image. Structural, not a
# convention: this repo has shipped a dev-only suppression twice (endospore.te lines 19-36 and 178-190).
HARVEST_SRC="$REPO/editions/endospore/build/harvest/endospore_mediad_permissive.te"
HARVEST_DST="$DEST/sepolicy/endospore_mediad_permissive.te"
rm -f "$HARVEST_DST"
if [ "${NOWHERE_SEPOLICY_HARVEST:-0}" = "1" ]; then
  [ -f "$HARVEST_SRC" ] || { echo "[stage-vendor] ERROR: NOWHERE_SEPOLICY_HARVEST=1 but $HARVEST_SRC is missing" >&2; exit 1; }
  cp "$HARVEST_SRC" "$HARVEST_DST"
  echo "[stage-vendor] *** HARVEST BUILD: endospore_mediad is PERMISSIVE -- this image must never ship ***"
fi

# NOWHERE_RING (beta / future canary rings): bake a ring's NON-SECRET store targeting into /system so a
# ring device is turnkey and survives the amnesia wipe. A ring bakes either GATEWAY_URL (turnkey: the device is
# already enrolled) or NOWHERE_GATEWAY_DEFAULT (user-run first-run enrols against it), and NEVER store creds.
# Unset (prod/stable) bakes nothing -> the OS ships un-enrolled, exactly as before. MUST run after the
# --delete rsyncs above (they would remove a staged nowhere.conf). Templates: core/vendor-common/etc/rings/.
if [ -n "${NOWHERE_RING:-}" ]; then
  RING_SRC="$REPO/core/vendor-common/etc/rings/${NOWHERE_RING}.conf"
  [ -f "$RING_SRC" ] || { echo "[stage-vendor] ERROR: NOWHERE_RING=$NOWHERE_RING but no template at $RING_SRC" >&2; exit 1; }
  install -D -m644 "$RING_SRC" "$DEST/etc/nowhere.conf"
  sed -i 's/\r$//' "$DEST/etc/nowhere.conf"   # LF only -- a trailing CR breaks the agent conf parse
  # NWP-20261011-32: log whichever gateway key the ring carries -- beta-setup.conf has NOWHERE_GATEWAY_DEFAULT= and
  # no GATEWAY_URL=, so a GATEWAY_URL-only grep printed an empty value and a wrong or missing gateway read exactly
  # like a correct one. The line is labelled by its own key; both values are non-secret URLs. A ring with neither
  # points the device at no gateway at all, so it fails the stage. Pinned by editions/endospore/build/test-ring-conf.sh.
  RING_GW=$(grep -m1 -E '^(GATEWAY_URL|NOWHERE_GATEWAY_DEFAULT)=' "$DEST/etc/nowhere.conf" || true)
  if [ -z "$RING_GW" ]; then
    rm -f "$DEST/etc/nowhere.conf"
    echo "[stage-vendor] ERROR: ring '$NOWHERE_RING' ($RING_SRC) carries neither GATEWAY_URL= nor NOWHERE_GATEWAY_DEFAULT=" >&2
    exit 1
  fi
  echo "[stage-vendor] baked ring '$NOWHERE_RING' -> vendor/endospore/etc/nowhere.conf ($RING_GW)"
fi

# >>> source commit (NWP-20261104-08)
# Q094 (c), docs/product-decisions.md: bake the commit this tree was staged from into ONE file, so nothing has to
# trust the build host's checkout afterwards. It is written HERE, at stage time, not by build-device.sh: a PREP=0
# build reuses a tree staged earlier, and the file must describe that staged tree. It sits after the --delete rsyncs
# (they would remove it). endospore.mk copies it to /system/etc/nowhere/source-commit and verify-release.sh check 8
# reads it back out of the signed artifact: exactly 40 lowercase hex passes, `<sha>+modified` (a tracked file differs
# from HEAD) and `unknown` (no git checkout) fail there. A dev stage never fails on it. Untracked files do not count,
# as in verified-commit-guard.sh. $REPO must be the checkout root (the idiom of the tracked-prebuilt block below): a
# source export unpacked inside another repository must not bake that repository's HEAD. POSIX syntax only; pinned by
# editions/endospore/build/test-source-commit.sh, which runs this block under every shell.
SRC_COMMIT=unknown
if [ "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)" = "$(cd "$REPO" && pwd -P)" ] \
  && SRC_HEAD=$(git -C "$REPO" rev-parse --verify -q HEAD 2>/dev/null) \
  && SRC_DIRTY=$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null); then
  SRC_COMMIT="$SRC_HEAD"
  [ -z "$SRC_DIRTY" ] || SRC_COMMIT="$SRC_HEAD+modified"
fi
printf '%s\n' "$SRC_COMMIT" > "$DEST/etc/nowhere-source-commit"
echo "[stage-vendor] source commit $SRC_COMMIT"
# <<< source commit

# F-Droid search (Phase B, DIA-20260731): stage the SIGNED trimmed index + icon pack from the publish pipeline's
# output (prebuilts/publish-fdroid-index.sh -> FDROID_INDEX_DIR). Gitignored + ~12 MB, so NOT in the repo -- placed
# here after the --delete rsyncs (which would remove them). The .mk copies them to /system only when present. All
# four (index.json + .sig + icons.pack + .sig) must be present or none are staged (partial -> skip), and a full set
# must match its fdroid-index.lock + the agent's indexPubKey or the stage fails.
FDROID_INDEX_DIR=${FDROID_INDEX_DIR:-/mnt/build/fdroid-index}
FDROID_NAMES="index.json index.json.sig icons.pack icons.pack.sig"
FDROID_HAVE=0
for f in $FDROID_NAMES; do
  if [ -f "$FDROID_INDEX_DIR/$f" ]; then FDROID_HAVE=$((FDROID_HAVE + 1)); fi
done
if [ "$FDROID_HAVE" -eq 4 ]; then
  # NWP-20261029-15: check the set against the lock publish-fdroid-index.sh wrote beside it, and the lock's
  # index-pubkey against the agent's indexPubKey, BEFORE installing anything. A set signed by another key, or
  # altered or cut after publish, makes every phone reject the baked index on read -- full-catalog search is
  # empty for that release and nothing at build time said why.
  FDROID_LOCK="$FDROID_INDEX_DIR/fdroid-index.lock"
  FDROID_BAD=""
  FDROID_AGENT_PUB=$(sed -n 's/^var indexPubKey = "\([^"]*\)".*/\1/p' "$REPO/core/agent/index.go" 2>/dev/null || true)
  if [ ! -f "$FDROID_LOCK" ]; then
    FDROID_BAD="has no fdroid-index.lock"
  elif [ -z "$FDROID_AGENT_PUB" ] || [ "$(printf '%s\n' "$FDROID_AGENT_PUB" | wc -l)" -ne 1 ]; then
    FDROID_BAD="cannot read indexPubKey from core/agent/index.go"
  else
    for f in $FDROID_NAMES; do
      FDROID_ROW=$(awk -v n="$f" '!/^#/ && $2 == n { c++; l = $0 } END { print c + 0; print l }' "$FDROID_LOCK")
      if [ "$(printf '%s\n' "$FDROID_ROW" | sed -n 1p)" != 1 ]; then
        FDROID_BAD="lock does not list $f exactly once"; break
      fi
      if [ "$(printf '%s\n' "$FDROID_ROW" | sed -n 2p)" != "$(sha256sum "$FDROID_INDEX_DIR/$f" | cut -d' ' -f1)  $f" ]; then
        FDROID_BAD="$f does not match its fdroid-index.lock hash"; break
      fi
    done
    if [ -z "$FDROID_BAD" ]; then
      if [ "$(grep -c '^# index-pubkey: ' "$FDROID_LOCK" || true)" -ne 1 ]; then
        FDROID_BAD="lock does not carry exactly one index-pubkey line"
      elif [ "$(sed -n 's/^# index-pubkey: //p' "$FDROID_LOCK")" != "$FDROID_AGENT_PUB" ]; then
        FDROID_BAD="lock index-pubkey is not the agent's indexPubKey"
      fi
    fi
  fi
  if [ -n "$FDROID_BAD" ]; then
    echo "[stage-vendor] ERROR: F-Droid index set in $FDROID_INDEX_DIR $FDROID_BAD -- not staged; re-run core/vendor-common/prebuilts/publish-fdroid-index.sh with the index key whose public half is index.go's indexPubKey" >&2
    exit 1
  fi
  for f in $FDROID_NAMES; do
    install -m644 "$FDROID_INDEX_DIR/$f" "$DEST/etc/$f"
  done
  echo "[stage-vendor] staged F-Droid search index ($(du -h "$DEST/etc/index.json" | cut -f1)) + icon pack ($(du -h "$DEST/etc/icons.pack" | cut -f1))"
elif [ "$FDROID_HAVE" -eq 0 ]; then
  echo "[stage-vendor] no F-Droid search index at $FDROID_INDEX_DIR -- baking without full-catalog search"
else
  echo "[stage-vendor] F-Droid search index at $FDROID_INDEX_DIR is incomplete ($FDROID_HAVE of 4 files) -- baking without full-catalog search"
fi

# DIA-20260817-01 (#732), GENERALISED NWP-20260820-15: FAIL the stage if any staged device script invokes a
# binary AOSP ships ONLY in PRODUCT_PACKAGES_DEBUG and that we do NOT add to PRODUCT_PACKAGES ourselves. Such
# a call site works on lynx (userdebug) and is silently dead on every shipping device -- this class has now
# shipped FOUR times: seed_home 2026-08-10, the launcher relabel pair, the #732 account destruction, and the
# NWP-20260820-09 OTA P0, where nowhere_otad.sh called update_engine_client and OTA APPLY HAD THEREFORE NEVER
# WORKED ON ANY user BUILD. The first three were sqlite3, so the guard only ever grepped for sqlite3 and the
# fourth walked straight past it. It is a DENYLIST now; add to it whenever a debug-only name is discovered.
#
# TO ALLOW ONE OF THESE, SHIP IT -- do not weaken the guard: add the module to PRODUCT_PACKAGES in BOTH
# editions' .mk AND give it a nowhere_exec label in core/vendor-common/sepolicy/file_contexts (which keeps it
# exec-restricted to the nowhere/endospore_priv domains), then drop it from this list. update_engine_client
# was on this list and is now shipped in exactly that way, which is why it is deliberately absent below.
#
# Comment lines are stripped before matching; `command -v <bin>` guards count as hits ON PURPOSE -- graceful
# degradation is exactly how these hid.
_DEBUG_ONLY_BINS='sqlite3'   # userdebug-only AND not shipped by us; see the note above
_sqlhits=$(for _f in "$DEST"/bin/*.sh; do
  sed 's/^[[:space:]]*#.*//' "$_f" | grep -HnE "$_DEBUG_ONLY_BINS" /dev/stdin | sed -e "s|^/dev/stdin|$(basename "$_f")|" -e "s|(standard input)|$(basename "$_f")|"
done 2>/dev/null | grep -v '^$' || true)
if [ -n "$_sqlhits" ]; then
  echo "[stage-vendor] FATAL: staged script(s) invoke a userdebug-only binary (dead on user builds):"
  echo "$_sqlhits" | sed 's/^/[stage-vendor]   /'
  exit 1
fi
echo "[stage-vendor] assembled $DEST from core/ + editions/endospore/"
