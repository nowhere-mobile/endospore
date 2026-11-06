package com.nowhere.chooser;

/**
 * NWP-20261119-15: a Play client whose profile has no Play stack keeps its placeholder and asks. Q055
 * (docs/product-decisions.md, 2026-10-20): Endospore only, the materialise reads the fetched APK's Play marker before it
 * installs, and with no stack it keeps the placeholder, with an "Install anyway". h49 #1 (2026-10-31) gives the words.
 * Device-proven 2026-08-27: a client whose nowhere-playdeps record was lost installed with no Play Store and no Play
 * services, opened to nothing, and nothing said where Play Store comes back from.
 *
 * Pure: no android.* import, so test-play-need-java.sh compiles it with its cases under javac. The dialog is
 * {@link PlayNeedAskActivity}; the call site is UnarchiveService.materializeLocked, between the APK list and
 * installApks.
 */
final class PlayNeed {
    private PlayNeed() {}

    /** The manifest meta-data key every Play-services client carries (ProfileActivity.usesPlayServices reads it too). */
    static final String MARKER = "com.google.android.gms.version";
    /** How long a tap waits for an answer. TIMEOUT counts as Not now. Same wait as PlayFetchAsk.WAIT_MS. */
    static final long WAIT_MS = 60000;

    static final String INSTALL_ANYWAY = "Install anyway";
    static final String NOT_NOW = "Not now";
    /** The <App> words when the archived label is not readable. A package name is not text for the user. */
    static final String FALLBACK_APP = "This app";

    enum Verdict { INSTALL, ASK, SKIP }

    /** INSTALL unless an Endospore profile is about to install a Play client with no Play Store present and none in
     *  the group it just installed. Then a tap asks, and the quiet Auto sweep keeps the placeholder without asking. */
    static Verdict decide(boolean endospore, boolean apkNeedsPlay, boolean stackPresent, boolean stackInGroup,
            boolean quiet) {
        if (!(endospore && apkNeedsPlay && !stackPresent && !stackInGroup)) return Verdict.INSTALL;
        return quiet ? Verdict.SKIP : Verdict.ASK;
    }

    /** h49 #1's title: "<App> needs Play Store". */
    static String title(CharSequence app) {
        return app(app, true) + " needs Play Store";
    }

    /** h49 #1's body, with <App> in both places. */
    static String body(CharSequence app) {
        String a = app(app, false);
        return "Play Store isn't on this profile, so " + a + " probably won't open. Install Play Store from the "
                + "GrapheneOS App Store, then tap " + a + " again. Some apps work without it.";
    }

    /** The label, or FALLBACK_APP (capitalised at the start of the title, lower case inside the body). */
    private static String app(CharSequence app, boolean start) {
        if (app != null && app.toString().trim().length() > 0) return app.toString();
        return start ? FALLBACK_APP : FALLBACK_APP.toLowerCase(java.util.Locale.ROOT);
    }
}
