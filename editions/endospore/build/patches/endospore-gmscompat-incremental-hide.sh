#!/usr/bin/env bash
# endospore-gmscompat-incremental-hide.sh -- hide incremental_delivery from sandboxed Play (DIA-20260802).
#
# Sandboxed Play (GrapheneOS gmscompat) runs com.android.vending / com.google.android.gms UNPRIVILEGED, so
# they cannot hold the signature perm USE_INSTALLER_V2 and cannot perform incremental/streaming (DataLoader)
# installs. Yet Finsky ATTEMPTS a streaming install for large (streaming-flagged / App-Bundle) apps and
# HARD-FAILS on the first try -- "Session creation failed errorCode=5402 / SecurityException: You need the
# com.android.permission.USE_INSTALLER_V2 permission to use a data loader" -- surfacing a user-visible
# "Can't install <app> - Try again"; only the retry falls back to a full-APK install. On the amnesiac roam
# this recurs on the FIRST big-game install after every login (Play is cold + un-synced), which reads as
# broken even though it self-heals. Fix: make the sandboxed-Play PackageManager wrapper (GmcPackageManager,
# which already spoofs a system feature per-app for uwb) report FEATURE_INCREMENTAL_DELIVERY as ABSENT, so
# Finsky never attempts streaming and full-installs on the first tap. Per-app by construction
# (GmcPackageManager exists only in gmscompat processes, and we further gate on isPlayStore()/isGmsCore());
# adb, `pm install`, system and every non-gmscompat app keep incremental. Overrides BOTH
# hasSystemFeature(name,version) AND getSystemAvailableFeatures() so it works whether Finsky queries or
# enumerates. Proven on lynx via an A/B global-disable (ro.incremental.enable=false): the first post-roam
# big-game install throws 5402 WITH the feature present, and succeeds on the first tap WITHOUT it. Without
# this patch the first post-roam big-game install shows a 5402 error and needs a manual retry. Idempotent;
# fail-open (if the wrapper is inactive the real feature is reported, no crash). See docs/sandboxed-play-roam.md.
set -euo pipefail
T="${1:?usage: endospore-gmscompat-incremental-hide.sh <graphene-tree>}"
F="$T/frameworks/base/core/java/com/android/internal/gmscompat/sysservice/GmcPackageManager.java"
[ -f "$F" ] || { echo "[incremental-hide] MISSING $F"; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'FEATURE_INCREMENTAL_DELIVERY' in s:
    print("[incremental-hide] already applied -- skipped"); sys.exit(0)
old = '''    @Override
    public boolean hasSystemFeature(String name) {
        switch (name) {
            // checked before accessing privileged UwbManager
            case "android.hardware.uwb":
                return false;
        }

        return super.hasSystemFeature(name);
    }'''
new = '''    @Override
    public boolean hasSystemFeature(String name) {
        switch (name) {
            // checked before accessing privileged UwbManager
            case "android.hardware.uwb":
                return false;
        }

        return super.hasSystemFeature(name);
    }

    // NOWHERE (endospore): sandboxed Play/GMS are unprivileged and lack USE_INSTALLER_V2, so they cannot
    // perform incremental/streaming (DataLoader) installs. Report FEATURE_INCREMENTAL_DELIVERY absent so
    // Finsky does a full-APK install instead of hard-failing at session creation (errorCode=5402). Both the
    // 1-arg hasSystemFeature (which delegates virtually to this 2-arg form) and getSystemAvailableFeatures
    // (enumeration) are covered so it works whichever way Finsky probes.
    @Override
    public boolean hasSystemFeature(String name, int version) {
        if ((GmsCompat.isPlayStore() || GmsCompat.isGmsCore())
                && PackageManager.FEATURE_INCREMENTAL_DELIVERY.equals(name)) {
            return false;
        }
        return super.hasSystemFeature(name, version);
    }

    @Override
    public android.content.pm.FeatureInfo[] getSystemAvailableFeatures() {
        android.content.pm.FeatureInfo[] features = super.getSystemAvailableFeatures();
        if (features == null || !(GmsCompat.isPlayStore() || GmsCompat.isGmsCore())) {
            return features;
        }
        java.util.ArrayList<android.content.pm.FeatureInfo> out =
                new java.util.ArrayList<>(features.length);
        for (android.content.pm.FeatureInfo fi : features) {
            if (fi != null && PackageManager.FEATURE_INCREMENTAL_DELIVERY.equals(fi.name)) {
                continue;
            }
            out.add(fi);
        }
        return out.toArray(new android.content.pm.FeatureInfo[0]);
    }'''
if old not in s:
    print("[incremental-hide] PATCH ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
print("[incremental-hide] hid FEATURE_INCREMENTAL_DELIVERY from sandboxed Play in GmcPackageManager")
PY
