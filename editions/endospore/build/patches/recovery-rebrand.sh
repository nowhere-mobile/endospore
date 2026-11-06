#!/usr/bin/env bash
# Rebrand the GrapheneOS recovery + fastbootd menu titles to Endospore (DIA-20260622). The fastbootd and
# recovery screens (seen when flashing) show hardcoded title strings in bootable/recovery:
#   recovery.cpp:        "GrapheneOS Recovery"
#   fastboot/fastboot.cpp: "GrapheneOS Fastboot"
# This is the OS-edition brand on the recovery UI (OS-level, not device). Done as a direct SOURCE PATCH of
# the out-of-repo bootable/recovery tree (same class as the device-tree/BoardConfig edits), reapplied on the
# build host before `m`. It lands in the recovery ramdisk, so after building, reflash the partition that
# carries it (init_boot / vendor_boot on this A/B device). Idempotent (a second run finds nothing to change).
# Asserts both titles afterwards and exits 2 with a "[recovery-rebrand] DRIFT:" line when a literal moved or
# fastboot/fastboot.cpp is missing (NWP-20261011-15).
#
# The fastbootd LOGO bitmap (bootable/recovery/res-*/images/fastbootd.png) is left as-is for now -- it's a
# generic fastbootd glyph, not a "GrapheneOS" wordmark; revisit if it turns out to carry branding.
#
# Usage: recovery-rebrand.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: recovery-rebrand.sh <graphene-tree-root>}"
R="$TREE/bootable/recovery"
[ -f "$R/recovery.cpp" ] || { echo "no bootable/recovery at $R" >&2; exit 1; }
[ -f "$R/fastboot/fastboot.cpp" ] || { echo "[recovery-rebrand] DRIFT: no fastboot/fastboot.cpp under $R (upstream moved the fastbootd source?)" >&2; exit 2; }  # assert:rec-fastboot-present
sed -i 's/"GrapheneOS Recovery"/"endospore Recovery"/' "$R/recovery.cpp"
sed -i 's/"GrapheneOS Fastboot"/"endospore Fastboot"/' "$R/fastboot/fastboot.cpp"
# End-state assertion (NWP-20261011-15): sed exits 0 whether or not it matched, so assert the titles.
drift(){ echo "[recovery-rebrand] DRIFT: $1" >&2; exit 2; }
grep -cF -- '"endospore Recovery"' "$R/recovery.cpp" >/dev/null || drift "\"endospore Recovery\" absent from $R/recovery.cpp (upstream title literal moved?)"  # assert:rec-endospore-recovery
grep -cF -- '"endospore Fastboot"' "$R/fastboot/fastboot.cpp" >/dev/null || drift "\"endospore Fastboot\" absent from $R/fastboot/fastboot.cpp (upstream title literal moved?)"  # assert:rec-endospore-fastboot
! grep -cF -- '"GrapheneOS Recovery"' "$R/recovery.cpp" >/dev/null || drift "\"GrapheneOS Recovery\" still present in $R/recovery.cpp"  # assert:rec-graphene-recovery
! grep -cF -- '"GrapheneOS Fastboot"' "$R/fastboot/fastboot.cpp" >/dev/null || drift "\"GrapheneOS Fastboot\" still present in $R/fastboot/fastboot.cpp"  # assert:rec-graphene-fastboot
echo "[recovery-rebrand] recovery/fastbootd titles -> endospore in $R"
