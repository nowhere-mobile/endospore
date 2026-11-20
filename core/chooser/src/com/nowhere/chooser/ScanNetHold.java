package com.nowhere.chooser;

/** NWP-20261208-19: the rule behind "DECIDED: the Gallery's sign-in scan runs on any network by default, and becomes
 *  a setting" (docs/product-decisions.md, 2026-11-16). A per-profile switch on Offline media, off by default, holds
 *  the gate's landed-media rescan (the NWP-20261114-34 watcher -> requestMediaRescan -> CredentialService
 *  rescanmedia) until the active network is unmetered. That scan opens each indexed file, and through mediad's
 *  overlay that fetches chunks from the store. roamd's own sign-in rescan (nowhere_roamd.sh rescan_media) indexes
 *  local restored files only and carries no extra, so it always runs.
 *
 *  The switch is FILE in the session's chooser files dir, so it seals and roams with the profile. Only the session's
 *  CredentialService reads it, at each ask: the gate (user 0) cannot read it (MLS, NWP-20261005-08). So the session
 *  decides run / hold / skip, and the gate only remembers that it asked on a metered network and re-asks once when
 *  its own network is unmetered.
 *
 *  Residuals: a hold whose switch is then turned off meets SKIP at the re-ask, so the held scan first runs at the
 *  next landing or sign-in. The gate and the session judge metered-ness apart (a session VPN can differ): a re-ask
 *  the session still judges metered holds again and waits for the next landing, and a session hold the gate judged
 *  unmetered is never re-asked. A landing asked on an unmetered network after an earlier metered mark for the same
 *  session leaves the mark, so the next tick re-asks and the session scans once more (idempotent).
 *  java.lang only, so it runs under plain javac (core/chooser/test-scan-net-hold-java.sh). */
final class ScanNetHold {
    private ScanNetHold() {}

    /** In the session's chooser files dir: "1" = hold for an unmetered network; absent or anything else = any
     *  network (the default, today's behaviour). */
    static final String FILE = "nowhere-scan-unmetered";
    /** The gate's landing ask (requestMediaRescan). roamd's sign-in start does not carry it. */
    static final String EXTRA_LANDED = "rescanlanded";
    /** The gate's re-ask once its network is unmetered (retryHeldRescan). */
    static final String EXTRA_RETRY = "rescanretry";

    static final int RUN = 0, HOLD = 1, SKIP = 2;

    /** True only when the file's trimmed text is exactly "1". null (an unreadable file) is false: any network. */
    static boolean on(String fileText) {
        return fileText != null && fileText.trim().equals("1");
    }

    /** What the session does with one rescanmedia ask. */
    static int decide(boolean landed, boolean retry, boolean on, boolean unmetered) {
        if (!landed) return RUN;                          // roamd's sign-in start: never held
        if (!retry) return on && !unmetered ? HOLD : RUN; // the gate's landing ask
        if (!on) return SKIP;                             // the first ask already ran on any network
        return unmetered ? RUN : HOLD;
    }

    /** The gate re-asks only for the live session it asked on a metered network, and only on an unmetered one. */
    static boolean retryNow(int askedMeteredUid, int uid, boolean unmetered) {
        return uid > 0 && askedMeteredUid == uid && unmetered;
    }

    // DRAFT (NWP-20261208-19): Chester's mockup decides
    static final String LABEL = "Wait for Wi-Fi to list stored photos";
    // DRAFT (NWP-20261208-19): Chester's mockup decides
    static final String SUB = "Photos still in your storage show in the Gallery once you're on Wi-Fi. Listing them on mobile data downloads part of each one.";
}
