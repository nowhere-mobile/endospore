package com.nowhere.chooser;

/** Cases for Fido2KeyList.parse, the LIST-FIDO2 reply parse (NWP-20261114-29), and Fido2KeyList.removeText, the text for
 *  a REMOVE-FIDO2-KEY reply (NWP-20261116-29). NWP-20261119-11: also Fido2KeyList.enrollText (an ENROLL-FIDO2 reply)
 *  and Fido2KeyList.nfcFinishText (a failed NFC FINISH). Prints "--- FAIL: <name>" per failed case and exits 1. Every
 *  credential id here is synthetic, never a real one. */
public final class Fido2KeyListCases {
    private static int fails = 0;

    private static void pass(String name) { System.out.println("--- PASS: " + name); }
    private static void fail(String name, String got) { System.out.println("--- FAIL: " + name + " (" + got + ")"); fails++; }

    /** The reply is (wantNull) or is not an answer; when it is, the list holds {@code size} records. */
    private static java.util.List<String[]> answer(String name, String reply, boolean wantNull, int size) {
        java.util.List<String[]> got;
        try {
            got = Fido2KeyList.parse(reply);
        } catch (RuntimeException e) {
            fail(name, "parse threw " + e);
            return null;
        }
        if (wantNull) {
            if (got == null) pass(name); else fail(name, "want null, got a list of " + got.size());
        } else if (got == null) {
            fail(name, "want " + size + " record(s), got null");
        } else if (got.size() != size) {
            fail(name, "want " + size + " record(s), got " + got.size());
        } else {
            pass(name);
        }
        return got;
    }

    /** Record i of the list reads {credID, added, transport, label}. */
    private static void rec(String name, java.util.List<String[]> list, int i, String credID, String added,
                            String transport, String label) {
        if (list == null || list.size() <= i) { fail(name, "no record " + i + " (size " + (list == null ? "null" : list.size()) + ")"); return; }
        String[] r = list.get(i);
        String[] want = {credID, added, transport, label};
        if (java.util.Arrays.equals(r, want)) pass(name);
        else fail(name, "got " + java.util.Arrays.toString(r) + ", want " + java.util.Arrays.toString(want));
    }

    // The removeText texts, written out here so a changed text fails a case.
    private static final String RM = "Key removed";
    private static final String RM_PASS = "Key removed — passphrase only now";
    private static final String RM_SESSION = "This session has ended — sign in again to manage your keys.";
    private static final String RM_LOST = "The phone didn't answer, so the key may or may not have been removed. "
            + "The list below shows the keys that are still added.";
    private static final String RM_ERR = "Couldn't remove the key — try again";
    // NWP-20261127-02: the fresh-tap replies.
    private static final String RM_NOKEY = "Plug in one of your keys to remove a key.";
    private static final String RM_WRONGKEY = "That key can't confirm this. Use one of your other keys.";
    private static final String RM_NOTSTORED = "This profile isn't stored, so it has no security keys to remove.";

    /** removeText(reply) is exactly {@code want}. */
    private static void txt(String name, String reply, String want) {
        String got;
        try {
            got = Fido2KeyList.removeText(reply);
        } catch (RuntimeException e) {
            fail(name, "removeText threw " + e);
            return;
        }
        if (want.equals(got)) pass(name); else fail(name, "got \"" + got + "\", want \"" + want + "\"");
    }

    // The enrollText and nfcFinishText texts, written out here so a changed text fails a case.
    private static final String EN_STORE = "Save this profile to your store first, then add a key.";
    private static final String EN_BUSY = "The phone is busy saving. Nothing changed — try again in a minute.";
    private static final String EN_SESSION = "This session isn't signed in to a saved profile — sign in again to add a key.";
    private static final String EN_ERR = "Couldn't enroll — is the key plugged into the USB-C port? Try again.";
    private static final String EN_LOST =
            "The phone didn't answer, so the key may have been added. Check the list below before you sign out.";
    private static final String EN_AGAIN = "The second tap didn't complete — tap the button and enroll again from the start.";

    /** enrollText(reply) is exactly {@code want} (null for OK). */
    private static void enroll(String name, String reply, String want) {
        String got;
        try {
            got = Fido2KeyList.enrollText(reply);
        } catch (RuntimeException e) {
            fail(name, "enrollText threw " + e);
            return;
        }
        if (java.util.Objects.equals(want, got)) pass(name); else fail(name, "got \"" + got + "\", want \"" + want + "\"");
    }

    /** nfcFinishText(detail) is exactly {@code want}. */
    private static void finish(String name, String detail, String want) {
        String got;
        try {
            got = Fido2KeyList.nfcFinishText(detail);
        } catch (RuntimeException e) {
            fail(name, "nfcFinishText threw " + e);
            return;
        }
        if (java.util.Objects.equals(want, got)) pass(name); else fail(name, "got \"" + got + "\", want \"" + want + "\"");
    }

    /** text does not claim that the enrolment failed. */
    private static void noFailClaim(String name, String text) {
        if (text != null && !text.contains("Couldn't")) pass(name); else fail(name, "got \"" + text + "\"");
    }

    public static void main(String[] args) {
        String okId = "OKx9Zq3vT0bW2c8Lr5mN4pQyJ1sE7hUaXk6fGdVwBoI=";
        java.util.List<String[]> f1 = answer("F1 a key whose id begins OK is kept (2 records)",
                "OK 2\n" + okId + " 1700000000 usb\nQUJDRA== 1700000100 nfc\n", false, 2);
        rec("F1 the OK... id is record 0", f1, 0, okId, "1700000000", "usb", "");
        rec("F1 the second key is record 1", f1, 1, "QUJDRA==", "1700000100", "nfc", "");

        answer("F2 OK 0 is an empty list, not null", "OK 0\n", false, 0);

        answer("F3 NONE is an empty list", "NONE\n", false, 0);
        answer("F3 LOCAL is an empty list", "LOCAL\n", false, 0);

        answer("F4 ERR is not an answer", "ERR\n", true, 0);
        answer("F4 an empty reply is not an answer", "", true, 0);
        answer("F4 a null reply is not an answer", null, true, 0);

        java.util.List<String[]> f5 = answer("F5 a legacy record with no transport", "OK 1\nQUJDRA== 1700000000\n", false, 1);
        rec("F5 transport and label are empty", f5, 0, "QUJDRA==", "1700000000", "", "");

        java.util.List<String[]> f6 = answer("F6 a label with spaces", "OK 1\nQUJDRA== 1700000000 usb My blue work key\n", false, 1);
        rec("F6 the label is kept whole", f6, 0, "QUJDRA==", "1700000000", "usb", "My blue work key");

        java.util.List<String[]> f7 = answer("F7 a NONE record after the header is a record", "OK 1\nNONE x y\n", false, 1);
        rec("F7 the NONE record reads as a key", f7, 0, "NONE", "x", "y", "");

        answer("F8 a newline-only reply is not an answer", "\n", true, 0);
        answer("F8 a reply of blank lines is not an answer", "\n\n", true, 0);

        txt("R1 OK true is Key removed", "OK true", RM);
        txt("R1 OK true with a newline is Key removed", "OK true\n", RM);
        txt("R2 OK false is passphrase only", "OK false", RM_PASS);
        txt("R2 OK false with blanks around it is passphrase only", "  OK false \n", RM_PASS);
        txt("R2 OK and false split by a tab is passphrase only", "OK\tfalse", RM_PASS);
        txt("R3 a bare OK is Key removed", "OK", RM);
        txt("R4 OK falsey is Key removed (the second token must BE false)", "OK falsey", RM);
        txt("R4 OK true false is Key removed (only the second token counts)", "OK true false", RM);
        txt("R5 ERR-NOSESSION says the session ended", "ERR-NOSESSION", RM_SESSION);
        txt("R5 ERR-NOSESSION with a newline says the session ended", "ERR-NOSESSION\n", RM_SESSION);
        txt("R6 an empty reply says the phone did not answer", "", RM_LOST);
        txt("R6 a null reply says the phone did not answer", null, RM_LOST);
        txt("R6 a blank reply says the phone did not answer", "  ", RM_LOST);
        txt("R6 a newline-only reply says the phone did not answer", "\n", RM_LOST);
        txt("R7 ERR is the retry text", "ERR", RM_ERR);
        txt("R7 BUSY is the retry text", "BUSY", RM_ERR);
        txt("R7 an unknown ERR- code is the retry text", "ERR-SOMETHING", RM_ERR);
        txt("R8 OKAY is not OK", "OKAY", RM_ERR);
        txt("R8 OK-X is not OK", "OK-X", RM_ERR);
        txt("R8 ERRX is the retry text", "ERRX", RM_ERR);
        txt("R8 ERR-NOSESSIONX is not ERR-NOSESSION", "ERR-NOSESSIONX", RM_ERR);
        txt("R9 ERR-NOKEY asks for a plugged-in key", "ERR-NOKEY", RM_NOKEY);
        txt("R9 ERR-NOKEY with a newline asks for a plugged-in key", "ERR-NOKEY\n", RM_NOKEY);
        txt("R9 ERR-NOKEY extra still maps by its first token", "ERR-NOKEY extra", RM_NOKEY);
        txt("R10 ERR-WRONGKEY asks for another key", "ERR-WRONGKEY", RM_WRONGKEY);
        txt("R10 ERR-WRONGKEY with a newline asks for another key", "ERR-WRONGKEY\n", RM_WRONGKEY);
        txt("R11 ERR-NOTSTORED says the profile is not stored", "ERR-NOTSTORED", RM_NOTSTORED);
        txt("R12 ERR-NOKEYX is not ERR-NOKEY", "ERR-NOKEYX", RM_ERR);
        txt("R12 ERR-WRONGKEYX is not ERR-WRONGKEY", "ERR-WRONGKEYX", RM_ERR);

        enroll("E1 OK is the success screen (null)", "OK", null);
        enroll("E1 OK with a newline is the success screen (null)", "OK\n", null);
        enroll("E2 ERR-NOTSTORED says save the profile first", "ERR-NOTSTORED", EN_STORE);
        enroll("E3 BUSY says the phone is busy", "BUSY", EN_BUSY);
        enroll("E4 ERR-NOSESSION says the session is not signed in", "ERR-NOSESSION", EN_SESSION);
        enroll("E5 ERR is the retry text", "ERR", EN_ERR);
        enroll("E5 ERR with a trailing blank is the retry text", "ERR ", EN_ERR);
        enroll("E5 an unknown ERR- code is the retry text", "ERR-WHATEVER", EN_ERR);
        enroll("E6 an empty reply says the key may have been added", "", EN_LOST);
        enroll("E6 a null reply says the key may have been added", null, EN_LOST);
        enroll("E6 a blank reply says the key may have been added", "  \n", EN_LOST);
        enroll("E7 OKAY is not OK", "OKAY", EN_ERR);
        enroll("E7 ERR-NOTSTORED-X is not ERR-NOTSTORED", "ERR-NOTSTORED-X", EN_ERR);
        enroll("E7 BUSYX is not BUSY", "BUSYX", EN_ERR);
        noFailClaim("E8 an empty reply does not say Couldn't", Fido2KeyList.enrollText(""));
        noFailClaim("E8 a null reply does not say Couldn't", Fido2KeyList.enrollText(null));
        if (Fido2KeyList.ENROLL_MAY_HAVE_ADDED.equals(Fido2KeyList.enrollText(""))) pass("E9 enrollText(\"\") is ENROLL_MAY_HAVE_ADDED");
        else fail("E9 enrollText(\"\") is ENROLL_MAY_HAVE_ADDED", "the caller would not re-render the list");

        finish("N1 BUSY says the phone is busy", "BUSY", EN_BUSY);
        finish("N2 nfc-io says the key may have been added", "nfc-io", EN_LOST);
        finish("N3 closed says the key may have been added", "closed", EN_LOST);
        finish("N4 nfc-link-lost means start again", "nfc-link-lost", EN_AGAIN);
        finish("N5 an ERR line means start again", "ERR", EN_AGAIN);
        finish("N5 ERR-NOTSTORED means start again", "ERR-NOTSTORED", EN_AGAIN);
        finish("N6 an unknown detail means start again", "not-fido", EN_AGAIN);
        finish("N6 closedX is not closed", "closedX", EN_AGAIN);
        if (Fido2KeyList.ENROLL_MAY_HAVE_ADDED.equals(Fido2KeyList.nfcFinishText("closed"))) pass("N7 nfcFinishText(\"closed\") is ENROLL_MAY_HAVE_ADDED");
        else fail("N7 nfcFinishText(\"closed\") is ENROLL_MAY_HAVE_ADDED", "the caller would not re-render the list");

        System.exit(fails == 0 ? 0 : 1);
    }
}
