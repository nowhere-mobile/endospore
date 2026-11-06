package com.nowhere.chooser;

/**
 * NWP-20261103-09 (Q068) -- the reconnect prompt's words and what its tap's reply means. The prompt is posted
 * before anything checks whether the offline session's name has a stored profile, so it must not promise saved
 * data: it is conditional, and says no more than an online sign-in with the same words would show. The daemon
 * checks for a stored head at the tap (RELOGIN), then replies. No Android imports: core/chooser/tests/relogin-copy
 * compiles this file verbatim.
 */
final class ReloginCopy {
    private ReloginCopy() {}

    static final String RECONNECT_BODY =
            "If this name has saved data, tap \"Load my saved data\" to load it. If it does, anything you did in "
            + "this offline session is discarded; if it doesn't, nothing is lost and you stay in this session.";

    enum Verdict { LOADING, KEPT, RETRY }

    /** RELOGIN's reply -> what happens next. OK: the daemon queued the online sign-in and is logging the offline
     *  session off. NOSTORED: no stored head, the session is kept as a throwaway (the gate withdraws the prompt when
     *  GET-OFFLINE reads 0). Anything else -- ERR-STORE, NONE, BUSY, a timeout (null), "" -- RETRY: nothing was
     *  discarded and the prompt stays for another tap. Exact equality: an unknown reply must never read as loading. */
    static Verdict verdict(String reply) {
        if (reply == null) return Verdict.RETRY;
        String r = reply.trim();
        if (r.equals("OK")) return Verdict.LOADING;
        if (r.equals("NOSTORED")) return Verdict.KEPT;
        return Verdict.RETRY;
    }
}
