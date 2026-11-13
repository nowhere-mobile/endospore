package com.nowhere.chooser;

/**
 * The gate's Help pages (NWP-20261122-05; decision 2026-11-02, docs/product-decisions.md, "Help at the gate covers the
 * gate and Owner settings only ..."). The gate's "?" (ChooserActivity.showGateHelp) opens the combo screen
 * (GateHelpScreen, NWP-20261130-11), and its tiles read these pages through GateHelpHome; Profile › Help reads HelpPages,
 * the session's own set. The gate covers only what is used at the gate: signing in, the gate's Settings, Owner settings,
 * and a locked phone.
 *
 * B4 (decision 2026-10-31, Part B, unchanged): a page says what a feature is and how to use it, never what it
 * protects; test-help-pages-java.sh refuses the words that would make one. Every step names its control by the label
 * the code shows today, and the comment beside it names where that label is.
 *
 * B5: English first, plain text, one step per paragraph. Pure: java.lang only, so javac runs it off the build host.
 */
final class GateHelpPages {
    private GateHelpPages() {}

    static final String[] TITLES = {
        "Signing in and creating a profile",
        "Gate settings",
        "Owner settings",
        "When the phone is locked",
    };

    // One String per step; a step holds no line break. body() puts a blank line between steps.
    private static final String[][] STEPS = {
        { // page 0: Signing in and creating a profile
            // ChooserActivity: field("profile"), field("passphrase"), btn.setText("Unlock")
            "Enter your profile name and passphrase, then tap Unlock.",
            // ChooserActivity.setCreateMode: "New here?  Create a profile", confirmField, "Create profile"
            "New here? Tap Create a profile, enter a name and your passphrase twice, then tap Create profile.",
            // core/agent/main.go handleRoamIn: the throwaway branch (decision Q071, 2026-10-20);
            // ProfileActivity: accentButton("Save to your store", ...)
            "A wrong passphrase or an unknown name opens an empty session, with no error. Nothing in it is saved "
                    + "unless you tap Save to your store in Profile.",
            // the security-key steps of the old gate sheet; ChooserActivity.armGateNfc (an NFC key at the gate)
            "Security key: plug a USB-C key in and touch it when it blinks, or hold an NFC key to the back of the "
                    + "phone.",
            // ChooserActivity: forgotLink "Forgot your passphrase?", buildRecoverScreen field("12-word recovery code")
            "Forgot your passphrase? Use the link below the Unlock button to recover with your 12-word recovery code.",
            // ChooserActivity.emergencyLink: "Emergency call"
            "Emergency call, below the sign-in form, opens the emergency dialer.",
        },
        { // page 1: Gate settings
            // ChooserActivity: gear (content description "Settings"); buildSettingsScreen: settingsRow("Wi-Fi",
            // "Join a network")
            "The gear at the top right opens Settings. Wi-Fi: join a network.",
            // GateAirplane.ROW "Airplane mode", GateAirplane.SUB
            "Airplane mode: a sign-in with it on is an offline session.",
            // buildSettingsScreen: "Software update", "Check for updates", "Install update"; the "Update available"
            // line's link "what's new" (showOtaNotes)
            "Software update: tap Check for updates, then Install update. Tap what's new to read what is in it.",
            // OtaUpdate.settingsDetail: "Required, install by <date>. <reason>" / ", overdue since <date>"
            "A required update shows Required, install by and a date. After that date it shows overdue.",
            // ChooserActivity: lookGlyph (left of helpIcon "?"), toggleGateLook; GONE while the gate's prefs hold
            // GateLookGlyph.OWNER_ONLY_KEY (buildGateLookScreen: GateLookCopy.OWNER_ONLY, NWP-20261124-15)
            "The sun or moon left of ? switches between light and dark, unless the owner has locked the look in Owner "
                    + "settings.",
            // buildOwnerMenu: settingsRow("Report a device issue", ...); ReportIntroCopy.GATE;
            // buildReportScreen: the `where` line
            "Owner settings › Report a device issue sends update, setup and system logs, never profile data, so "
                    + "report a problem inside a profile from Profile › Report an issue.",
        },
        { // page 2: Owner settings
            // ChooserActivity: ownerGlyph (content description "Owner settings"), buildOwnerVerifyScreen
            // field("device passphrase")
            "Owner settings is the shield at the bottom right of the sign-in screen. Enter your device passphrase to "
                    + "open it.",
            // buildOwnerMenu: settingsRow("Device passphrase", "Change the passphrase that opens Owner settings")
            "Device passphrase: change the passphrase that opens Owner settings.",
            // buildOwnerMenu: settingsRow("SIM lines", "Bind a SIM to the profile(s) it belongs to")
            "SIM lines: bind each SIM to the profile(s) that should receive its calls and messages.",
            // buildOwnerMenu: settingsRow("Messages & calls", ...); buildMessagesCallsMenu: "Inbox", "Compose",
            // "Lock screen notices"
            "Messages & calls: the Inbox and Compose for a SIM not assigned to a profile, and Lock screen notices.",
            // buildOwnerMenu: settingsRow("Lock screen clock", "Show a dim clock while the phone is resting");
            // buildOwnerMenu: settingsRow("Store settings", "Where your encrypted data is saved") -> buildStoreScreen;
            // buildOwnerMenu: settingsRow("Backup", "How often your data is saved") -> buildOwnerBackupScreen
            "Lock screen clock: show a dim clock while the phone is resting. Store settings: choose where profiles "
                    + "are saved. Backup: choose how often.",
            // buildOwnerMenu: settingsRow("System settings", "USB debugging, eSIM and more. ..."),
            // settingsRow("Leave Nowhere", "Go back to the stock Android this phone shipped with")
            "System settings: USB debugging, eSIM and more, for every profile. Leave Nowhere: go back to the stock "
                    + "Android this phone shipped with.",
        },
        { // page 3: When the phone is locked
            // ProfileActivity: accentButton("Lock — keep on this device", () -> doColdLock())
            "Profile › Lock — keep on this device: lock the phone and keep your session on it.",
            // ChooserActivity.enterResumeMode: "Welcome back, <name>", unlockBtn "Resume", "enter your PIN"
            "The sign-in screen then shows Welcome back and your profile name. Enter your passphrase, or your Session "
                    + "PIN if you set one, and tap Resume.",
            // ChooserActivity: resumeAlt "Not you?  Sign in as someone else" -> exitResumeMode
            "Not you? Sign in as someone else: go back to the normal sign-in screen.",
            // ChooserActivity.createOverColdLockText; ProfileActivity.showSecurity "Auto-wipe when left locked"
            "A locked session ends when another sign-in succeeds, when the phone restarts, or after the time set in "
                    + "Profile › Security › Auto-wipe when left locked. Anything it has not saved is lost.",
            // ProfileActivity: logoffLabel "Log off"; HelpPages page 3 has the same step. The "Lock or log off" tile opens
            // this page (NWP-20261130-11).
            "Profile › Log off: sign out. A saved profile saves to your store first.",
        },
    };

    /** Page i: its steps, a blank line between them. An index outside the four pages throws. */
    static String body(int i) {
        return String.join("\n\n", STEPS[i]);
    }

    /** The title of the gate's Help list: the same as Profile › Help's. */
    static String indexTitle() {
        return HelpPages.indexTitle();
    }

    /** The last paragraph of every page: the same line as Profile › Help's. */
    static String moreLine() {
        return HelpPages.moreLine();
    }
}
