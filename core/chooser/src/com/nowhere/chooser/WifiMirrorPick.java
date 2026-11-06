package com.nowhere.chooser;

/**
 * NWP-20261120-14: which WIFI-MIRROR lines WifiMirror.capture sends, and in what order. The framework lists saved
 * networks in WifiConfigManager's internal order, not the user's, so a plain "first MAX" could leave off the network
 * the session is connected to, and the switch to user 0 then drops Wi-Fi (#98). No Android types: a javac suite
 * (core/chooser/tests/wifi-mirror-pick) compiles this file alone.
 */
final class WifiMirrorPick {
    /**
     * The mirror's own cap. It stays at 16 because the gate adopts every mirrored network into its phone-wide store
     * (amnesia finding #9; docs/wifi-retention-spec.md §7.2 item 7). It must stay at or below handleWifiMirror's
     * bound (core/agent/main.go, {@code n > 32}); the suite reads that bound from main.go.
     */
    static final int MAX = 16;

    private WifiMirrorPick() {}

    /**
     * The encoded lines to send: the connected network's line first, then every other line in its original order, at
     * most MAX. {@code currentAt} is its index in {@code lines}; -1, an index outside the list or a null entry means
     * none. Null entries are skipped and do not count toward MAX. Never null; the input is not changed.
     */
    static java.util.List<String> order(java.util.List<String> lines, int currentAt) {
        java.util.List<String> out = new java.util.ArrayList<>();
        if (lines == null) return out;
        if (currentAt < 0 || currentAt >= lines.size() || lines.get(currentAt) == null) currentAt = -1;
        // Pick the current line BEFORE filling to MAX: a cap applied first loses a late current network.
        if (currentAt != -1) out.add(lines.get(currentAt));
        for (int i = 0; i < lines.size() && out.size() < MAX; i++) {
            if (i == currentAt || lines.get(i) == null) continue;
            out.add(lines.get(i));
        }
        return out;
    }
}
