/** Cases for SnapshotCopy (NWP-20261027-07, NWP-20261116-22). Run by test-snapshot-copy-java.sh. Exits 1 on any
 *  failure. The expected texts are literals, never read back from SnapshotCopy. */
public class SnapshotCopyCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("--- FAIL " + what); }
    }

    static final String CONN = "Couldn't delete it — check your connection and try again.";
    static final String BUSY_DELETE = "This phone is busy right now — nothing was deleted. Try again in a moment.";
    static final String LOST_DELETE = "The phone didn't answer, so the delete may or may not have happened. The list "
            + "below shows what is kept.";
    static final String DEFAULT_RESTORE = "Couldn't restore — check your connection and try again.";
    static final String BUSY_RESTORE = "This phone is busy right now — nothing was restored. Try again in a moment.";
    static final String LOST_RESTORE = "The phone didn't answer, so the restore may or may not have happened. If it "
            + "did, this session ends without saving in a moment and the earlier version loads when you sign in again.";

    static String show(String r) {
        return r == null ? "null" : "'" + r.replace("\n", "\\n") + "'";
    }

    static void reply(String r, String want) {
        String got = SnapshotCopy.deleteReply(r);
        check(want.equals(got), "deleteReply(" + show(r) + ") = '" + got + "' want '" + want + "'");
    }

    static void roll(String r, String want) {
        String got = SnapshotCopy.rollbackReply(r);
        check(want.equals(got), "rollbackReply(" + show(r) + ") = '" + got + "' want '" + want + "'");
    }

    static void rolled(String r, boolean want) {
        check(SnapshotCopy.rolledBack(r) == want, "rolledBack(" + show(r) + ") want " + want);
    }

    public static void main(String[] a) {
        reply("OK", "Version deleted.");
        reply("OK\n", "Version deleted.");
        reply("BUSY", BUSY_DELETE);
        reply("NOSNAP", "That version is no longer available.");
        reply("LOCAL", "This profile is a throwaway — there's nothing saved to delete.");
        reply("NONE", "No active session.");
        reply("ERR", CONN);
        reply("ERR-ARG", CONN);
        reply("", LOST_DELETE);
        reply("  ", LOST_DELETE);
        reply(null, LOST_DELETE);
        reply("OK-LATER", CONN);
        check(!SnapshotCopy.deleteReply("NOSNAP").equals(CONN), "NOSNAP is not the connection line");
        check(!SnapshotCopy.deleteReply("ERR").equals("Version deleted."), "ERR is not read as OK");

        // ROLLBACK (handleRollback): every reply but OK gets a toast; only the codes below get their own text.
        roll("LOCAL", "This profile is a throwaway — there's nothing to restore.");
        roll("NOSNAP", "That version is no longer available — pick another.");
        roll("BUSY", BUSY_RESTORE);
        roll("BUSY\n", BUSY_RESTORE);
        roll("NONE", "No active session.");
        roll("", LOST_RESTORE);
        roll("  ", LOST_RESTORE);
        roll(null, LOST_RESTORE);
        roll("ERR", DEFAULT_RESTORE);
        roll("ERR-ARG", DEFAULT_RESTORE);
        roll("NOSNAPX", DEFAULT_RESTORE);
        roll("BUSYX", DEFAULT_RESTORE);
        rolled("OK 3", true);
        rolled("OK", true);
        rolled(" OK 3\n", true);
        rolled("OKAY", false);
        rolled("OK-LATER", false);
        rolled("", false);
        rolled(null, false);
        rolled("ERR", false);

        // Every code handleRollback writes (test-snapshot-copy-java.sh extracts them from main.go) is rendered: OK by
        // rolledBack, ERR by the default line by design, every other code by a text of its own.
        String codes = System.getenv("SNAPSHOT_ROLLBACK_CODES");
        check(codes != null && !codes.trim().isEmpty(), "SNAPSHOT_ROLLBACK_CODES is unset: the code pin did not run");
        if (codes != null) {
            for (String c : codes.trim().split("\\s+")) {
                if (c.isEmpty()) continue;
                if (c.equals("OK")) {
                    check(SnapshotCopy.rolledBack("OK 1") && SnapshotCopy.rolledBack("OK"), "OK is not read as rolled back");
                } else if (!c.equals("ERR")) {
                    check(!SnapshotCopy.rolledBack(c), "handleRollback's " + c + " is read as rolled back");
                    check(!DEFAULT_RESTORE.equals(SnapshotCopy.rollbackReply(c)),
                            "handleRollback's " + c + " falls to the default line");
                }
            }
        }

        check(SnapshotCopy.confirmTitle().equals("Delete this version?"), "title");
        String m = SnapshotCopy.confirmMessage("Oct 3, 4:05 PM");
        check(m.contains("Oct 3, 4:05 PM"), "message names the version");
        check(m.contains("can't be undone"), "message says it can't be undone");
        String n = SnapshotCopy.confirmMessage("earlier");
        check(!n.matches("(?s).*[0-9].*"), "message has no digit (no size): " + n);
        String low = n.toLowerCase();
        for (String bad : new String[] {"gb", "mb", "kb", "free", "bytes"})
            check(!low.contains(bad), "message has no size phrase '" + bad + "'");

        if (fails > 0) { System.out.println(fails + " failure(s)"); System.exit(1); }
        System.out.println("ok snapshot copy");
    }
}
