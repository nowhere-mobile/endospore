package com.nowhere.chooser;

/** NWP-20261119-14 (Q042; the words DECIDED 2026-10-31, h49 #1, docs/product-decisions.md "thirteen answers to
 *  harvest 49 ..."): the words of Your apps' "Install pending apps now" row. With the "Download over mobile data"
 *  switch off and no Wi-Fi the post-login sweep fetches no Auto app (AutoSweepNet.mayFetch), so the row says the apps
 *  wait for Wi-Fi and links to the one switch, in Offline media. In every other state the old line stays. With no
 *  network at all the sweep waits too, and the waiting line is still true, so no internet input. This class decides
 *  only which words to show; it reads no network. Pure (java.lang and PendingRow only):
 *  core/chooser/test-auto-pending-copy-java.sh runs it under plain javac. */
final class AutoPendingCopy {
    private AutoPendingCopy() {}

    static final String LINK = "Download over mobile data is off. Change it in Offline media ›";

    /** The sweep waits for Wi-Fi: the switch is off and the phone is not on Wi-Fi. */
    static boolean waitingForWifi(boolean allowMetered, boolean onWifi) {
        return !allowMetered && !onWifi;
    }

    /** The row's grey line for n pending Auto apps. */
    static String subline(int n, boolean allowMetered, boolean onWifi) {
        String who = n + (n == 1 ? " Auto app is" : " Auto apps are");
        if (waitingForWifi(allowMetered, onWifi)) return who + " waiting for Wi-Fi. Tap Install to use mobile data now.";
        return who + " waiting to install. They install in the background.";
    }

    /** The link to the switch under the grey line, or null when there is none to show. */
    static String link(boolean allowMetered, boolean onWifi) {
        return waitingForWifi(allowMetered, onWifi) ? LINK : null;
    }

    /** What applyPendingRow does to the row. countAction is PendingRow.action's answer for the count alone; shownTag
     *  is the tag installPendingRow set on the row on screen (Boolean: it said "waiting for Wi-Fi"), or null with no
     *  row. A recount with the same count leaves the row alone unless its words are now wrong, for example when Wi-Fi
     *  came or went: then the row is rebuilt. */
    static int rowAction(int countAction, Object shownTag, boolean allowMetered, boolean onWifi) {
        if (countAction != PendingRow.NONE || !(shownTag instanceof Boolean)) return countAction;
        return (Boolean) shownTag == waitingForWifi(allowMetered, onWifi) ? PendingRow.NONE : PendingRow.REPLACE;
    }
}
