package com.nowhere.chooser;

/**
 * Profile › Help's pages (NWP-20261119-16; split by NWP-20261122-05 under the decision of 2026-11-02,
 * docs/product-decisions.md, "Help at the gate covers the gate and Owner settings only ..."). ProfileActivity.showHelp
 * reads this class; the gate's "?" reads GateHelpPages, its own set. These pages cover the session: the six decided
 * topics, in the decided order. "Getting started" is the gate's first page now, and the owner-mode steps of "Calls,
 * texts and SIMs" are on the gate's Owner settings page.
 *
 * B4: a page says what a feature is and how to use it, never what it protects. A body names no protection, so it stays
 * out of the scope of docs/privacy-claims.md; test-help-pages-java.sh refuses the words that would make one.
 * Every step names its control by the label on the screen and its path, as the code shows it today.
 *
 * Text first (B5): a page is plain text, one step per paragraph. Each step is the place where its picture will go
 * (B2, the illustrations, a later slice). Pure: java.lang only, so javac runs it off the build host.
 */
final class HelpPages {
    private HelpPages() {}

    static final String[] TITLES = {
        "Your profile on any phone",
        "Your apps",
        "Saving and storage",
        "Locking and signing out",
        "Calls, texts and SIMs",
        "Privacy controls",
    };

    // One String per step; a step holds no line break. body() puts a blank line between steps.
    private static final String[][] STEPS = {
        { // page 0: Your profile on any phone
            "Sign in on any Nowhere phone with your profile name and passphrase.",
            "The apps you keep come back with you. Choose them in Profile › Preferences › Your apps.",
            "Profile › Security › Use a security key: add a key that you touch when you sign in.",
            "Profile › Security › Tie to this phone: choose whether this phone's security chip is needed to open your "
                    + "profile.",
        },
        { // page 1: Your apps
            "Profile › Preferences › Your apps: tap the mode beside an app to choose how it comes back.",
            "Off — removed at logoff.",
            "On-demand — icon only, downloads when you tap it.",
            "Auto — downloads by itself after you sign in.",
            "Keep installed — ready to use the moment you sign in.",
            "Profile › Preferences › Configuration: choose what a newly installed app starts as.",
        },
        { // page 2: Saving and storage
            "Profile › Your data: your profile saves to your store automatically while you use it.",
            "Profile › Your data › Back up now: save your latest changes now.",
            "Profile › Your data › Export a copy: put your contacts, calendar, texts, calls, photos and files in your "
                    + "store as one copy.",
            "Profile › Your data › Restore a snapshot: go back to an earlier saved version.",
            "Profile › Storage › What's using space: see what takes room on this phone and in your plan.",
            "A throwaway profile is erased on log off or power off. Tap Save to your store in Profile to keep it.",
        },
        { // page 3: Locking and signing out
            "Profile › Lock — keep on this device: lock the phone and keep your session on it.",
            "Profile › Log off: sign out. A saved profile saves to your store first.",
            "Profile › Security › Auto standby when idle: choose how long the phone waits before it goes into standby.",
            "Profile › Security › Auto-wipe when left locked: choose how long a locked session stays before it is "
                    + "erased.",
            "Profile › Security › Session PIN: set a short PIN to unlock this phone.",
        },
        { // page 4: Calls, texts and SIMs -- the session side only
            "Calls and texts that arrive on a bound SIM while its profile is signed out appear in that profile when it "
                    + "next signs in.",
            // ChooserActivity.applyOwnerSimLock (the SIMs it does not own are hidden from it) and
            // blockOutboundTelephony (#158: a profile that owns no SIM)
            "While this profile is signed in, it calls and texts only on the SIMs bound to it in Owner settings › SIM "
                    + "lines. With none bound, it cannot call or text.",
            // ProfileActivity.showPreferences: the "Mobile data" row, MobileData.offered; showMobileData
            "Profile › Preferences › Mobile data: turn this phone's mobile data on or off while this profile is signed "
                    + "in. A throwaway or offline session does not show it.",
        },
        { // page 5: Privacy controls
            "Profile › Preferences › Location services: turn on Network location or Geocoding, only while this profile "
                    + "is signed in.",
            "Profile › Preferences › Hotspot & tethering: share this phone's connection while this profile is signed "
                    + "in.",
            "Profile › Security › Always-on VPN: pick a VPN app to keep on for the whole session.",
            "Profile › Report an issue › View what's sent: read a report before you tap Send report.",
        },
    };

    /** Page i: its steps, a blank line between them. An index outside the six pages throws. */
    static String body(int i) {
        return String.join("\n\n", STEPS[i]);
    }

    /** Page i's steps, a copy (NWP-20261122-08: Profile › Help's step cards read them). An index outside the pages
     *  throws. */
    static String[] steps(int i) {
        return STEPS[i].clone();
    }

    /** The title of the Help list, on the gate and in Profile. */
    static String indexTitle() {
        return "Help";
    }

    /** The last paragraph of every page. Plain text, not a link: the gate is Lock-Task'd and nothing leaves it. */
    static String moreLine() {
        return "More help is on the support pages at nowhere.mobile.";
    }
}
