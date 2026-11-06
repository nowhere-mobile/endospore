package com.nowhere.chooser;

/** Cases for RecoverCopy (NWP-20261115-10; ERR-MOVED, NWP-20261116-06). Expected texts are literals here, independent of RecoverCopy.
 *  "probe <code>..." prints "<code>\t<1 when failText(code) equals failText(BLANK)>" for the suite's cross-side check. */
public final class RecoverReplyCases {
    private static int fails = 0;

    private static void eq(String name, Object got, Object want) {
        if (want.equals(got)) { System.out.println("  ok    " + name); return; }
        fails++;
        System.out.println("  FAIL  " + name + "\n    got:  " + got + "\n    want: " + want);
    }

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("probe")) {
            String dflt = RecoverCopy.failText("BLANK");
            for (int i = 1; i < args.length; i++) {
                System.out.println(args[i] + "\t" + (RecoverCopy.failText(args[i]).equals(dflt) ? 1 : 0));
            }
            return;
        }
        String blind = "couldn't reset — check the name and recovery code";
        String store = "Your recovery code was accepted, but the phone couldn't reach your storage. Try again.";
        String none = "the phone didn't answer, so the reset may or may not have gone through — try signing in with "
                + "your new passphrase first";
        String weakBare = "Choose a stronger passphrase. Nothing was reset.";
        String moved = "Your recovery code was accepted, but this profile was just saved from another phone. Try again.";

        eq("failText(\"ERR-STORE\")", RecoverCopy.failText("ERR-STORE"), store);
        eq("failText(\"ERR-MOVED\")", RecoverCopy.failText("ERR-MOVED"), moved);
        eq("failText(\"\") is the no-answer text", RecoverCopy.failText(""), none);
        eq("failText(null) is the no-answer text", RecoverCopy.failText(null), none);
        eq("failText(\"BLANK\") is the blind text", RecoverCopy.failText("BLANK"), blind);
        // The reason below is a case input, not a pin of passphraseStrong's wording.
        eq("failText(\"WEAK <reason>\")", RecoverCopy.failText("WEAK the reason here"),
                "Choose a stronger passphrase — the reason here. Nothing was reset.");
        eq("failText(\"WEAK\")", RecoverCopy.failText("WEAK"), weakBare);
        eq("failText(\"WEAK \") has no reason", RecoverCopy.failText("WEAK "), weakBare);
        for (String trap : new String[] {"ERR-STOR", "ERR-STORE2", "ERR-MOVE", "ERR-MOVED2", "WEAKER"}) {
            eq("prefix trap \"" + trap + "\" -> blind text", RecoverCopy.failText(trap), blind);
        }

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
