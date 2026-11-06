#!/bin/bash
# #84 DELETION (+ future write-back): let a roamed app manage its OWN on-demand media -- e.g. Organic Maps
# updates a map by unlinking the old <region>.mwm before writing the new one. The mediad FUSE overlay labels its
# served files context=nowhere_media_file; under enforcing SELinux the app's unlink(2) needs unlink on that type,
# which AOSP's app create/unlink neverallow (system/sepolicy/private/app_neverallows.te) forbids for every file
# type outside the app-sandbox set.
#
# To exempt our type there we must NAME it in a PLATFORM neverallow -- but that neverallow is verified against a
# platform-only policy (the `sepolicy_neverallows` target: plat public+private, NO system_ext/vendor), so a
# SYSTEM_EXT_PRIVATE type fails with `unknown type nowhere_media_file`. So this patch does two platform-side edits:
#   1. DECLARE nowhere_media_file as a PLATFORM type in system/sepolicy/public/file.te (moved out of the vendor
#      dir; nowhere.te keeps only the labeling + allows). mlstrustedobject bridges MLS (app s0:cN <-> s0 file).
#   2. EXEMPT it (-nowhere_media_file) from the app create/unlink neverallow so the vendor `allow appdomain
#      nowhere_media_file:file unlink` compiles.
#
# SECURITY: nowhere_media_file exists ONLY inside the per-app mediad FUSE overlays (mounted context=), each over
# that app's OWN media dir in that app's OWN user -- so this lets an app manage ITS OWN on-demand media and
# nothing else (DAC + per-user mounts still forbid touching another app's data). The per-domain permission stays
# gated by the VENDOR policy (nowhere.te grants only unlink today; write-back's create/write is a separate later
# grant) -- the exemption only removes the compile-time neverallow, it grants nothing by itself.
#
# Idempotent out-of-repo tree patch (backs up each file to .diaspore-orig); run before `m` (rebuilds sepolicy).
# Same class as editions/diaspore/build/patches/keyguard-roaming-noocclude.sh and the AVB/Trebuchet tree patches.
set -e
LINEAGE="${1:-/mnt/build/lineage}"

FDECL="$LINEAGE/system/sepolicy/public/file.te"
FNEVER="$LINEAGE/system/sepolicy/private/app_neverallows.te"
[ -f "$FDECL" ]  || { echo "no public/file.te at $FDECL"; exit 1; }
[ -f "$FNEVER" ] || { echo "no private/app_neverallows.te at $FNEVER"; exit 1; }

# --- 1. platform type declaration (after the related media_rw_data_file decl, a unique anchor) ---
if grep -q "nowhere_media_file" "$FDECL"; then
  echo "sepolicy-app-media-manage: public/file.te already has the type (skip)"
else
  cp "$FDECL" "$FDECL.diaspore-orig"
  sed -i '/^type media_rw_data_file, file_type, data_file_type, core_data_file_type, mlstrustedobject;/a\
# Diaspore #84: on-demand media served by the nowhere_mediad per-app FUSE overlay (context=nowhere_media_file).\
# Declared PLATFORM-side (not the vendor system_ext sepolicy dir) so the app create/unlink neverallow exemption\
# in private/app_neverallows.te can name it -- a platform neverallow is checked against a platform-only policy.\
# Labeling (context= mount) + every app/daemon allow live in vendor/diaspore/sepolicy/nowhere.te.\
# mlstrustedobject bridges MLS: an app at s0:cN reads/deletes this s0 file (like ringtone_file/ota_package_file).\
type nowhere_media_file, file_type, mlstrustedobject;' "$FDECL"
  grep -q "nowhere_media_file" "$FDECL" || { echo "PATCH FAILED (file.te anchor not found)"; cp "$FDECL.diaspore-orig" "$FDECL"; exit 1; }
  echo "sepolicy-app-media-manage: declared nowhere_media_file in public/file.te"
fi

# --- 2. app create/unlink neverallow exemption ---
if grep -q "nowhere_media_file" "$FNEVER"; then
  echo "sepolicy-app-media-manage: app_neverallows.te already exempt (skip)"
else
  cp "$FNEVER" "$FNEVER.diaspore-orig"
  sed -i '/-app_data_file .*# The apps sandbox itself/a\  -nowhere_media_file       # #84: an app manages its OWN on-demand media (mediad FUSE, per-app dir)' "$FNEVER"
  grep -q "nowhere_media_file" "$FNEVER" || { echo "PATCH FAILED (app_neverallows.te anchor not found)"; cp "$FNEVER.diaspore-orig" "$FNEVER"; exit 1; }
  echo "sepolicy-app-media-manage: exempted nowhere_media_file from app create/unlink neverallow"
fi

# --- 3. frozen-API + Treble compat bookkeeping (frozen-API platforms only, e.g. GrapheneOS/Endospore) ---
# A build against a FROZEN public sepolicy API (BOARD_API_LEVEL >= 202604) runs se_freeze_test +
# treble_sepolicy_tests, which reject a NEW public type unless it is (a) present in the LATEST frozen public
# snapshot (prebuilts/api/<YYYYMM>/public) and (b) listed in the "new_objects" ignore of every PRIOR frozen
# version. LineageOS/FP3 has no such snapshots, so the globs below match nothing and this section no-ops.
# Version-agnostic (discovers the frozen versions, so it survives a GrapheneOS bump); idempotent; touches
# only files that exist. Without it the Endospore build fails at se_freeze_test then treble_sepolicy_tests.
APIROOT="$LINEAGE/system/sepolicy/prebuilts/api"
if [ -d "$APIROOT" ]; then
  LATEST=$(ls "$APIROOT" 2>/dev/null | grep -E '^[0-9]{6}$' | sort -n | tail -1)
  FROZEN="$APIROOT/$LATEST/public/file.te"
  if [ -n "$LATEST" ] && [ -f "$FROZEN" ] && ! grep -q 'nowhere_media_file' "$FROZEN"; then
    printf '\n%s\n%s\n' \
      '# Diaspore #84: nowhere_media_file mirrored into the frozen public API so se_freeze_test accepts it.' \
      'type nowhere_media_file, file_type, mlstrustedobject;' >> "$FROZEN"
    echo "sepolicy-app-media-manage: declared nowhere_media_file in frozen $LATEST/public/file.te"
  fi
  for VDIR in "$LINEAGE"/system/sepolicy/private/compat/*/; do
    V="$(basename "$VDIR")"
    echo "$V" | grep -qE '^[0-9]{6}$' || continue   # only YYYYMM frozen versions
    [ "$V" = "$LATEST" ] && continue                # the current API level uses the frozen snapshot, not the ignore
    IG="$VDIR$V.ignore.cil"
    [ -f "$IG" ] || continue
    grep -q 'nowhere_media_file' "$IG" && continue
    grep -q '^  ( new_objects$' "$IG" || continue
    sed -i '/^  ( new_objects$/a\    nowhere_media_file' "$IG"
    echo "sepolicy-app-media-manage: listed nowhere_media_file in $V.ignore.cil"
  done
fi
echo "sepolicy-app-media-manage: done"
