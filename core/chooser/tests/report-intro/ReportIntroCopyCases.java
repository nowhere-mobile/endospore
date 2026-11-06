package com.nowhere.chooser;

/** Cases for ReportIntroCopy (NWP-20261118-18). Expected texts are literals here, independent of ReportIntroCopy. */
public final class ReportIntroCopyCases {
    private static int fails = 0;

    private static void check(String name, boolean ok, String got) {
        if (ok) { System.out.println("  ok    " + name); return; }
        fails++;
        System.out.println("  FAIL  " + name + "\n    got:  " + got);
    }

    public static void main(String[] args) {
        String never = "Never send us your profile name or passphrase.";
        String profile = "This sends your device model, OS version, and a recent tail of app diagnostics so support "
                + "can look into a problem. It's anonymous — there's no account. Before anything is sent, passwords, "
                + "phone numbers, contacts, and anything that could identify you are removed from the diagnostics. "
                + "You can review exactly what's sent first. " + never;
        String gate = "Sends scrubbed device diagnostics (update, setup and system logs) anonymously to support. "
                + "Profile data and sign-in history are never included. Don't put personal details in the note. "
                + never;

        String n = ReportIntroCopy.NEVER_SEND, p = ReportIntroCopy.PROFILE, g = ReportIntroCopy.GATE;
        check("NEVER_SEND is /support's live sentence", never.equals(n), n);
        check("PROFILE ends with NEVER_SEND", p.endsWith(" " + never) && p.endsWith(" " + n), p);
        check("GATE ends with NEVER_SEND", g.endsWith(" " + never) && g.endsWith(" " + n), g);
        check("PROFILE does not list the passphrase as removed", !p.contains("passphrase,"), p);
        // Every sentence before NEVER_SEND: none names a passphrase. A PROFILE that does not end with NEVER_SEND fails
        // here too, never a silent pass.
        boolean ends = p.endsWith(" " + never);
        String head = ends ? p.substring(0, p.length() - never.length()) : p;
        check("no sentence of PROFILE before NEVER_SEND names a passphrase",
                ends && !head.toLowerCase(java.util.Locale.ROOT).contains("passphrase"), head);
        check("PROFILE still offers the review", p.contains("You can review exactly what's sent first."), p);
        check("GATE still excludes profile data", g.contains("Profile data and sign-in history are never included."), g);
        check("PROFILE is the whole expected text", profile.equals(p), p);
        check("GATE is the whole expected text", gate.equals(g), g);

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
