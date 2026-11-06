#!/usr/bin/env bash
# Endospore / Pixel 7a (lynx) Launcher3: keep a clean empty LANDING page (E.5d UX parity, DIA-20260710).
#
# WHY: the Endospore default home (default_workspace_5x5.xml) puts the 5 primary apps in the hotseat (dock)
# and the rest on screen 1 (page 2), leaving screen 0 (the landing) empty -- so you land on wallpaper + dock,
# then swipe right to the apps, IDENTICAL to the Diaspore FP3. But Launcher3 only KEEPS that empty leading
# page when QSB_ON_FIRST_SCREEN is true; otherwise the page-2 items collapse onto the landing. Stock
# Launcher3 ships QSB_ON_FIRST_SCREEN=false (the buildconfig.sh default), so flip the default to true.
#
# Unlike LineageOS/Trebuchet, this Launcher3 has no res/layout/search_container_workspace.xml to overlay to
# suppress a search bar -- GrapheneOS ships no Google search widget, so nothing is drawn on the leading page;
# the flag only governs whether the empty page survives. (Verify on-device after flashing; if a bar ever
# appears, add the suppression then.)
#
# Direct SOURCE PATCH of the buildconfig generator (the genrule at Launcher3/Android.bp:183 runs
# tools/buildconfig.sh with no QSB override, so it falls to the :-false default). Same class as
# launcher3-grid.sh -- run once on the graphene tree before `m`. Idempotent. Exits 2 with a
# "[launcher3-qsb] DRIFT:" line when the default line is not found (NWP-20261011-15).
#
# Usage: launcher3-qsb-firstscreen.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: launcher3-qsb-firstscreen.sh <graphene-tree-root>}"
BC="$TREE/packages/apps/Launcher3/tools/buildconfig.sh"
[ -f "$BC" ] || { echo "no buildconfig.sh at $BC" >&2; exit 1; }

OLD='QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-false}'
NEW='QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-true}'
if grep -cF -- "$OLD" "$BC" >/dev/null; then
  sed -i 's/QSB_ON_FIRST_SCREEN = ${overrides\[QSB_ON_FIRST_SCREEN\]:-false}/QSB_ON_FIRST_SCREEN = ${overrides[QSB_ON_FIRST_SCREEN]:-true}/' "$BC"
  echo "[launcher3-qsb] flipped QSB_ON_FIRST_SCREEN default false->true in $BC"
elif grep -cF -- "$NEW" "$BC" >/dev/null; then
  echo "[launcher3-qsb] already applied -- QSB_ON_FIRST_SCREEN default is true in $BC"
else
  # NWP-20261011-15: until this slice this branch printed "already true (or default moved)" and exited 0,
  # so an upstream move of the default line shipped a green build with the landing page collapsed.
  echo "[launcher3-qsb] DRIFT: QSB_ON_FIRST_SCREEN default line not found in $BC -- found: $(grep -m1 -F QSB_ON_FIRST_SCREEN "$BC" || echo '<no QSB_ON_FIRST_SCREEN line>')" >&2
  exit 2  # assert:qsb-drift
fi
# End-state assertion (NWP-20261011-15): the flipped line must be present after the edit.
if ! grep -cF -- "$NEW" "$BC" >/dev/null; then echo "[launcher3-qsb] DRIFT: the flipped line is absent after the edit -- $BC" >&2; exit 2; fi  # assert:qsb-flipped
