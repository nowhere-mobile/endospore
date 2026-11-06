package com.nowhere.chooser;

/**
 * NWP-20261124-09: the Google Play question on the gate's create form. docs/product-decisions.md, 2026-10-26 ("on
 * Endospore, creating a profile asks one question, "Use Google Play apps on this profile?", off by default ...") and
 * 2026-11-01 ("twenty-two answers to harvests 50, 51 and 52 ...", h50 #7: "on" at Create or in Profile › Apps marks
 * Play kept On-demand). Pure java.lang, so test-play-at-create-java.sh compiles it as-is.
 *
 * The gate (user 0) shows the question only on the create form and only where the GrapheneOS App Store is installed,
 * so Diaspore never shows it. An answer of on is sent to the new session before switch-in (PlayAtCreateReceiver),
 * which writes play.wanted=1 there. Off writes nothing: the new profile starts in today's absent state, which
 * PlayChoice treats as no choice made, and the Profile › Apps row stays the one place to choose later.
 *
 * The decision also hides the question when a signed setup configuration fixes the choice. No such field exists, so
 * that half waits for it.
 */
final class PlayAtCreate {

    /** The decided words, verbatim. */
    static final String QUESTION = "Use Google Play apps on this profile? Some apps (banking, maps, messaging) need it. "
            + "It downloads about 130 MB the first time.";

    /** The broadcast extra that carries the answer to the new session. */
    static final String EXTRA = "nowhere.playatcreate";

    private PlayAtCreate() {}

    /** The question is on the form only in create mode, and only with the GrapheneOS App Store installed. */
    static boolean offered(boolean gosStorePresent, boolean createMode) {
        return gosStorePresent && createMode;
    }

    /** The value the gate sends for an answer: "1" (PlayChoice's raw ON) for on, null (send nothing) for off. */
    static String value(boolean on) {
        return on ? "1" : null;
    }

    /** The session writes the flag only for exactly "1"; anything else is ignored. */
    static boolean accepts(String extra) {
        return "1".equals(extra);
    }
}
