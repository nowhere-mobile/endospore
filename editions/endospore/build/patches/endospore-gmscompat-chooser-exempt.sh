#!/usr/bin/env bash
# endospore-gmscompat-chooser-exempt.sh -- sandboxed-Play roam (DIA-20260801, extended DIA-20260802-10).
#
# GrapheneOS's PackageInstallerSession blocks a non-first-party installer from installing the GmsCompat
# packages (com.google.android.gms / com.android.vending) -- "blocked to prevent breaking gmscompat".
# The amnesiac roam reinstalls the EXACT sealed (already-sanctioned) APK version via the nowhere chooser
# (com.nowhere.chooser), which is neither shell nor the first-party app source, so the reinstall was
# refused and sandboxed Play could never roam. Exempt the chooser: it only ever re-installs a version the
# store already vetted -- exactly what the check guards against.
#
# THREE exemptions (all safe, all needed for the sandboxed-Play roam + on-demand group-materialize):
#   1. initiatingPackageName == com.nowhere.chooser  -- the normal installApkSet roam path (DIA-20260801).
#   2. mInstallSource.mInstallerPackageName == com.nowhere.chooser  -- the ON-DEMAND paths (DIA-20260802-10):
#      an archived-placeholder install (installPackageArchived) and the tap-time unarchive carry the SEALED
#      package's ORIGINAL installer as initiatingPackageName (not the chooser), so the check missed them and
#      Play Store's archived placeholder was killed ("Session destroyed ... blocked ... gmscompat"). The
#      chooser is always the real INSTALLER of record, so match on that too.
#   3. isArchivedInstallation()  -- an archived placeholder installs NO code (it's a code-less shell), so it
#      cannot "break gmscompat"; the real code install (unarchive/tap) stays gated by exemptions 1/2.
# Without this patch on the image, sandboxed Play does not roam (pre-DIA behaviour); without exemptions 2/3,
# an ON-DEMAND (group-materialize) Play Store can't raise its placeholder so there is nothing to tap.
# Idempotent; robust to a pristine OR an already-(#531)-patched tree. See docs/sandboxed-play-roam.md +
# docs/ondemand-sandboxed-play-group.md.
set -euo pipefail
T="${1:?usage: endospore-gmscompat-chooser-exempt.sh <graphene-tree>}"
F="$T/frameworks/base/services/core/java/com/android/server/pm/PackageInstallerSession.java"
[ -f "$F" ] || { echo "[gmscompat-exempt] MISSING $F"; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# Idempotency marker: the installer-based exemption (exemption 2) uniquely identifies the full patch.
if 'com.nowhere.chooser".equals(mInstallSource.mInstallerPackageName)' in s:
    print("[gmscompat-exempt] full exemption (initiator+installer+archived) already applied -- skipped"); sys.exit(0)

# Case A: tree already carries the #531 initiator-only exemption -> append the installer + archived checks.
anchor_531 = '''                && !"com.nowhere.chooser".equals(initiatingPackageName)) {'''
new_531 = '''                && !"com.nowhere.chooser".equals(initiatingPackageName)
                && !"com.nowhere.chooser".equals(mInstallSource.mInstallerPackageName)
                && !isArchivedInstallation()) {'''

# Case B: pristine upstream block -> add all three exemptions at once.
anchor_pristine = '''                && !android.util.PackageUtils.getFirstPartyAppSourcePackageName(mContext)
                        .equals(initiatingPackageName)) {'''
new_pristine = '''                && !android.util.PackageUtils.getFirstPartyAppSourcePackageName(mContext)
                        .equals(initiatingPackageName)
                && !"com.nowhere.chooser".equals(initiatingPackageName)
                && !"com.nowhere.chooser".equals(mInstallSource.mInstallerPackageName)
                && !isArchivedInstallation()) {'''

if anchor_531 in s:
    s = s.replace(anchor_531, new_531, 1)
    print("[gmscompat-exempt] added installer + archived exemptions to the #531-patched block")
elif anchor_pristine in s:
    s = s.replace(anchor_pristine, new_pristine, 1)
    print("[gmscompat-exempt] applied chooser + installer + archived exemptions (pristine tree)")
else:
    print("[gmscompat-exempt] PATCH ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)

open(p, 'w', encoding='utf-8').write(s)
PY
