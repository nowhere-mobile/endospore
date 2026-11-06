package com.nowhere.chooser;

/** NWP-20261128-05 (backlog row "An app installed by hand in a session comes up fresh: ..."): when the install heal
 *  (AppInstallReceiver.heal) sends RESTORE-ODDATA again. Its one send used to give up after 130 s, while a seal can hold
 *  the RW worker slot for 7-9 minutes, and nothing in the session retried it for an On-demand app.
 *
 *  Pure (java.lang only) so test-heal-retry-java.sh runs it under javac alone. The replies are the one-name forms of
 *  core/agent/app_code.go handleRestoreOdData / restoreOdOne. */
final class HealRetry {
    private HealRetry() {}

    /** The first send and six retries. */
    static final int MAX_TRIES = 7;
    /** The wait after the first try; it doubles per try: 60, 120, 240, 480, 960, 1920 s (about an hour in all). */
    static final long FIRST_DELAY_MS = 60_000L;

    /** delayMs: the wait before the next try, or -1 to stop. reply is the trimmed reply ("" when there was none);
     *  attempt is the number of tries already sent (1 after the first). */
    static long delayMs(String reply, int attempt) {
        String r = reply == null ? "" : reply.trim();
        if (attempt < 1 || attempt >= MAX_TRIES) return -1; // the bound: the first send and six retries
        if (r.startsWith("OK")) return -1; // OK <pkg>, OK NOSRC, OK LOCAL: the restore landed, or there is nothing to land
        if (r.equals("NONE")) return -1; // NONE: nobody is signed in, so there is no session to restore into
        if (is(r, "ERR-PKG")) return -1; // ERR-PKG: an invalid name gets the same answer every time
        if (r.isEmpty() // no reply: the 130 s round trip timed out, the socket failed or there is no daemon
                || is(r, "ERR-WORKER-BUSY") // the RW worker slot is held (a seal)
                || is(r, "ERR-TIMEOUT") // the worker op did not finish in time
                || is(r, "ERR-NOTREADY")) // roamd kept the hold: a packages.list line can lag a fresh install
            return FIRST_DELAY_MS << (attempt - 1);
        return -1; // a reply this policy does not name: stop, the safe direction
    }

    // is: the reply is the token, or the token and a reason after a space (so ERR-NOTREADYX is not ERR-NOTREADY).
    private static boolean is(String r, String token) { return r.equals(token) || r.startsWith(token + " "); }
}
