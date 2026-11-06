// Cases for TieCopy (NWP-20261112-02, NWP-20261119-23). Run by run.sh; prints "FAIL <case>" per failure and exits 1.
// The strings are written with backslash-u escapes for the bullet and the em dash (ASCII in this file), so an
// encoding slip in TieCopy.java is caught.
public class TieCopyCases {
    static int fails = 0;

    static void eq(String name, String want, String got) {
        if (want.equals(got)) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + "\n  want: " + want + "\n  got:  " + got); fails++; }
    }

    static void is(String name, boolean want, boolean got) {
        if (want == got) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + ": want " + want + ", got " + got); fails++; }
    }

    public static void main(String[] a) {
        eq("the fourth cost point is the decision's, byte for byte",
                "\u2022 If this phone is reset, lost or broken, your 12-word recovery code is the only way back in. "
                + "Without it, no one can open this profile again, including us.",
                TieCopy.COST_RESET);
        eq("the confirmation is the decision's, byte for byte",
                "I have my 12-word recovery code written down",
                TieCopy.CONFIRM);
        is("a tie is not sent unconfirmed", false, TieCopy.maySend("SE-TIE", false));
        is("a tie is sent once confirmed", true, TieCopy.maySend("SE-TIE", true));
        is("an untie never asks", true, TieCopy.maySend("SE-UNTIE", false));
        is("no verb is not a tie", true, TieCopy.maySend(null, false));

        // NWP-20261119-23: failText names every reply runTieVerb renders, on the whole trimmed reply.
        final String pass = "that isn't this profile's passphrase";
        final String dflt = "Couldn't change it \u2014 showing where it stands";
        final String none = "The phone didn't answer in time, so this may still finish. Showing where it stands now "
                + "\u2014 open this screen again in a few minutes.";
        eq("ERR-PASS keeps its line", pass, TieCopy.failText("ERR-PASS"));
        eq("ERR-PASS is matched after a trim", pass, TieCopy.failText(" ERR-PASS\n"));
        eq("ERR-WORKER-BUSY keeps its line", "your profile is being saved \u2014 try again in a minute",
                TieCopy.failText("ERR-WORKER-BUSY"));
        eq("ERR-NOCREDIT keeps its line",
                "your storage plan doesn't have room to save your data again under the chip, so nothing changed",
                TieCopy.failText("ERR-NOCREDIT"));
        eq("BUSY says the profile is busy and nothing changed",
                "your profile is busy saving \u2014 try again in a minute. Nothing changed.",
                TieCopy.failText("BUSY"));
        eq("no answer (\"\") says it may still finish", none, TieCopy.failText(""));
        eq("no answer (null) says it may still finish", none, TieCopy.failText(null));
        is("no answer (\"\") does not say it failed", false, TieCopy.failText("").contains("Couldn't"));
        is("no answer (null) does not say it failed", false, TieCopy.failText(null).contains("Couldn't"));
        eq("ERR gets the default line", dflt, TieCopy.failText("ERR"));
        eq("ERR-PASSWORD is not ERR-PASS: the default line", dflt, TieCopy.failText("ERR-PASSWORD"));
        eq("an unknown code gets the default line", dflt, TieCopy.failText("ERR-SOMETHING-NEW"));
        if (fails > 0) System.exit(1);
    }
}
