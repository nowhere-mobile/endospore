// NWP-20261029-12: what the back-online notification does with each BACKUP reply. Run by run.sh, in com.nowhere.chooser.
public class BackupNowReplyCases {
    static int fails = 0;

    static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            System.out.println("--- FAIL " + what + ": want [" + want + "] got [" + got + "]");
            fails++;
        } else {
            System.out.println("ok " + what);
        }
    }

    static void act(String reply, int want) {
        eq("action " + (reply == null ? "null" : "[" + reply.replace("\n", "\\n") + "]"), want, BackupNowReply.action(reply));
    }

    public static void main(String[] a) {
        act("OK", BackupNowReply.SAVING);
        act("OK\n", BackupNowReply.SAVING);
        act(" OK ", BackupNowReply.SAVING);
        act("NONE", BackupNowReply.CLEAR);
        act("LOCAL", BackupNowReply.CLEAR);

        // NWP-20261201-09: a save already running is joined, never refused.
        String[] joined = {"BUSY seal-in-flight", "BUSY seal-run:periodic", "BUSY seal-run:manual", "BUSY seal-run:logoff"};
        for (String j : joined) {
            act(j, BackupNowReply.SAVING);
            eq("joined body " + j, null, BackupNowReply.body(j));
            eq("joins " + j, true, BackupNowReply.joins(j));
        }
        String[] refused = {"BUSY login", "BUSY user-op-waiting", "BUSY", "BUSY seal-runx", "BUSY seal-in-flightx", "ERR x", "", null};
        for (String r : refused) {
            act(r, BackupNowReply.PROMPT);
            eq("joins " + (r == null ? "null" : "[" + r + "]"), false, BackupNowReply.joins(r));
        }
        for (String r : new String[] {"OK", "NONE", "LOCAL"}) eq("joins " + r, false, BackupNowReply.joins(r));
        eq("joins reads the first line only", false, BackupNowReply.joins("BUSY login\nBUSY seal-in-flight"));

        String[] busy = {"BUSY login", "BUSY user-op-waiting", "BUSY something-new", "BUSY"};
        for (String b : busy) eq("body " + b, ReplyCopy.backupBusy(b), BackupNowReply.body(b));
        String none = "Couldn't reach the save service, so nothing was saved. Try again in a moment.";
        eq("body null", none, BackupNowReply.body(null));
        eq("body empty", none, BackupNowReply.body(""));
        eq("body ERR", none, BackupNowReply.body("ERR x"));
        eq("body OK", null, BackupNowReply.body("OK"));
        eq("body NONE", null, BackupNowReply.body("NONE"));
        eq("body LOCAL", null, BackupNowReply.body("LOCAL"));

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
