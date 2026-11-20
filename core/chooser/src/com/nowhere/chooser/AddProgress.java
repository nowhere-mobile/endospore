package com.nowhere.chooser;

import java.util.LinkedHashMap;

/**
 * NWP-20261209-05: the progress of each add nApps started, so nApps can show it on its own screen (decision
 * 2026-11-17 in docs/product-decisions.md, "nApps gets the mixed look (M); Signal leaves the curated catalog; the app
 * page points to Your apps; in-app progress reopens h51 #3"). StoreService.getApp begins an entry before FETCH-APP,
 * updates it from the same callback that moves the add's notification, and ends it in its finally. nApps reads it
 * through INowhereStore.getAddProgress and getAddsInFlight.
 *
 * Wire format: get(pkg) is "<got> <total>" in bytes, total 0 while unknown, or "" when no add of pkg is in flight.
 * inFlight() is the packages in flight, space-separated, in start order, or "" when none. An update with got < 0, or
 * with got > total when total > 0, is clamped into [0, total]; nothing here throws.
 *
 * Pure: java.lang and java.util only, so javac runs it off the build host (test-add-progress-java.sh).
 */
final class AddProgress {
    private AddProgress() {}

    private static final Object LOCK = new Object();
    // pkg -> {got, total}, in start order. Guarded by LOCK.
    private static final LinkedHashMap<String, long[]> MAP = new LinkedHashMap<>();

    /** An add of pkg starts: its entry is "0 0", and it goes to the end of the start order. */
    static void begin(String pkg) {
        if (pkg == null || pkg.isEmpty()) return;
        synchronized (LOCK) {
            MAP.remove(pkg);
            MAP.put(pkg, new long[] {0, 0});
        }
    }

    /** The add of pkg has got bytes of total (total <= 0: unknown). No entry is made for an add that is not in flight. */
    static void update(String pkg, long got, long total) {
        if (pkg == null || pkg.isEmpty()) return;
        long t = Math.max(0, total);
        long g = Math.max(0, got);
        if (t > 0 && g > t) g = t;
        synchronized (LOCK) {
            long[] p = MAP.get(pkg);
            if (p == null) return;
            p[0] = g;
            p[1] = t;
        }
    }

    /** The add of pkg ended (installed, refused or failed): its entry goes. */
    static void end(String pkg) {
        if (pkg == null || pkg.isEmpty()) return;
        synchronized (LOCK) {
            MAP.remove(pkg);
        }
    }

    /** "<got> <total>" for an add of pkg in flight, else "". */
    static String get(String pkg) {
        if (pkg == null || pkg.isEmpty()) return "";
        synchronized (LOCK) {
            long[] p = MAP.get(pkg);
            if (p == null) return "";
            return p[0] + " " + p[1];
        }
    }

    /** The packages with an add in flight, space-separated, in start order; "" when none. */
    static String inFlight() {
        synchronized (LOCK) {
            return String.join(" ", MAP.keySet());
        }
    }
}
