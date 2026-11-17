package com.nowhere.chooser;

import java.util.function.Supplier;

/**
 * NWP-20261206-03 (Q047): the decision half of the emergency-callback window, pure Java (no Android API, no I/O), so
 * test-emergency-window-java.sh runs it under javac.
 *
 * The chooser remembers an outbound emergency call in a per-process static that does not survive a user switch
 * (docs/backlog.md, "The emergency-callback window does not survive a user switch, so a PSAP callback after a login can
 * be rejected"). Q047 adds a second record held by the login daemon. A hit in either counts. When the daemon does not
 * answer in time, the call rings rather than being rejected (fail-open): that cost is flagged in Q047 and accepted for
 * the stall case. EmergencyWindow is the I/O half that asks the daemon.
 */
final class EmergencyWindowRule {
    private EmergencyWindowRule() {}

    /** Equal to NowhereCallControlService.EMERGENCY_CALLBACK_WINDOW_MS (15 minutes); the suite pins the two. */
    static final long WINDOW_MS = 15L * 60L * 1000L;

    /** The reason when the daemon gave no answer in time. Q047: the call rings rather than being rejected. */
    static final String FAIL_OPEN = "the daemon did not answer in time (fail-open, Q047)";

    /** The local signal, the first half of signal 4 of NowhereCallControlService.emergencyExemption. Null when no
     *  call was marked, or when the mark is WINDOW_MS old or older. */
    static String localReason(long markedAtMs, long nowMs) {
        if (markedAtMs <= 0) return null;
        long age = nowMs - markedAtMs;
        // A backwards clock makes age negative: that counts as inside the window, shown as 0, because the safe
        // direction here is "do not reject".
        if (age < WINDOW_MS) return "an emergency call left this phone " + (age < 0 ? 0 : age / 1000) + "s ago";
        return null;
    }

    /** The daemon signal from the EMERGENCY-RECENT reply. Null reply = no answer in time = FAIL_OPEN. "YES <n>" with n
     *  a non-negative integer is a hit. NO, DENIED, ERR ..., a bad number or any other text is a miss: the daemon
     *  answered, so this signal does not exempt. */
    static String daemonReason(String reply) {
        if (reply == null) return FAIL_OPEN;
        String r = reply.trim();
        if (!r.startsWith("YES ")) return null;
        String n = r.substring(4).trim();
        if (!n.matches("[0-9]{1,18}")) return null;
        return "an emergency call left this phone " + Long.parseLong(n) + "s ago (daemon)";
    }

    /** The local check first; a local hit returns WITHOUT calling ask (no round trip). Else the daemon's answer. */
    static String exemptReason(long markedAtMs, long nowMs, Supplier<String> ask) {
        String local = localReason(markedAtMs, nowMs);
        if (local != null) return local;
        return daemonReason(ask.get());
    }

    /** The log class of an EMERGENCY-MARK reply that did not record the mark, or null for OK. Only the class is
     *  logged, never the reply text. */
    static String markFailure(String reply) {
        String r = reply == null ? "" : reply.trim();
        if (r.equals("OK")) return null;
        if (r.isEmpty()) return "no-answer";
        if (r.equals("DENIED")) return "denied";
        if (r.equals("ERR clock")) return "clock";
        return "other";
    }
}
