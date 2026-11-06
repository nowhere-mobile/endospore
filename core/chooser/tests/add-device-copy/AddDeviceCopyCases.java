package com.nowhere.chooser;

/** Cases for AddDeviceCopy (NWP-20261116-28). Expected texts are literals here, independent of AddDeviceCopy.
 *  "probe <code>..." prints "<code>\t<1 when failText(code) equals failText(ERR)>" for the suite's cross-side check. */
public final class AddDeviceCopyCases {
    private static int fails = 0;

    private static void eq(String name, Object got, Object want) {
        if (want.equals(got)) { System.out.println("  ok    " + name); return; }
        fails++;
        System.out.println("  FAIL  " + name + "\n    got:  " + got + "\n    want: " + want);
    }

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("probe")) {
            String dflt = AddDeviceCopy.failText("ERR");
            for (int i = 1; i < args.length; i++) {
                System.out.println(args[i] + "\t" + (AddDeviceCopy.failText(args[i]).equals(dflt) ? 1 : 0));
            }
            return;
        }
        String dflt = "couldn't reach the store — check your connection and try again";
        String badpass = "that recovery code is right, but that is not this profile's passphrase";
        String badphrase = "that is not a valid 12-word recovery code — check for a typo";
        String noprofile = "couldn't find that profile — check the name and the recovery code";
        String badsecret = "this phone's secure chip didn't answer — try again";
        String nostore = "this phone has no store set up yet";
        String blank = "fill in all three fields";
        String none = "the phone didn't answer, so this phone may or may not have been added — tap Add again (adding a "
                + "phone twice is safe), then sign in with your passphrase";

        String[][] texts = {
            {"ERR-BADPASS", badpass}, {"ERR-BADPHRASE", badphrase}, {"ERR-NOPROFILE", noprofile},
            {"ERR-BADSECRET", badsecret}, {"NOSTORE", nostore}, {"BLANK", blank}, {"", none}, {"ERR", dflt},
            {"ERR-WHATEVER", dflt},
        };
        for (String[] t : texts) eq("failText(\"" + t[0] + "\")", AddDeviceCopy.failText(t[0]), t[1]);
        eq("failText(null) is the no-answer text", AddDeviceCopy.failText(null), none);
        for (String trap : new String[] {"ERR-BADP", "ERR-BADPASSX", "NOSTOREX", "BLANKS"}) {
            eq("prefix trap \"" + trap + "\" -> default", AddDeviceCopy.failText(trap), dflt);
        }

        String got = AddDeviceCopy.failText("");
        eq("the no-answer text says to tap Add again", got.contains("Add again"), true);
        eq("the no-answer text never says to sign in first", got.contains("sign in with your passphrase first"), false);
        eq("the no-answer text puts Add again before sign in",
                got.indexOf("Add again") >= 0 && got.indexOf("Add again") < got.indexOf("sign in"), true);

        eq("added(\"OK\")", AddDeviceCopy.added("OK"), true);
        eq("added(\" OK\\n\")", AddDeviceCopy.added(" OK\n"), true);
        for (String r : new String[] {null, "", "OKAY", "OK 1", "ERR", "BLANK", "NOSTORE"}) {
            eq("added(" + (r == null ? "null" : "\"" + r + "\"") + ") is false", AddDeviceCopy.added(r), false);
        }

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
