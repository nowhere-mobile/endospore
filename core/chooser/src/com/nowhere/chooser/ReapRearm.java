package com.nowhere.chooser;

/**
 * The POLL-REAP REARM phase (NWP-20261031-03). A cold lock revoked after its reply by a logoff in flight
 * queues {@code REARM <uid>} so the gate can re-arm the idle alarm the lock's fire spent. Pure
 * (java.lang only) so a javac suite can pin the parse.
 */
final class ReapRearm {
    private ReapRearm() {}

    /** The uid of a well-formed {@code REARM <digits>} line, else -1 (a sign, inner spaces, overflow or another phase). */
    static int uid(String reply) {
        if (reply == null) return -1;
        String s = reply.trim();
        if (!s.startsWith("REARM ")) return -1;
        String d = s.substring(6);
        if (d.isEmpty()) return -1;
        for (int i = 0; i < d.length(); i++) {
            char c = d.charAt(i);
            if (c < '0' || c > '9') return -1;
        }
        try {
            return Integer.parseInt(d);
        } catch (NumberFormatException e) {
            return -1;
        }
    }
}
