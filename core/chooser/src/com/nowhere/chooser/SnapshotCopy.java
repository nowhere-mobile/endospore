package com.nowhere.chooser;

/**
 * The words the chooser puts on screen when the user deletes or restores a retained version in "Restore a snapshot"
 * (NWP-20261027-07, docs/product-decisions.md 2026-10-19; Restore since NWP-20261116-22). Decided here so the
 * confirmation can never promise a size ("the screen must not promise a size it cannot free") and so each
 * DELETE-SNAPSHOT and ROLLBACK reply reads as what it is.
 *
 * DELETE-SNAPSHOT replies are OK | NONE | LOCAL | BUSY | NOSNAP | ERR-ARG | ERR (handleDeleteSnapshot,
 * NWP-20261027-04); ROLLBACK replies are {@code OK <v>} | NONE | LOCAL | BUSY | NOSNAP | ERR (handleRollback). They are
 * matched on the WHOLE first token: no reply word extends another today (so {@code OK} cannot match an
 * {@code OK-...} word), and {@code ERR-ARG} deliberately falls to the generic line. An empty or null reply is the
 * daemon not answering (sendDaemon's read timed out or the socket died), and the request may still have landed: the
 * daemon can delete the version, or roll the head and queue the unsaved sign-out, after the reply is lost. So that text
 * says the change may or may not have happened, never that the connection failed. BUSY names no save: the daemon also
 * answers BUSY while a teardown is queued (endUnsavedBlocked), so its text says only that nothing changed.
 *
 * Pure Java, no android.* import: core/chooser/test-snapshot-copy-java.sh compiles this file directly.
 */
final class SnapshotCopy {
    private SnapshotCopy() {}

    static String confirmTitle() {
        return "Delete this version?";
    }

    static String confirmMessage(String label) {
        return "The version saved " + label + " will be deleted from your store. This can't be undone, and you won't "
                + "be able to restore it. Your current data and your other saved versions are not affected.";
    }

    /** The toast for a DELETE-SNAPSHOT reply. */
    static String deleteReply(String r) {
        String first = r == null ? "" : r.trim().split("\\s+", 2)[0];
        if (first.equals("OK")) return "Version deleted.";
        if (first.equals("BUSY")) return "This phone is busy right now — nothing was deleted. Try again in a moment.";
        if (first.equals("NOSNAP")) return "That version is no longer available.";
        if (first.equals("LOCAL")) return "This profile is a throwaway — there's nothing saved to delete.";
        if (first.equals("NONE")) return "No active session.";
        if (first.isEmpty()) return "The phone didn't answer, so the delete may or may not have happened. The list "
                + "below shows what is kept.";
        return "Couldn't delete it — check your connection and try again.";
    }

    /** True when the ROLLBACK reply is {@code OK <v>} (or a bare OK): the first token, by equality. */
    static boolean rolledBack(String r) {
        return r != null && r.trim().split("\\s+", 2)[0].equals("OK");
    }

    /** The toast for a ROLLBACK reply that is not OK. */
    static String rollbackReply(String r) {
        String first = r == null ? "" : r.trim().split("\\s+", 2)[0];
        if (first.isEmpty()) return "The phone didn't answer, so the restore may or may not have happened. If it did, "
                + "this session ends without saving in a moment and the earlier version loads when you sign in again.";
        if (first.equals("LOCAL")) return "This profile is a throwaway — there's nothing to restore.";
        if (first.equals("BUSY")) return "This phone is busy right now — nothing was restored. Try again in a moment.";
        if (first.equals("NOSNAP")) return "That version is no longer available — pick another.";
        if (first.equals("NONE")) return "No active session.";
        return "Couldn't restore — check your connection and try again.";
    }
}
