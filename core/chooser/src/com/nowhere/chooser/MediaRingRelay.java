package com.nowhere.chooser;

/**
 * The media ring poller's send decision (NWP-20261128-19), lifted out of ChooserActivity.startMediaRingPoller so javac
 * can run it. Backlog row: "An app's blue media ring stays on its home-screen icon with no media notice".
 * CAUSE: the launcher patch registers its MEDIA_PROGRESS receiver in Launcher.onResume and unregisters it in onPause,
 * and keeps the last map in the static BubbleTextView.sMediaProgress. The poller used to broadcast ONLY on a change,
 * so a clear ("" once the prefetch ended) sent while an app was in front reached no receiver and was never sent
 * again; back home, the launcher drew the stale ring from its static map. So the relay also re-sends an unchanged
 * value every RESEND_MS, the empty clear included. Pure: java.lang only.
 */
final class MediaRingRelay {
    /** An unchanged value is sent again this long after its last send: the worst stale ring after the user goes home. */
    static final long RESEND_MS = 10_000;

    private String last;      // null = nothing sent since reset
    private int lastUid = -1;
    private long lastSentMs;

    /** True when this value should be broadcast now: nothing sent yet, a new uid or value, or RESEND_MS since the last send. */
    boolean due(String prog, int uid, long nowMs) {
        String p = prog == null ? "" : prog;
        if (last == null || uid != lastUid || !p.equals(last)) return true;
        return nowMs - lastSentMs >= RESEND_MS;
    }

    /** Records a broadcast that did not throw; one that threw is not recorded, so the next tick tries again. */
    void sent(String prog, int uid, long nowMs) {
        last = prog == null ? "" : prog;
        lastUid = uid;
        lastSentMs = nowMs;
    }

    /** No session (uid < 0): forget the last send, so the next session's first value is due. */
    void reset() {
        last = null;
        lastUid = -1;
        lastSentMs = 0;
    }
}
