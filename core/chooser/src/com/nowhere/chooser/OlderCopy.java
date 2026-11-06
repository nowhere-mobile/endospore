package com.nowhere.chooser;

/** NWP-20261126-07 (h50 #3 of the 2026-11-01 entry "twenty-two answers to harvests 50, 51 and 52 ...",
 *  docs/product-decisions.md): "The sweep recognises this refusal and does not retry it." A head sealed before
 *  NWP-20261119-02 can carry APK bytes older than the archived placeholder's version (the app was updated from Play
 *  in a session), and PackageInstaller refuses that unarchive (frankel: `version code 26091819 inconsistent with
 *  26102651`). The quiet path of UnarchiveService.materializeLocked reads both versions before the install, and on
 *  an older copy it installs nothing and the sweep does not fetch the app again for the rest of the session. The skip
 *  is per process: UnarchiveService.OLDER_COPY lives in this roamed session's chooser process, in RAM only.
 *  NWP-20261128-20 (h50 #3, slice 2): playCount and endLine, the Auto sweep's end line "1 app needs Play Store to come
 *  back". java.lang and AppCodeManifest (pure java.*) only, so test-older-copy-java.sh compiles the two alone. */
final class OlderCopy {
    private OlderCopy() {}

    /** True exactly when both versions are known (> 0) and the fetched copy is older than the placeholder. An
     *  unknown version (<= 0: the reader could not read it) is false, so that app installs as before this change:
     *  the check only stops an install that cannot succeed, it never adds a refusal. One guard is enough, because
     *  0 < fetchedVc < placeholderVc implies placeholderVc > 0. */
    static boolean older(long fetchedVc, long placeholderVc) {
        return fetchedVc > 0 && fetchedVc < placeholderVc;
    }

    /** Play Store's package: the installer an app updated from Play records (AppCodeManifest.installer). */
    static final String PLAY = "com.android.vending";

    /** The end line's notification id, beside UnarchiveService.FG_ID (0x0A2D). Its own id, because the sweep's FG_ID
     *  notice is removed when the service stops (STOP_FOREGROUND_REMOVE): an inference, not stated by Chester. */
    static final int NOTICE_ID = 0x0A2E;

    /** NWP-20261128-20: how many of this sweep's older copies Play Store would bring back. 0 unless Play Store is on
     *  the profile (com.android.vending installed or archived for this user: an inference, not stated by Chester).
     *  Only a meta whose installer is Play counts; an unknown installer (null) never counts. */
    static int playCount(String[] metaTexts, boolean playOnProfile) {
        if (!playOnProfile || metaTexts == null) return 0;
        int n = 0;
        for (String t : metaTexts) if (PLAY.equals(AppCodeManifest.installer(t))) n++;
        return n;
    }

    /** NWP-20261128-20: the sweep's end line, null for n <= 0. The words are drafts for Chester to correct (h50 #3). */
    static String endLine(int n) {
        if (n <= 0) return null;
        if (n == 1) return "1 app needs Play Store to come back";
        return n + " apps need Play Store to come back";
    }
}
