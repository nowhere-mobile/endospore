#!/usr/bin/env bash
# Endospore / Pixel 9a (tegu) Launcher3 grid (shared-source patch, same as devices/lynx) (DIA-20260622-03). the 9a, like lynx, satisfies BOTH the 4x5 "Pixel 2021"
# and the 5x5 "Large Phone" display-options, and stock Launcher3 picks the 4x5 (closest by minWidth/Height)
# -> 4 columns + a 4-icon dock. We want 5 columns + a 5-icon dock, so FORCE the 5x5 grid by dropping the
# 4x5 "Pixel 2021" as a default candidate; Launcher3 then falls to the next-closest canBeDefault that fits,
# which is 5x5 "Large Phone". Also shrink the 5x5 home icon 56 -> 54.
#
# Done as a DIRECT SOURCE PATCH of packages/apps/Launcher3/res/xml/device_profiles.xml (not a
# PRODUCT_PACKAGE_OVERLAYS / RRO): device_profiles.xml uses launcher3's PRIVATE styleable attrs
# (numColumns/canBeDefault/iconImageSize/...) under the res-auto namespace, which an auto-generated RRO
# resolves to the OVERLAY package, not com.android.launcher3 -> aapt2 "attribute ... not found". The home
# LAYOUT (default_workspace_5x5.xml) overlays fine and stays an RRO.
#
# Idempotent (a second run finds no "true"/"56" to change). Run after a fresh Launcher3 checkout, before `m`.
# Asserts its end state and exits 2 with a "[launcher3-grid] DRIFT:" line when the anchor moved (NWP-20261011-15).
# Usage: launcher3-grid.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: launcher3-grid.sh <graphene-tree-root>}"
L3="$TREE/packages/apps/Launcher3"
DP="$L3/res/xml/device_profiles.xml"
[ -f "$DP" ] || { echo "no device_profiles.xml at $DP" >&2; exit 1; }
# 0. GrapheneOS 2026110100 builds Launcher3 from resource_dirs ["res", "res-stock"], and res-stock carries its own
#    xml/device_profiles.xml (the stock Pixel grids: a 4-column "medium", a 5x6 "small", "large", "xl"). The later
#    directory wins, so the file the edits below make is never read and lynx came up on the 5x6 "small" grid; a profile
#    saved on 5x5 is then moved onto it with an empty top row on every page (GridSizeMigrationLogic shifts a strictly
#    taller grid down). Remove res-stock's copy so res/xml/device_profiles.xml is the grid list again, as it was on every
#    earlier tree. To undo: git -C packages/apps/Launcher3 checkout -- res-stock/xml/device_profiles.xml
rm -f "$L3/res-stock/xml/device_profiles.xml"
# 1. Force 5x5: the 4x5 "Pixel 2021" display-option must not be a default candidate (scoped sed range so
#    only its canBeDefault flips; the 5x5 options keep canBeDefault="true").
sed -i '/launcher:name="Pixel 2021"/,/\/>/ s/launcher:canBeDefault="true"/launcher:canBeDefault="false"/' "$DP"
# 2. Smaller 5x5 home icon (56 -> 54; "56" is unique to the 5x5 "Large Phone" display-options).
sed -i 's/launcher:iconImageSize="56"/launcher:iconImageSize="54"/g' "$DP"
# End-state assertion (NWP-20261011-15): the seds above exit 0 whether or not they matched, so assert the
# state they were meant to produce. The block is extracted with the SAME scoped range the edit uses and
# matched in bash -- nothing is piped into grep under pipefail.
BLOCK="$(sed -n '/launcher:name="Pixel 2021"/,/\/>/p' "$DP")"
drift(){ echo "[launcher3-grid] DRIFT: $1 -- $DP" >&2; exit 2; }
# The grid list the build reads is the one edited here: no other phone resource directory carries a device_profiles.xml
# (go/ is the Launcher3Go variant, not built for these devices).
OTHER="$(cd "$L3" && find . -path ./go -prune -o -path '*/tests' -prune -o -name device_profiles.xml -print | grep -vx './res/xml/device_profiles.xml' || true)"
[ -z "$OTHER" ] || drift "another device_profiles.xml would override the edited one: $OTHER"  # assert:grid-sole-list
if [ -n "$BLOCK" ]; then
  # A tree that still has the 4x5 grid (GrapheneOS up to the 2026-06 tags): its "Pixel 2021" is demoted.
  [[ "$BLOCK" == *'launcher:canBeDefault="false"'* ]] || drift 'no "Pixel 2021" display-option carrying canBeDefault="false" (anchor renamed or attribute moved?)'  # assert:grid-cbd-false
  [[ "$BLOCK" != *'launcher:canBeDefault="true"'* ]] || drift 'the "Pixel 2021" block still carries canBeDefault="true"'  # assert:grid-cbd-true
else
  # A tree without it (GrapheneOS 2026110100: its res/ list has no 4x5 grid): nothing to demote, so assert the outcome
  # step 1 exists for. The 5x5 "Large Phone" is a default candidate, and no grid of 4 columns and 5 or more rows is (that
  # is the shape that wins over 5x5 on these phones; the 4x4 grids' small display-options do not).
  L5="$(sed -n '/launcher:name="5_by_5"/,/<\/grid-option>/p' "$DP" | sed -n '/launcher:name="Large Phone"/,/\/>/p')"
  [[ "$L5" == *'launcher:canBeDefault="true"'* ]] || drift 'no 4x5 grid, and the 5x5 "Large Phone" is not a default candidate'  # assert:grid-5x5-default
  T4="$(awk '/<grid-option/ {r = 0; c = 0}
    /launcher:numRows="/ {v = $0; sub(/.*launcher:numRows="/, "", v); sub(/".*/, "", v); r = v + 0}
    /launcher:numColumns="/ {v = $0; sub(/.*launcher:numColumns="/, "", v); sub(/".*/, "", v); c = v + 0}
    /launcher:canBeDefault="true"/ { if (c == 4 && r >= 5) print NR }' "$DP")"
  [ -z "$T4" ] || drift 'a grid of 4 columns and 5 or more rows is a default candidate (the "Pixel 2021" anchor renamed?)'  # assert:grid-no-4x5
fi
if grep -cF -- 'launcher:iconImageSize="56"' "$DP" >/dev/null; then drift 'launcher:iconImageSize="56" still present'; fi  # assert:grid-icon-56
if ! grep -cF -- 'launcher:iconImageSize="54"' "$DP" >/dev/null; then drift 'no launcher:iconImageSize="54" (upstream icon size moved off 56?)'; fi  # assert:grid-icon-54
echo "[launcher3-grid] forced 5x5 (res/xml is the only grid list; no 4-column default wins) + iconImageSize 56->54 in $DP"
