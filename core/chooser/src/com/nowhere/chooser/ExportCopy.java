package com.nowhere.chooser;

/**
 * The words "Export a copy" puts on screen about what a copy leaves out (NWP-20261101-02, docs/product-decisions.md
 * 2026-10-20, Q155). Both strings are the decision's, byte for byte, with app names kept general. They live here so a
 * javac suite can pin them: the success line used to name only what was taken, and someone leaving Nowhere read it as
 * "my 2FA seeds came with me".
 *
 * No "export them from each app first" line: the decision adds it only after a lynx check shows an Aegis export file
 * comes through the media export.
 */
final class ExportCopy {
    private ExportCopy() {}

    /** Shown directly under the Export a copy button. */
    static final String UNDER_BUTTON = "A copy takes your contacts, calendar, text messages (not picture messages), "
            + "calls, photos and files. It doesn't take what's inside your apps, like 2FA codes, notes, bookmarks "
            + "or loyalty cards.";

    /** The clause a successful export's done line carries. */
    static final String NOT_INCLUDED = "Not included: picture messages, and what's inside your apps "
            + "(2FA codes, notes, bookmarks, loyalty cards).";

    /** The success line: what was taken, what a copy never takes, then today's two suffixes (null reads as ""). */
    static String doneText(String parts, String missing, String where) {
        return "Exported " + parts + " to your store. " + NOT_INCLUDED + (missing == null ? "" : missing)
                + (where == null ? "" : where);
    }

    /** NWP-20261112-24: the kinds whose read FAILED with the permission granted, in a fixed order -- "contacts",
     *  "contacts and calls", "contacts, messages and calls" -- or "" when none did. A denied kind is not one. */
    static String unreadKinds(boolean contacts, boolean calendar, boolean messages, boolean calls) {
        java.util.List<String> k = new java.util.ArrayList<>();
        if (contacts) k.add("contacts");
        if (calendar) k.add("calendar");
        if (messages) k.add("messages");
        if (calls) k.add("calls");
        if (k.isEmpty()) return "";
        if (k.size() == 1) return k.get(0);
        return String.join(", ", k.subList(0, k.size() - 1)) + " and " + k.get(k.size() - 1);
    }

    /** The done line's clause for the kinds that could not be read ("" when none): a copy without them is not whole. */
    static String unreadLine(boolean contacts, boolean calendar, boolean messages, boolean calls) {
        String k = unreadKinds(contacts, calendar, messages, calls);
        return k.isEmpty() ? "" : " Your " + k + " couldn't be read, so they aren't in this copy — try again.";
    }

    /** Shown in place of "Nothing to export yet" when nothing landed and a kind could not be read ("" when none). */
    static String unreadText(boolean contacts, boolean calendar, boolean messages, boolean calls) {
        String k = unreadKinds(contacts, calendar, messages, calls);
        return k.isEmpty() ? "" : "Couldn't read your " + k + " — try again.";
    }

    /** NWP-20261124-21: how long runExport reads EXPORT-MEDIA and sendExport reads EXPORT, in milliseconds. It must
     *  outlast both arms' deadlines in core/agent/main.go, conn.SetDeadline(time.Now().Add(120 * time.Second)), which
     *  start only after the daemon has read the request and holds sessionMu; the 30 s margin covers the connect, the
     *  body write and the reply. The daemon must give up first (#744): otherwise the chooser reads "" for an export
     *  that landed. Keep it above every arm deadline if either moves; test-export-copy-java.sh reads both from main.go
     *  and fails when this does not outlast them. */
    static final int READ_MS = 150_000;

    /** NWP-20261124-21: the done line's clause when the media half was sent and no reply came back. No reply is not a
     *  failure on record: the daemon may still pin the media export after the read gave up. */
    static final String MEDIA_UNANSWERED = " The phone didn't answer about your photos & files, so they may still "
            + "export. Exporting again is safe.";

    /** NWP-20261124-21: the same for the documents half. */
    static final String DOCS_UNANSWERED = " The phone didn't answer about your contacts, calendar, messages and calls, "
            + "so they may still export. Exporting again is safe.";

    /** NWP-20261124-21: the line when nothing landed and the half it reports was sent and got no reply. */
    static String unansweredText() {
        return "The phone didn't answer, so your copy may still finish. Wait a minute, then export again — "
                + "exporting again is safe.";
    }

    /** NWP-20261124-21: the clause the nothing-landed line adds when the documents half failed on record and the media
     *  half got no reply: that media half may still land, so the line must not leave it reported as failed. LOCAL and
     *  NONE say this session cannot export at all, so the media half cannot land either; with both replies "" the
     *  line is already unansweredText(). */
    static String lostMediaClause(boolean haveDocs, String r, String mr) {
        return haveDocs && mr.isEmpty() && !r.isEmpty() && !r.startsWith("LOCAL") && !r.startsWith("NONE")
                ? MEDIA_UNANSWERED : "";
    }
}
