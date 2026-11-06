package com.nowhere.chooser;

/** Cases for PromoteCopy (NWP-20261116-15). Expected kinds and texts are literals here, independent of PromoteCopy.
 *  "probe <reply>..." prints "<reply>\t<kind>\t<1 when the reply falls to the default>" for the suite's cross-side
 *  check: the default is CEREMONY with the text of a code PromoteCopy does not know. */
public final class PromoteCopyCases {
    private static int fails = 0;

    private static void eq(String name, Object got, Object want) {
        if (want == null ? got == null : want.equals(got)) { System.out.println("  ok    " + name); return; }
        fails++;
        System.out.println("  FAIL  " + name + "\n    got:  " + got + "\n    want: " + want);
    }

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("probe")) {
            String dflt = PromoteCopy.text("NOT-A-PROMOTE-CODE");
            for (int i = 1; i < args.length; i++) {
                PromoteCopy.Kind k = PromoteCopy.kind(args[i]);
                boolean isDefault = k == PromoteCopy.Kind.CEREMONY && PromoteCopy.text(args[i]).equals(dflt);
                System.out.println(args[i] + "\t" + k + "\t" + (isDefault ? 1 : 0));
            }
            return;
        }
        String dflt = "Couldn't save — try again";
        String rekey = "Couldn't update the session lock — nothing was saved. Try again.";
        String nostore = "Set up a store first (Settings → Store) to save this profile";
        String exists = "A profile with that name and passphrase already exists in your store. To save this session, "
                + "choose a different passphrase. To use that profile, sign in to it instead. If you just restored it "
                + "on the website, wait for the verify message.";
        String offline = "You signed in offline — your saved profile already exists. It loads when you reconnect.";
        String session = "Nothing was saved, and this phone's screen lock now takes the passphrase you just typed. "
                + "Use it to unlock.";
        String none = "The phone didn't answer, so this session may or may not have been saved. Tap Save again to "
                + "find out.";
        String weakWhy = "Choose a stronger passphrase — too short — use at least 12 characters";
        String weakBare = "Choose a stronger passphrase — too weak";
        String badName = "Names can't contain #.";

        Object[][] cases = {
            {"OK RECOVERY alpha bravo charlie", PromoteCopy.Kind.SAVED, ""},
            {"WEAK too short — use at least 12 characters", PromoteCopy.Kind.CEREMONY, weakWhy},
            {"WEAK", PromoteCopy.Kind.CEREMONY, weakBare},
            {"WEAK ", PromoteCopy.Kind.CEREMONY, weakBare},
            {"ERR-REKEY", PromoteCopy.Kind.CEREMONY, rekey},
            {"ERR-EXISTS", PromoteCopy.Kind.EXISTS, exists},
            {"ERR-ALREADY", PromoteCopy.Kind.ALREADY, ""},
            {"NOCREDIT", PromoteCopy.Kind.CREDIT, ""},
            {"NOSTORE", PromoteCopy.Kind.BACK, nostore},
            {"ERR-OFFLINE", PromoteCopy.Kind.BACK, offline},
            {"ERR-NAME", PromoteCopy.Kind.BACK, badName},
            {"ERR-SESSION", PromoteCopy.Kind.SPLIT, session},
            {"", PromoteCopy.Kind.CEREMONY, none},
            {"BUSY", PromoteCopy.Kind.CEREMONY, dflt},
            {"ERR-VAULT", PromoteCopy.Kind.CEREMONY, dflt},
            {"ERR-NOSESSION", PromoteCopy.Kind.CEREMONY, dflt},
            {"ERR-NOPASS", PromoteCopy.Kind.CEREMONY, dflt},
            {"ERR-SOMETHING-NEW", PromoteCopy.Kind.CEREMONY, dflt},
        };
        for (Object[] c : cases) {
            String r = (String) c[0];
            eq("kind(\"" + r + "\")", PromoteCopy.kind(r), c[1]);
            eq("text(\"" + r + "\")", PromoteCopy.text(r), c[2]);
        }
        eq("kind(null) reads as \"\"", PromoteCopy.kind(null), PromoteCopy.Kind.CEREMONY);
        eq("text(null) reads as \"\"", PromoteCopy.text(null), none);

        // Prefix traps: equality for every code; only "OK RECOVERY <words>" and "WEAK"/"WEAK <reason>" by prefix.
        for (String trap : new String[] {"ERR-SESSIONX", "ERR-EXIST", "ERR-EXISTSX", "ERR-ALREADYX", "NOSTOREX",
                "NOCREDITX", "ERR-OFFLINEX", "ERR-NAMEX", "ERR-REKEYX", "WEAKER", "OK RECOVERY", "OK RECOVERY   ", "OK"}) {
            eq("prefix trap \"" + trap + "\" -> CEREMONY", PromoteCopy.kind(trap), PromoteCopy.Kind.CEREMONY);
            eq("prefix trap \"" + trap + "\" -> default text", PromoteCopy.text(trap), dflt);
        }

        eq("recovery(words)", PromoteCopy.recovery("OK RECOVERY alpha bravo charlie"), "alpha bravo charlie");
        eq("recovery(trimmed)", PromoteCopy.recovery("OK RECOVERY   a b  "), "a b");
        eq("recovery(ERR-VAULT)", PromoteCopy.recovery("ERR-VAULT"), null);
        eq("recovery(\"\")", PromoteCopy.recovery(""), null);
        eq("recovery(null)", PromoteCopy.recovery(null), null);
        eq("recovery(no words)", PromoteCopy.recovery("OK RECOVERY"), null);
        eq("recovery(blank words)", PromoteCopy.recovery("OK RECOVERY   "), null);

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
