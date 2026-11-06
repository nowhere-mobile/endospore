package com.nowhere.chooser;

/**
 * NWP-20261117-27: the drop, reconnect and landed cycle of the "back online -- Back up now" prompt.
 *
 * <p>The user-0 backup watcher (ChooserActivity.startSyncStatusWatcher) owns one instance on its own thread; the
 * class is not thread-safe. It decides when the prompt goes up and when it comes down, and holds no Android type,
 * so a javac suite (test-back-now-cycle-java.sh) runs it off the device.
 *
 * <p>Two causes made the notice wrong (lynx 2026-10-23). (1) The watcher cancelled the prompt whenever
 * GET-SYNC-STATUS was not STALE. That is the LAST seal's verdict, which predates the reconnect, so the prompt
 * went about 15 s after the reconnect while the offline changes were still unsaved. (2) That cancel also reset the
 * drop latch, so the "Backing up" a tap turned the prompt into (same notification id) had nothing to clear it.
 *
 * <p>The rule now: the prompt, and the "Backing up" it becomes, clear only once a seal announced at or after the
 * reconnect has landed OK. The daemon's GET-SEAL-LANDED answers {@code OK <unix seconds>}, that seal's announce
 * stamp; 0 means no seal landed OK since this session's sign-in, which never clears anything. A reply of any other
 * shape changes nothing, so the notice stays.
 *
 * <p>Residuals. The cycle lives in the watcher's memory: a chooser restart mid-cycle leaves the notice until the
 * next drop's cycle clears it, or the session ends. A tap whose seal and every later seal fail keeps "Backing up"
 * beside "Not backed up".
 */
final class BackNowCycle {
    static final int NOTHING = 0;
    static final int POST = 1;
    static final int CANCEL = 2;

    private boolean armed;      // a drop was announced and its cycle has not ended
    private boolean posted;     // the prompt was posted for this drop
    private long reconnectAt;   // unix seconds of the online tick that posted the prompt

    /** A drop was announced (the 3-tick debounce passed). Idempotent: called on every offline tick past it. */
    void onDrop() {
        armed = true;
        posted = false;
        reconnectAt = 0;
    }

    /** An online tick. POST once per drop, and remember when. */
    int onOnline(long nowSec) {
        if (!armed || posted) return NOTHING;
        posted = true;
        reconnectAt = nowSec;
        return POST;
    }

    /** True while a posted prompt waits for a seal from after the reconnect. */
    boolean awaitingLanded() {
        return armed && posted;
    }

    /** The last landed seal's announce stamp. CANCEL once, when it is at or after the reconnect; then disarm. */
    int onLanded(long landedSec) {
        if (!armed || !posted || landedSec <= 0 || landedSec < reconnectAt) return NOTHING;
        reset();
        return CANCEL;
    }

    /** A GET-SEAL-LANDED reply. One that is not {@code OK <digits>} is NOTHING and changes no state. */
    int onReply(String reply) {
        long v = landedStamp(reply);
        return v < 0 ? NOTHING : onLanded(v);
    }

    /** The stamp in {@code OK <digits>}, or -1 for any other reply (null, BUSY, a timeout's "", a sign, overflow). */
    static long landedStamp(String reply) {
        if (reply == null) return -1;
        String r = reply.trim();
        if (!r.startsWith("OK ")) return -1;
        String d = r.substring(3);
        if (d.isEmpty() || d.length() > 18) return -1;
        for (int i = 0; i < d.length(); i++) {
            char c = d.charAt(i);
            if (c < '0' || c > '9') return -1;
        }
        return Long.parseLong(d);
    }

    /** No live session: the cycle ends with it. */
    void reset() {
        armed = false;
        posted = false;
        reconnectAt = 0;
    }
}
