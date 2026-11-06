package com.nowhere.chooser;

/**
 * NWP-20261128-12: what a GET-OWNER-INBOX reply means to the owner inbox screen. The daemon answers an empty inbox
 * NONE. It never sends OK with no row. A read that failed is not an empty inbox, so the screen must not show it as
 * one, and must not clear the unassigned-line notice for it. Pure: java.lang / java.util only, so
 * core/chooser/tests/owner-inbox-reply runs it under plain javac.
 */
final class OwnerInboxReply {
    static final int FAILED = 0, EMPTY = 1, ROWS = 2;
    static final String FAILED_LINE = "The inbox couldn't be read right now — open it again to retry.";
    static final String EMPTY_LINE = "No messages on unassigned SIMs.";

    private OwnerInboxReply() {}

    /**
     * The reply's kind. {@code lines} comes from roundTripLinesOrNull: null is a failed or cut-short read.
     * An empty list (the socket closed with no line) is FAILED. A first line "NONE" is EMPTY. "OK" alone is EMPTY too
     * (defensive: no daemon sends it today). "OK" and at least one row is ROWS. Anything else (ERR request, DENIED, an
     * unknown token) is FAILED.
     *
     * NONE is an inference, not a proof. serveOwnerInboxList answers NONE for an empty inbox and also for a key that
     * does not open. The chooser asks only with the passphrase that owner verify just accepted (ownerSessionPass), so
     * the NONE it can see is the empty inbox. If the key does not open, the screen shows nothing in both readings.
     */
    static int of(java.util.List<String> lines) {
        if (lines == null || lines.isEmpty()) return FAILED;
        String head = lines.get(0);
        if ("NONE".equals(head)) return EMPTY;
        if ("OK".equals(head)) return lines.size() == 1 ? EMPTY : ROWS;
        return FAILED;
    }
}
