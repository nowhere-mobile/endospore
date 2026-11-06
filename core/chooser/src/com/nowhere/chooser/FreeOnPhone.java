package com.nowhere.chooser;

/**
 * "Free on this phone" for a downloaded On-demand app (h51 #4 B2, NWP-20261125-11): the "What's using your space"
 * row frees the app now, as {@link ReArchiveReceiver}'s idle reclaim would later. The archive drops the APK and keeps
 * the app's data and its icon; a tap on the icon downloads it again. java.* only, lifted so a JDK can run it
 * (core/chooser/tests/free-on-phone).
 *
 * The decision says "never freeable: an app's parked data waiting for its install, and anything changed since the
 * last save". This reads the second as "its code is in the store": the #apps head carries its APK, so the tap that
 * brings it back has something to download. The app's data stays on the phone, as the archive keeps it.
 */
final class FreeOnPhone {
    private FreeOnPhone() {}

    // Draft words, for Chester to correct.
    static final String LINK = "Free on this phone";
    static final String DONE = "Freeing it — it downloads again when you tap it.";
    static final String KEPT = "Not freed: this app is doing a job that needs it on the phone (keyboard, VPN, or "
            + "another always-on role).";
    static final String UNREAD = "Not freed: couldn't check whether this app is in use right now.";
    static final String FAILED = "Not freed: the phone didn't accept the request. Try again.";

    /** True when the row offers the link: an On-demand app that is installed now (not a placeholder or a parked
     *  hold), not bundled, whose code the measured #apps head carries, and not a Play stack member (the row's
     *  `actionable` rule keeps those off-limits for the same reason). */
    static boolean offer(String mode, boolean installedNow, boolean bundled, boolean appsMeasured, boolean code,
                         boolean playStack) {
        return "ondemand".equals(mode) && installedNow && !bundled && appsMeasured && code && !playStack;
    }

    /** The sweep's own guards for a free now: "unread" when a job source could not be read (failedSource names
     *  it), "job" when the app holds a job, else "ok". Only "ok" archives. */
    static String verdict(String failedSource, boolean holdsJob) {
        if (failedSource != null) return "unread";
        return holdsJob ? "job" : "ok";
    }

    /** The Toast text for a verdict that did not free the app. */
    static String message(String verdict) {
        if ("job".equals(verdict)) return KEPT;
        if ("unread".equals(verdict)) return UNREAD;
        return FAILED;
    }
}
