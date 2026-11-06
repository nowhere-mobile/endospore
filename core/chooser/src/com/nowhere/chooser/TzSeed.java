package com.nowhere.chooser;

/** The AUTOMATIC time-zone seed (Q148, docs/product-decisions.md 2026-10-20): the profile's last zone when the
 *  platform knows it, else the baked default. A seed, never an override (DIA-58): the caller re-enables
 *  auto-detection after applying it. No network is involved. Pure java.lang/java.util so a javac suite compiles it. */
final class TzSeed {
    private TzSeed() {}

    /** lastTz when it is non-empty and known, else baked. Never calls known with null or "". */
    static String pick(String lastTz, String baked, java.util.function.Predicate<String> known) {
        if (lastTz != null && !lastTz.isEmpty() && known.test(lastTz)) return lastTz;
        return baked;
    }
}
