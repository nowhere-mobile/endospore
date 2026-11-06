// Cases for ExportCopy (NWP-20261101-02; the unread kinds NWP-20261112-24; the read cap and lost replies
// NWP-20261124-21). Run by run.sh; prints "FAIL <case>" per failure and exits 1.
public class ExportCopyCases {
    static int fails = 0;

    static void eq(String name, String want, String got) {
        if (want.equals(got)) System.out.println("  ok   " + name);
        else { System.out.println("FAIL " + name + "\n  want: " + want + "\n  got:  " + got); fails++; }
    }

    public static void main(String[] a) {
        eq("under-button text is the entry's, byte for byte",
                "A copy takes your contacts, calendar, text messages (not picture messages), calls, photos and files. "
                + "It doesn't take what's inside your apps, like 2FA codes, notes, bookmarks or loyalty cards.",
                ExportCopy.UNDER_BUTTON);
        eq("not-included clause is the entry's, byte for byte",
                "Not included: picture messages, and what's inside your apps (2FA codes, notes, bookmarks, loyalty cards).",
                ExportCopy.NOT_INCLUDED);
        eq("done line, nothing missing, no where line",
                "Exported 40 contacts, 3 events to your store. Not included: picture messages, and what's inside your apps "
                + "(2FA codes, notes, bookmarks, loyalty cards).",
                ExportCopy.doneText("40 contacts, 3 events", "", ""));
        eq("done line, null suffixes read as empty",
                ExportCopy.doneText("2 photos", "", ""), ExportCopy.doneText("2 photos", null, null));
        eq("done line with missing and where",
                "Exported 2 photos to your store. Not included: picture messages, and what's inside your apps "
                + "(2FA codes, notes, bookmarks, loyalty cards). Your photos & files didn't export — try again. WHERE",
                ExportCopy.doneText("2 photos", " Your photos & files didn't export — try again.", " WHERE"));
        // NWP-20261112-24: a kind whose read FAILED with its permission granted is named; none -> "".
        eq("unreadKinds, none", "", ExportCopy.unreadKinds(false, false, false, false));
        eq("unreadLine, none", "", ExportCopy.unreadLine(false, false, false, false));
        eq("unreadText, none", "", ExportCopy.unreadText(false, false, false, false));
        eq("unreadKinds, contacts", "contacts", ExportCopy.unreadKinds(true, false, false, false));
        eq("unreadKinds, calendar", "calendar", ExportCopy.unreadKinds(false, true, false, false));
        eq("unreadKinds, messages", "messages", ExportCopy.unreadKinds(false, false, true, false));
        eq("unreadKinds, calls", "calls", ExportCopy.unreadKinds(false, false, false, true));
        eq("unreadKinds, two", "contacts and calls", ExportCopy.unreadKinds(true, false, false, true));
        eq("unreadKinds, two in the fixed order", "calendar and messages", ExportCopy.unreadKinds(false, true, true, false));
        eq("unreadKinds, three", "contacts, messages and calls", ExportCopy.unreadKinds(true, false, true, true));
        eq("unreadKinds, four", "contacts, calendar, messages and calls", ExportCopy.unreadKinds(true, true, true, true));
        eq("unreadLine, contacts",
                " Your contacts couldn't be read, so they aren't in this copy — try again.",
                ExportCopy.unreadLine(true, false, false, false));
        eq("unreadLine, three",
                " Your contacts, messages and calls couldn't be read, so they aren't in this copy — try again.",
                ExportCopy.unreadLine(true, false, true, true));
        eq("done line when the contacts read failed",
                "Exported 12 events, 340 messages, 80 calls to your store. Not included: picture messages, and what's "
                + "inside your apps (2FA codes, notes, bookmarks, loyalty cards). Your contacts couldn't be read, so they "
                + "aren't in this copy — try again.",
                ExportCopy.doneText("12 events, 340 messages, 80 calls", ExportCopy.unreadLine(true, false, false, false), ""));
        eq("unreadText, contacts", "Couldn't read your contacts — try again.",
                ExportCopy.unreadText(true, false, false, false));
        eq("unreadText, all four", "Couldn't read your contacts, calendar, messages and calls — try again.",
                ExportCopy.unreadText(true, true, true, true));
        // NWP-20261124-21: the read cap outlasts the daemon's 120 s arm deadlines (the source check s16 reads main.go).
        if (ExportCopy.READ_MS == 150000) System.out.println("  ok   READ_MS is 150 s");
        else { System.out.println("FAIL READ_MS\n  want: 150000\n  got:  " + ExportCopy.READ_MS); fails++; }
        // A half that was sent and got no reply did not fail on record: it may still export.
        eq("media unanswered clause, byte for byte",
                " The phone didn't answer about your photos & files, so they may still export. Exporting again is safe.",
                ExportCopy.MEDIA_UNANSWERED);
        eq("documents unanswered clause, byte for byte",
                " The phone didn't answer about your contacts, calendar, messages and calls, so they may still export. "
                + "Exporting again is safe.",
                ExportCopy.DOCS_UNANSWERED);
        eq("unanswered line, byte for byte",
                "The phone didn't answer, so your copy may still finish. Wait a minute, then export again — "
                + "exporting again is safe.",
                ExportCopy.unansweredText());
        eq("done line when the media reply was lost",
                "Exported 2 photos to your store. Not included: picture messages, and what's inside your apps "
                + "(2FA codes, notes, bookmarks, loyalty cards). The phone didn't answer about your photos & files, so "
                + "they may still export. Exporting again is safe.",
                ExportCopy.doneText("2 photos", ExportCopy.MEDIA_UNANSWERED, ""));
        int said = 0;
        for (String t : new String[] {
                ExportCopy.MEDIA_UNANSWERED, ExportCopy.DOCS_UNANSWERED, ExportCopy.unansweredText() }) {
            if (t.contains("didn't export") || t.contains("check your connection")) {
                System.out.println("FAIL an unanswered text reports a failure: " + t); said++;
            }
        }
        if (said == 0) System.out.println("  ok   no unanswered text says didn't export or check your connection");
        fails += said;
        String[][] lost = {
            // haveDocs, r, mr, want
            { "1", "ERR-STORE", "", "M" }, { "1", "ERR-KEY", "", "M" }, { "1", "ERR-FOO", "", "M" },
            { "0", "", "", "" }, { "1", "", "", "" }, { "1", "ERR-STORE", "ERR-STORE", "" },
            { "1", "ERR-STORE", "NOMEDIA", "" }, { "1", "LOCAL", "", "" }, { "1", "NONE", "", "" },
        };
        for (String[] c : lost) {
            eq("lostMediaClause(" + c[0] + ", \"" + c[1] + "\", \"" + c[2] + "\")",
                    c[3].equals("M") ? ExportCopy.MEDIA_UNANSWERED : "",
                    ExportCopy.lostMediaClause(c[0].equals("1"), c[1], c[2]));
        }
        if (fails > 0) System.exit(1);
    }
}
