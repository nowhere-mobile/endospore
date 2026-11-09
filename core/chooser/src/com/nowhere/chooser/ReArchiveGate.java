package com.nowhere.chooser;

/**
 * ReArchiveReceiver's verdict (#206), lifted out of the receiver so a JDK can run it: which materialised on-demand
 * app is handed to {@code PackageInstaller.requestArchive}, dropping its local APK mid-session. java.* only. The
 * receiver reads the clock, the usage stats, the package's update time and the settings; this decides. It also
 * decides when the next sweep runs (NWP-20261120-12).
 */
final class ReArchiveGate {
    private ReArchiveGate() {}

    // The sandboxed-Play stack, as ProfileActivity's GMS_PKG, GSF_PKG and VENDING_PKG. Literals: java.* only.
    private static final java.util.Set<String> PLAY_STACK = java.util.Set.of("com.android.vending",
            "com.google.android.gms", "com.google.android.gsf");

    /**
     * The idle threshold in ms (0 or less = Never). A positive dev/test override
     * ({@code settings put global nowhere.rearchive_idle_ms N}) beats the profile's own value, Never included;
     * an absent, zero or negative override leaves the profile's choice standing.
     */
    static long effectiveIdle(long globalOverrideMs, long profileIdleMs) {
        return globalOverrideMs > 0 ? globalOverrideMs : profileIdleMs;
    }

    /**
     * True iff pkg does a job without being opened, so the idle reclaim keeps it (h51 #6, NWP-20261122-10): it is
     * the current keyboard (imeComponent, Settings.Secure default_input_method, a flattened component), the
     * always-on VPN (vpnPkg, always_on_vpn_app, a package), an enabled accessibility service or notification
     * listener (a11yServices, listeners: ':'-separated flattened components), a holder of one of the roles the
     * receiver reads (roleHolders), or a Play stack member an app with code on the phone needs ({@link #playNeeded},
     * h59 #8, NWP-20261129-14). The package must match exactly: com.foo does not own com.foo.bar/.X or com.foo2/.X,
     * and a component without a '/' owns nothing. A null or empty source holds nothing.
     */
    static boolean holdsJob(String pkg, String imeComponent, String vpnPkg, String a11yServices, String listeners,
            java.util.Set<String> roleHolders, java.util.Set<String> playNeeded) {
        if (pkg == null || pkg.isEmpty()) return false;
        return ownsComponent(pkg, imeComponent) || pkg.equals(vpnPkg) || inList(pkg, a11yServices)
                || inList(pkg, listeners) || (roleHolders != null && roleHolders.contains(pkg))
                || (playNeeded != null && playNeeded.contains(pkg));
    }

    /**
     * The Play stack members some app with code on the phone needs (h59 #8, NWP-20261129-14). The map holds each such
     * app and its deps, as ProfileActivity.appDeps computes them; any other dep is dropped. appDeps of a stack member
     * is its group siblings, so each member is kept while another member with code, or a Play client with code, names
     * it. A member alone on the phone is not kept by its own code, and while two members have code the stack is not
     * idle-reclaimed (the NWP-20260830-07 unit rule: never a half stack). This is the reading of "needs" through
     * appDeps, which the backlog row names; the decision's words name no function.
     */
    static java.util.Set<String> playNeeded(java.util.Map<String, java.util.List<String>> depsOfAppsWithCode) {
        java.util.Set<String> out = new java.util.HashSet<>();
        for (java.util.List<String> deps : depsOfAppsWithCode.values()) {
            for (String dep : deps) {
                if (PLAY_STACK.contains(dep)) out.add(dep);
            }
        }
        return out;
    }

    /** True iff any ':'-separated flattened component in list belongs to pkg. */
    private static boolean inList(String pkg, String list) {
        if (list == null) return false;
        for (String flat : list.split(":")) {
            if (ownsComponent(pkg, flat)) return true;
        }
        return false;
    }

    /** True iff the flattened component (package/class) belongs to exactly pkg. */
    private static boolean ownsComponent(String pkg, String flat) {
        if (flat == null) return false;
        int slash = flat.indexOf('/');
        return slash > 0 && pkg.equals(flat.substring(0, slash));
    }

    /**
     * True iff the app should be re-archived. Never (idle 0 or less) keeps every app until logoff, and an app that
     * holds a job ({@link #holdsJob}) is kept whatever its times. Otherwise the "last active" time is the latest of
     * the last time on screen (lastUsedMs), the last time visible, the last foreground-service use and the last
     * (re)install: a keyboard or a VPN works without being on screen (h51 #6, NWP-20261122-10), a freshly
     * materialised app that has not been foregrounded yet is not archived on the very next sweep, and an absent
     * usage service (every usage time 0, the blind sweep of NWP-20260912-06) falls back to materialise age rather
     * than archiving every app. The app goes once a full idle period has passed since then; a clock behind that
     * time keeps it.
     */
    static boolean archive(long nowMs, long idleMs, long lastUsedMs, long lastVisibleMs, long lastFgsMs,
            long lastUpdateMs, boolean holdsJob) {
        if (idleMs <= 0) return false;
        if (holdsJob) return false;
        long last = Math.max(Math.max(lastUsedMs, lastVisibleMs), Math.max(lastFgsMs, lastUpdateMs));
        return nowMs - last >= idleMs;
    }

    /**
     * When the next idle-reclaim sweep should run, given the one already pending (0 = none known) and the time a
     * caller wants. The earlier pending sweep wins, so a re-arm never moves a sweep later. A due time at or before
     * now is not pending (it fired or was dropped), so the wanted time stands.
     */
    static long armAt(long pendingDueMs, long nowMs, long wantMs) {
        return pendingDueMs > nowMs && pendingDueMs <= wantMs ? pendingDueMs : wantMs;
    }
}
