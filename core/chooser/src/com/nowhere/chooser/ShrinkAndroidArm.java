package com.nowhere.chooser;

import java.util.Collection;
import java.util.LinkedHashSet;

/**
 * NWP-20261210-01 (backlog row "A SHRUNKEN `#de` SCOPE WEDGES LOGOFF PERMANENTLY", decision 2026-11-05 h59 #5): the
 * pure rule for which Android package broadcast arms the agent's EXPECT-SHRINK-ANDROID intent, and its payload.
 * java.* only, so a JDK can run it (test-shrink-android-sender-java.sh). ShrinkAndroidSender does the send.
 * The package grammar is {@code core/agent/pkgname.go validPkgName}'s, the same copy UnarchiveGate holds.
 */
final class ShrinkAndroidArm {
    /** {@code Intent.ACTION_PACKAGE_DATA_CLEARED} and {@code Intent.ACTION_PACKAGE_REMOVED}, spelt out for the JDK. */
    static final String DATA_CLEARED = "android.intent.action.PACKAGE_DATA_CLEARED";
    static final String REMOVED = "android.intent.action.PACKAGE_REMOVED";
    /** The verb core/agent/main.go dispatches to handleExpectShrinkAndroid. */
    static final String VERB = "EXPECT-SHRINK-ANDROID";
    /** core/agent/shrink_intent.go shrinkAndroidMaxPkgs: the agent reads at most this many names per payload. */
    static final int MAX_PKGS = 64;
    /** One retry every 30 s, at most 20 of them: about ten minutes after the last event. */
    static final long RETRY_MS = 30000L;
    static final int MAX_RETRIES = 20;

    private ShrinkAndroidArm() {}

    /**
     * The package a broadcast arms, or null. Never in user 0 (the gate is never a session), never the chooser itself.
     * A clear-data arms. A removal arms only as a true uninstall: an update (EXTRA_REPLACING) and an archive
     * (EXTRA_ARCHIVAL) both broadcast REMOVED and keep the data, and EXTRA_DATA_REMOVED explicitly false means the
     * data was kept (nothing shrank). {@code dataRemoved} is null when the intent does not carry the extra.
     */
    static String armed(String action, String pkg, String selfPkg, int userId, boolean replacing,
                        boolean archival, Boolean dataRemoved) {
        if (userId == 0 || pkg == null || pkg.isEmpty() || pkg.equals(selfPkg) || !validPkg(pkg)) return null;
        if (DATA_CLEARED.equals(action)) return pkg;
        if (REMOVED.equals(action) && !replacing && !archival && !Boolean.FALSE.equals(dataRemoved)) return pkg;
        return null;
    }

    /** The request: the verb line, then the valid names, each once in first-seen order, at most MAX_PKGS of them,
     *  joined by one space, and one newline. Null when no valid name is left. */
    static String payload(Collection<String> names) {
        if (names == null) return null;
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String name : names) {
            if (unique.size() == MAX_PKGS) break;
            if (validPkg(name)) unique.add(name);
        }
        if (unique.isEmpty()) return null;
        return VERB + "\n" + String.join(" ", unique) + "\n";
    }

    /** The delay before retry {@code attempt} (1-based), or -1 when the sender stops retrying. */
    static long retryDelayMs(int attempt) {
        return attempt >= 1 && attempt <= MAX_RETRIES ? RETRY_MS : -1L;
    }

    /** ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$, at most 255 chars (ASCII only, so chars equal bytes). */
    static boolean validPkg(String s) {
        if (s == null || s.isEmpty() || s.length() > 255) return false;
        int segs = 0;
        boolean start = true;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
            if (c == '.') {
                if (start) return false;
                start = true;
            } else if (letter) {
                if (start) segs++;
                start = false;
            } else if ((c >= '0' && c <= '9') || c == '_') {
                if (start) return false;
            } else {
                return false;
            }
        }
        return !start && segs >= 2;
    }
}
