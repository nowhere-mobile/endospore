package com.nowhere.chooser;

/**
 * The chooser's half of the KEEP-HEADROOM verb (Q025 [BA], NWP-20261104-07; daemon side: core/agent/keep_headroom.go).
 * Turning on Keep for an app counts the app's own size against the plan: the daemon runs it through installHeadroom
 * and answers one line. Pure Java, no Android imports, so tests/keep-headroom/run.sh compiles it under plain javac.
 */
final class KeepHeadroom {
    private KeepHeadroom() {}

    /** The payload line "<pkg>:<bytes>" (no newline), or null when the daemon would not accept it: pkg null, empty or
     *  holding whitespace or ':', or a negative size. */
    static String request(String pkg, long bytes) {
        if (pkg == null || pkg.isEmpty() || bytes < 0) return null;
        for (int i = 0; i < pkg.length(); i++) {
            char c = pkg.charAt(i);
            if (c == ':' || Character.isWhitespace(c)) return null;
        }
        return pkg + ":" + bytes;
    }

    /** TRUE = over plan ("ERR-OVERPLAN ..."), FALSE = fits ("OK" or "OK ..."), null = no verdict (null, empty, NONE,
     *  LOCAL, ERR-ARG, an older daemon's unknown-verb answer, anything else): the caller falls back. */
    static Boolean verdict(String reply) {
        if (reply == null) return null;
        String t = reply.trim();
        if (t.equals("OK") || t.startsWith("OK ")) return Boolean.FALSE;
        if (t.equals("ERR-OVERPLAN") || t.startsWith("ERR-OVERPLAN ")) return Boolean.TRUE;
        return null;
    }
}
