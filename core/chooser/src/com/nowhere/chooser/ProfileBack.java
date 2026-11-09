package com.nowhere.chooser;

/**
 * NWP-20261128-10: what Back (the button or the swipe) does in ProfileActivity (java.lang only, so it runs under javac).
 *
 * <p>The row "The Profile app closes on Back from any screen ...": Profile swaps its screens in place, and Back used
 * to leave the app from every one of them. Each sub-screen's on-screen Back link already names its real parent, so
 * ProfileActivity records that link's target when it shows the screen, and Back runs it. A screen with no Back link
 * goes to Profile home; only Profile home leaves the app. Once a sign-out has started, Back is swallowed.
 */
final class ProfileBack {
    private ProfileBack() {}

    enum Act { SWALLOW, TARGET, HOME, LEAVE }

    static Act decide(boolean loggingOff, boolean atHome, boolean hasTarget) {
        if (loggingOff) return Act.SWALLOW;
        if (atHome) return Act.LEAVE;
        if (hasTarget) return Act.TARGET;
        return Act.HOME;
    }

    /** Whether the API 33+ OnBackInvokedCallback is registered. On Profile home with no sign-out it is not, so the
     *  platform plays its own back-to-home animation with its peek and leaves the app. */
    static boolean wantCallback(boolean loggingOff, boolean atHome) {
        return loggingOff || !atHome;
    }
}
