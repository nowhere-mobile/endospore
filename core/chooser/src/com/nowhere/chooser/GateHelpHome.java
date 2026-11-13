package com.nowhere.chooser;

/**
 * The words and the mappings of the gate's Help combo screen (NWP-20261130-11; chosen by Chester on 2026-11-06, "Go with
 * combo", NWP-20261105-27). GateHelpScreen draws them. The tiles open the gate's own pages (GateHelpPages) and three
 * short pages here. A session topic's short page says where it is in Profile › Help, so the split of decision 2026-11-02
 * stays: GateHelpPages keeps its four pages, and Profile › Help keeps HelpPages.
 *
 * B4 (decision 2026-10-31, Part B): a line says what a feature is and how to use it, never what it protects;
 * test-gate-help-combo-java.sh refuses the words that would make one, so the hero's middle node reads "Your store" and
 * the picture carries the padlock. Every step names its control by the label the code shows today, and the comment
 * beside it names where that label is. Static text, the same for everyone, so blind login holds.
 *
 * Pure: java.lang only, so javac runs it off the build host.
 */
final class GateHelpHome {
    private GateHelpHome() {}

    /** The art kinds GateHelpArtView draws. */
    static final int ART_HERO = 0, ART_ANY_PHONE = 1, ART_SAVING = 2, ART_LOCK = 3;

    static final String HERO_TITLE = "How Nowhere works";
    static final String HERO_BODY = "Sign in on any phone and your profile comes down from your store.";
    // GateHelpArtView draws these under the hero's first three pictures; the fourth, the check, has no label.
    static final String[] HERO_NODES = { "This phone", "Your store", "Any phone" };
    static final String HERO_DESCRIPTION = "This phone saves your profile to your store, and any phone can bring it back.";
    static final String WATCH = "Watch the 3 steps";
    static final String WATCH_DESCRIPTION = "Watch the 3 steps. Opens the intro.";
    static final String TOPICS_HEADING = "Topics";
    static final String BACK = "Back";
    static final String BACK_DESCRIPTION = "Back to the sign-in screen";
    static final String NEXT = "Next";
    static final String DONE = "Done";
    static final String SKIP = "Skip";
    static final String SKIP_DESCRIPTION = "Skip the intro";

    // One row per step: the title, then its two lines.
    static final String[][] INTRO = {
        { "Your profile on any phone",
            // ChooserActivity: field("profile"), field("passphrase")
            "Sign in on any Nowhere phone with your name and passphrase.",
            "Your profile comes down from your store." },
        { "Saving",
            // HelpPages page 2: "Profile › Your data: your profile saves to your store automatically while you use it."
            "Your profile saves to your store while you use it.",
            // ProfileActivity.showBackup: menuScreen("Your data", ...), accentButton("Back up now", ...)
            "Back up now, in Profile › Your data, saves your latest changes." },
        { "Lock or log off",
            // ProfileActivity: accentButton("Lock — keep on this device", ...)
            "Lock keeps your session on this phone.",
            // ProfileActivity: logoffLabel "Log off"; HelpPages page 3
            "Log off signs you out. A saved profile saves to your store first." },
    };
    static final int[] INTRO_ART = { ART_ANY_PHONE, ART_SAVING, ART_LOCK };
    static final String[] INTRO_ART_DESCRIPTIONS = {
        "Your store in the middle, and your profile coming down to a phone on each side.",
        "A phone sending your profile to your store.",
        "One phone with a padlock, and one phone sending your profile to your store.",
    };

    static final String[] TILES = { "Signing in", "Your apps", "Saving", "Lock or log off", "Calls and SIMs", "Owner" };
    // Drawable names, in tile order. GateHelpTileGrid.ICONS holds the same ids; test-gate-help-combo-java.sh pins both.
    static final String[] TILE_ICONS = {
        "ic_help_signin", "ic_help_apps", "ic_help_saving", "ic_help_lock", "ic_help_calls", "ic_help_owner",
    };

    // A tile's GateHelpPages page, or -1 for a short page below.
    private static final int[] TILE_PAGE = { 0, -1, -1, 3, -1, 2 };
    // The GateHelpPages page a tile's dialog also opens, or -1. Gate settings has no tile of its own in the chosen six.
    private static final int[] TILE_ALSO = { 1, -1, -1, -1, -1, -1 };
    // A short page: one String per step, as GateHelpPages.
    private static final String[][] SHORT_PAGES = {
        null,
        {
            // ProfileActivity.showPreferences: "Your apps"; HelpPages.TITLES[1]
            "Your apps is in Profile › Preferences once you are signed in.",
            "Profile › Help › Your apps says how each mode works.",
        },
        {
            "Your profile saves to your store while you use it.",
            // ProfileActivity.showBackup: menuScreen("Your data", ...), accentButton("Back up now", ...)
            "Back up now and the other saving controls are in Profile › Your data once you are signed in.",
            // HelpPages.TITLES[2]
            "Profile › Help › Saving and storage says what each one does.",
        },
        null,
        {
            // ChooserActivity.buildOwnerMenu: settingsRow("SIM lines", ...), as GateHelpPages page 2
            "Owner settings › SIM lines: bind each SIM to the profile(s) that should receive its calls and messages.",
            // ChooserActivity.buildMessagesCallsMenu: "Inbox", "Compose", as GateHelpPages page 2
            "Owner settings › Messages & calls: the Inbox and Compose for a SIM not assigned to a profile.",
            // HelpPages.TITLES[4]
            "Once you are signed in, Profile › Help › Calls, texts and SIMs covers the session side.",
        },
        null,
    };

    static final String FORGOT_TITLE = "Forgot your passphrase?";
    static final String FORGOT_SUB = "Use your 12-word recovery code.";
    private static final String[] FORGOT_STEPS = {
        // ChooserActivity: forgotLink "Forgot your passphrase?", under btn.setText("Unlock")
        "Tap Forgot your passphrase? below the Unlock button.",
        // ChooserActivity.buildRecoverScreen: its first line
        "Enter your profile name and your 12-word recovery code, then choose a new passphrase.",
        // ChooserActivity.buildRecoveryScreen: "They are the ONLY way back into your profile ..."
        "The 12 words are the only way back into your profile if you forget your passphrase.",
        // ChooserActivity.buildRecoverScreen: "a reset does not lock out the old one"
        "If someone else may know your passphrase, sign in and change it instead. A reset does not lock out the old one.",
    };

    /** The primary button's label on intro step i. */
    static String nextLabel(int i) {
        return i == INTRO.length - 1 ? DONE : NEXT;
    }

    /** The primary button's TalkBack label on intro step i. */
    static String nextDescription(int i) {
        return i == INTRO.length - 1 ? "Done. Back to Help." : "Next step";
    }

    /** The step after i, or -1 after the last one. */
    static int introNext(int i) {
        return i + 1 < INTRO.length ? i + 1 : -1;
    }

    /** What TalkBack says for the dots. */
    static String dotsDescription(int i) {
        return "Step " + (i + 1) + " of " + INTRO.length;
    }

    /** What TalkBack says for tile i. */
    static String tileDescription(int i) {
        return TILES[i] + ". Opens help.";
    }

    /** The title of the page tile i opens. An index outside the six tiles throws. */
    static String tileTitle(int i) {
        return TILE_PAGE[i] >= 0 ? GateHelpPages.TITLES[TILE_PAGE[i]] : TILES[i];
    }

    /** The body of the page tile i opens, a blank line between steps. An index outside the six tiles throws. */
    static String tileBody(int i) {
        return TILE_PAGE[i] >= 0 ? GateHelpPages.body(TILE_PAGE[i]) : String.join("\n\n", SHORT_PAGES[i]);
    }

    /** The GateHelpPages page tile i's dialog also opens, or -1. */
    static int tileAlso(int i) {
        return TILE_ALSO[i];
    }

    /** The label of that dialog button, or null. */
    static String alsoLabel(int i) {
        return TILE_ALSO[i] < 0 ? null : GateHelpPages.TITLES[TILE_ALSO[i]];
    }

    /** What TalkBack says for the Forgot card. */
    static String forgotDescription() {
        return FORGOT_TITLE + " Opens help.";
    }

    /** The page the Forgot card opens. It holds no profile name and no secret. */
    static String forgotBody() {
        return String.join("\n\n", FORGOT_STEPS);
    }
}
