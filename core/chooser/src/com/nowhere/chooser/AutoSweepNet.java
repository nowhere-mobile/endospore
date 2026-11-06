package com.nowhere.chooser;

/** NWP-20261112-11 (Q042, DECIDED 2026-10-20, docs/product-decisions.md "sixteen recommendations accepted -- Play's
 *  download cache does not roam ..."): the network rule of the post-login Auto sweep. It follows the profile's
 *  "Download over mobile data" switch exactly as the media prefetch does (ChooserActivity's backup watcher), so the
 *  switch means one thing; "Install pending apps now" is a request by hand and runs on any network. A tap on one app
 *  never comes here. Pure (java.lang only): core/chooser/tests/auto-sweep-net runs it under plain javac. */
final class AutoSweepNet {
    private AutoSweepNet() {}

    /** The session's GET-PREFETCH-METERED reply: "1" (whitespace trimmed) is on; null, "", "0" or anything else is off. */
    static boolean meteredAllowed(String reply) {
        return reply != null && "1".equals(reply.trim());
    }

    /** May the sweep download now? By hand: always. Switch on: any internet. Switch off: Wi-Fi only. */
    static boolean mayFetch(boolean byHand, boolean allowMetered, boolean onWifi, boolean hasInternet) {
        if (byHand) return true;
        if (allowMetered) return hasInternet;
        return onWifi;
    }

    /** Should the gate start the sweep again? Only when one session's network rule turns from no to yes between two
     *  watcher ticks. A new or resumed session's first tick never does: its own login or resume kick ran the sweep. */
    static boolean rekick(int prevUid, boolean prevNet, int uid, boolean net) {
        return uid > 0 && uid == prevUid && !prevNet && net;
    }
}
