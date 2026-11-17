package com.nowhere.chooser;

/**
 * NWP-20261205-02 (h58 #1, docs/product-decisions.md 2026-11-04): the chooser half of "a restore says when the last
 * save left a scope unsaved" -- the daemon reply parser and the decided line. Pure (java.* only), so
 * test-last-save-java.sh compiles it with its cases alone.
 *
 * Backlog row "The scopes advance INDEPENDENTLY with no consistency rule, so a partial seal leaves the stored profile
 * internally skewed". The seal records each round's per-scope verdict (NWP-20261204-01, `noteLastRound`), and a
 * sign-in whose last round left a scope unsaved shows {@link #LINE} beside the Auto sweep's card.
 *
 * The daemon contract (the harvest 66 gate verb, read-only here):
 *   GET-LASTSAVE\n  -> "LASTSAVE v=1 unsaved=<parts> t=<unix seconds>" (the file line, without its LF) / "NONE"
 * where <parts> is 1-5 comma-separated <scope>=<cause>, scope in {vault,de,media,sys,apps} at most once each and
 * cause [a-z][a-z0-9-]{0,31}: the file's own rule (core/agent roundPartsOK / roundCauseOK). Any other reply,
 * an older daemon's included, reads as nothing to show.
 */
final class LastSaveCopy {
    private LastSaveCopy() {}

    /** h58 #1, byte for byte. test-last-save-java.sh checks it against docs/product-decisions.md. */
    static final String LINE = "Your last save did not finish; some of your data is from an earlier save.";

    private static final java.util.List<String> SCOPES = java.util.Arrays.asList("vault", "de", "media", "sys", "apps");
    private static final int PARTS_MAX = 5;
    private static final int CAUSE_MAX = 32;

    /** True only for a well-formed LASTSAVE line: the last save left at least one scope unsaved. */
    static boolean unsaved(String reply) {
        if (reply == null) return false;
        String[] f = reply.split(" ", -1);
        if (f.length != 4 || !"LASTSAVE".equals(f[0]) || !"v=1".equals(f[1])) return false;
        if (!f[2].startsWith("unsaved=") || !partsOK(f[2].substring("unsaved=".length()))) return false;
        if (!f[3].startsWith("t=")) return false;
        String n = f[3].substring(2);
        if (n.isEmpty() || n.length() > 19) return false;
        for (int i = 0; i < n.length(); i++) {
            char c = n.charAt(i);
            if (c < '0' || c > '9') return false;
        }
        try { return Long.parseLong(n) > 0; } catch (NumberFormatException e) { return false; }
    }

    /** Show the line: the last save left a scope unsaved and this sign-in (its user serial) has not shown it yet. */
    static boolean show(boolean unsaved, String stamp, String serial) {
        return unsaved && serial != null && !serial.equals(stamp);
    }

    private static boolean partsOK(String parts) {
        String[] items = parts.split(",", -1);
        if (items.length < 1 || items.length > PARTS_MAX) return false;
        java.util.Set<String> seen = new java.util.HashSet<>();
        for (String it : items) {
            int eq = it.indexOf('=');
            if (eq <= 0) return false;
            String scope = it.substring(0, eq);
            if (!SCOPES.contains(scope) || !seen.add(scope)) return false;
            if (!causeOK(it.substring(eq + 1))) return false;
        }
        return true;
    }

    private static boolean causeOK(String c) {
        if (c.isEmpty() || c.length() > CAUSE_MAX) return false;
        char h = c.charAt(0);
        if (h < 'a' || h > 'z') return false;
        for (int i = 1; i < c.length(); i++) {
            char x = c.charAt(i);
            if (!((x >= 'a' && x <= 'z') || (x >= '0' && x <= '9') || x == '-')) return false;
        }
        return true;
    }
}
