package com.nowhere.chooser;

/** Cases for RotateCopy (NWP-20261108-13). Expected texts are literals here, independent of RotateCopy.
 *  "probe <code>..." prints "<code>\t<1 when failText(code) equals failText(ERR)>" for the suite's cross-side check. */
public final class RotateCopyCases {
    private static int fails = 0;

    private static void eq(String name, Object got, Object want) {
        if (want.equals(got)) { System.out.println("  ok    " + name); return; }
        fails++;
        System.out.println("  FAIL  " + name + "\n    got:  " + got + "\n    want: " + want);
    }

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("probe")) {
            String dflt = RotateCopy.failText("ERR");
            for (int i = 1; i < args.length; i++) {
                System.out.println(args[i] + "\t" + (RotateCopy.failText(args[i]).equals(dflt) ? 1 : 0));
            }
            return;
        }
        String dflt = "couldn't change — something went wrong saving the new passphrase. Your passphrase has not changed.";
        String secret = "couldn't change — this phone's secure chip didn't answer for this session. Sign out and sign in "
                + "again, then try once more. Your passphrase has not changed.";
        String strand = "couldn't change — this would have locked this phone out of the profile. Your passphrase has not "
                + "changed.";
        String multi = "couldn't change — this profile is signed in on more than one phone, and a change here reaches only "
                + "this one. Change it there first. Your passphrase has not changed.";
        String rekey = "couldn't change — your screen lock could not follow the new passphrase, so nothing was changed. "
                + "Sign out and sign in again, then try once more.";
        String session = "your passphrase HAS changed, but this session didn't pick it up. Sign out and sign back in with "
                + "the new passphrase.";
        String store = "couldn't reach your storage — your passphrase has not changed. Check your connection and try again.";
        String none = "the phone didn't answer, so this may or may not have gone through. Sign out, then sign in with your "
                + "NEW passphrase — if that doesn't work, use the old one.";
        String blank = "that passphrase doesn't match this profile — your passphrase has not changed.";
        String busy = "couldn't change — a save is running right now. Try again in a minute. Your passphrase has not "
                + "changed.";
        String weakWhy = "Choose a stronger passphrase — too short — use at least 12 characters. Your passphrase has "
                + "not changed.";
        String weakBare = "Choose a stronger passphrase. Your passphrase has not changed.";

        String[][] texts = {
            {"ERR-SECRET", secret}, {"ERR-STRAND", strand}, {"ERR-MULTI", multi}, {"ERR-REKEY", rekey},
            {"ERR-SESSION", session}, {"ERR-STORE", store}, {"", none}, {"BLANK", blank}, {"ERR", dflt},
            {"BUSY", busy}, {"WEAK too short — use at least 12 characters", weakWhy}, {"WEAK", weakBare},
        };
        for (String[] t : texts) {
            eq("failText(\"" + t[0] + "\")", RotateCopy.failText(t[0]), t[1]);
            eq("failIsError(\"" + t[0] + "\")", RotateCopy.failIsError(t[0]), !t[0].equals("ERR-SESSION"));
        }
        eq("failText(null) is the no-answer text", RotateCopy.failText(null), RotateCopy.failText(""));
        eq("failIsError(null)", RotateCopy.failIsError(null), true);
        for (String trap : new String[] {"ERR-SE", "ERR-SESSIONX", "ERR-STOR", "WEAKER"}) {
            eq("prefix trap \"" + trap + "\" -> default", RotateCopy.failText(trap), dflt);
            eq("prefix trap \"" + trap + "\" is an error", RotateCopy.failIsError(trap), true);
        }

        eq("retired(OK 2)", RotateCopy.retired("OK 2"), 2);
        eq("retired(OK)", RotateCopy.retired("OK"), -1);
        eq("retired(OK -1)", RotateCopy.retired("OK -1"), -1);
        eq("retired(OK -3)", RotateCopy.retired("OK -3"), -1);
        eq("retired(OK x)", RotateCopy.retired("OK x"), -1);
        eq("retired(null)", RotateCopy.retired(null), -1);

        String base = "passphrase changed — use it next time you sign in";
        String tail = ": tap “Passphrase works on your other phone?”, then enter your new passphrase and your 12-word "
                + "recovery code.";
        eq("changed(0)", RotateCopy.changed(0), base);
        eq("changed(1)", RotateCopy.changed(1),
                base + ". Your other phone can't open this profile until you add it again there" + tail);
        eq("changed(3)", RotateCopy.changed(3),
                base + ". Your other phones can't open this profile until you add each of them again there" + tail);
        eq("changed(-1)", RotateCopy.changed(-1),
                base + ". If another phone is locked to its own secure chip, add it again there" + tail);

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
