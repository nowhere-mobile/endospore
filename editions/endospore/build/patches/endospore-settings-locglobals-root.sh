#!/usr/bin/env bash
# endospore-settings-locglobals-root.sh -- let roamd (uid root) write GrapheneOS's two location globals (NWP-20261101-25).
#
# GrapheneOS marks Settings.Global NETWORK_LOCATION ("network_location") and GEOCODER ("geocoder") @Protected
# (frameworks/base/core/java/android/provider/Settings.java, the 2026061600 tree ~:14512-14520):
#   @Protected(restrictReads = false, readWrite = {KnownSystemPackage.SETTINGS, KnownSystemPackage.SETUP_WIZARD})
# SettingsProvider.checkProtectedSettingAccess enforces it on every global write (mutateGlobalSetting): it allows the
# in-process caller, the listed packages, the shell package (adb) and, on a debuggable build only, uid root with NO
# calling package. `cmd settings` from uid 0 is not that caller: SettingsService.resolveCallingPackage names uid 0's
# package "root", so the write is refused with a SecurityException on a user build AND on userdebug.
# roamd runs as `user root` (core/vendor-common/etc/nowhere.rc) and its SESSION-SCOPED LOCATION GLOBALS block
# (NWP-20261016-45) is the one writer of these two keys: it claims them for the profile in front and restores the
# baseline when that session ends. Every claim on a device was therefore refused and read back as not applied --
# frankel 0.5.50, NW-cdd075c0ac79: "wrote network_location=2 geocoder=2, NOT APPLIED (reads network_location=null,
# geocoder=2)". The 2026-10-16 proof passed only because its value was set from an adb shell (com.android.shell).
#
# The fix adds ONE exception beside the shell exemption. It applies only when every one of these holds: a write (not a
# read), Binder.getCallingUid() == ROOT_UID, the calling package is exactly "root", the map is the Global one, and the
# key is Settings.Global.NETWORK_LOCATION or Settings.Global.GEOCODER (by the constant). Any other key, any read path
# and any other caller behave exactly as before. Residual: any root process may now write these two keys; root on
# these builds is init's daemons under SELinux, and the keys only choose a location provider.
#
# Lands in SettingsProvider.apk (/system/priv-app) -> `m`, system reflash. To verify a build carries it: the APK's
# classes*.dex holds the literal `nowhere: allowed root to write protected setting` (patch-markers.tsv, checked by
# build-device.sh before signing); on a device logcat shows
#   SettingsProvider: nowhere: allowed root to write protected setting network_location (NWP-20261101-25)
# at a claim, and roam.log's locglobals line reads APPLIED instead of NOT APPLIED.
# Idempotent. Aborts (exit 2) unless the shell-exemption anchor appears exactly once, inside the one
# checkProtectedSettingAccess. See docs/framework-patches.md.
set -euo pipefail
T="${1:?usage: endospore-settings-locglobals-root.sh <graphene-tree>}"
SP="$T/frameworks/base/packages/SettingsProvider/src/com/android/providers/settings/SettingsProvider.java"
[ -f "$SP" ] || { echo "[settings-locglobals-root] MISSING $SP"; exit 1; }

python3 - "$SP" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
MARK = 'NWP-20261101-25 (nowhere/endospore)'
if MARK in s:
    print("[settings-locglobals-root] already patched -- skipped"); sys.exit(0)
anchor = '''        if (ksp.shell.equals(callingPackage)) {
            // ADB is used for testing
            Slog.d(LOG_TAG, "allowed shell to access protected setting " + protSetting.key());
            return;
        }
'''
patched = anchor + '''
        // NWP-20261101-25 (nowhere/endospore): roamd (init's nowhere_roamd service, uid root) is the one writer of the
        // session-scoped location globals: it claims these two keys for the profile in front and restores the baseline
        // when that session ends. `cmd settings` from uid 0 names its package "root" (SettingsService), which no list
        // above holds, so this guard refused every such write on every build type. Allow exactly that caller to WRITE
        // exactly these two Global keys; any other key, any read and any other caller are refused as before.
        if (!isRead && Binder.getCallingUid() == ROOT_UID && "root".equals(callingPackage)
                && map == sProtectedGlobalSettings
                && (Settings.Global.NETWORK_LOCATION.equals(name) || Settings.Global.GEOCODER.equals(name))) {
            Slog.d(LOG_TAG, "nowhere: allowed root to write protected setting " + name + " (NWP-20261101-25)");
            return;
        }
'''
if s.count(anchor) != 1:
    print("[settings-locglobals-root] shell-exemption ANCHOR found %d times, expected 1 (upstream changed?) -- aborting"
          % s.count(anchor)); sys.exit(2)
# The exemption must still sit inside checkProtectedSettingAccess, whose isRead / name / map / callingPackage the
# inserted condition reads: a block moved into another method needs a human, not a guess.
sig = '    private void checkProtectedSettingAccess(boolean isRead, String name, ArrayMap<String, Settings.ProtectedSetting> map) {\n'
if s.count(sig) != 1:
    print("[settings-locglobals-root] expected exactly one checkProtectedSettingAccess signature (upstream changed?) -- aborting"); sys.exit(2)
start = s.index(sig); end = s.find('\n    }\n', start)
if not (start < s.index(anchor) < end):
    print("[settings-locglobals-root] the shell exemption is not inside checkProtectedSettingAccess (upstream changed?) -- aborting"); sys.exit(2)
open(p, 'w', encoding='utf-8', newline='').write(s.replace(anchor, patched, 1))
print("[settings-locglobals-root] checkProtectedSettingAccess now lets root write network_location / geocoder (NWP-20261101-25)")
PY
