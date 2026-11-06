// Cases for PinCopy (NWP-20261124-10). Run by run.sh; prints "FAIL <case>" per failure and exits 1.
// The strings are written with backslash-u escapes for the en and em dashes (ASCII in this file), so an encoding slip
// in PinCopy.java is caught.
public class PinCopyCases {
    static int fails = 0;

    static void eq(String name, String want, String got) {
        if (java.util.Objects.equals(want, got)) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + "\n  want: " + want + "\n  got:  " + got); fails++; }
    }

    static void is(String name, boolean want, boolean got) {
        if (want == got) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + ": want " + want + ", got " + got); fails++; }
    }

    public static void main(String[] a) {
        final String floor = "the PIN must be 4–16 digits";
        final String notStored = "save this profile to your store first";
        final String busy = "a save is running — try again in a minute. Nothing changed.";
        final String noSession = "this session isn't signed in to a saved profile";
        final String none = "The phone didn't answer, so the PIN may have changed. Open this screen again to see "
                + "whether a PIN is set.";
        final String setDflt = "couldn't save the PIN — try again";
        final String clearDflt = "couldn't remove the PIN — try again";

        eq("set: OK is null", null, PinCopy.setText("OK"));
        eq("set: OK is matched after a trim", null, PinCopy.setText(" OK\n"));
        eq("set: ERR-FLOOR names the floor", floor, PinCopy.setText("ERR-FLOOR"));
        eq("set: ERR-NOTSTORED", notStored, PinCopy.setText("ERR-NOTSTORED"));
        eq("set: BUSY says nothing changed", busy, PinCopy.setText("BUSY"));
        eq("set: BUSY is matched after a trim", busy, PinCopy.setText(" BUSY\n"));
        eq("set: ERR-NOSESSION", noSession, PinCopy.setText("ERR-NOSESSION"));
        eq("set: no answer (\"\") says to look again", none, PinCopy.setText(""));
        eq("set: no answer (null) says to look again", none, PinCopy.setText(null));
        is("set: no answer does not say it failed", false, PinCopy.setText("").contains("couldn't"));
        eq("set: ERR gets the default line", setDflt, PinCopy.setText("ERR"));
        eq("set: ERR-FLOOR-X is not ERR-FLOOR", setDflt, PinCopy.setText("ERR-FLOOR-X"));
        eq("set: OKAY is not OK", setDflt, PinCopy.setText("OKAY"));
        eq("set: BUSY-X is not BUSY", setDflt, PinCopy.setText("BUSY-X"));
        eq("set: an unknown code gets the default line", setDflt, PinCopy.setText("ERR-SOMETHING-NEW"));

        eq("clear: OK is null", null, PinCopy.clearText("OK"));
        eq("clear: ERR-FLOOR gets the default line (a clear sends no PIN)", clearDflt, PinCopy.clearText("ERR-FLOOR"));
        eq("clear: ERR-NOTSTORED", notStored, PinCopy.clearText("ERR-NOTSTORED"));
        eq("clear: BUSY says nothing changed", busy, PinCopy.clearText("BUSY"));
        eq("clear: ERR-NOSESSION", noSession, PinCopy.clearText("ERR-NOSESSION"));
        eq("clear: no answer (\"\") says to look again", none, PinCopy.clearText(""));
        eq("clear: no answer (null) says to look again", none, PinCopy.clearText(null));
        eq("clear: ERR gets the default line", clearDflt, PinCopy.clearText("ERR"));
        eq("clear: OKAY is not OK", clearDflt, PinCopy.clearText("OKAY"));
        if (fails > 0) System.exit(1);
    }
}
