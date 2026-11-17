/** Cases for BackupWait (NWP-20261206-20). Run by core/vendor-common/bin/test-backup-wait-java.sh. Exits 1 on any failure. */
public class BackupWaitCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("--- FAIL " + what); }
        else System.out.println("ok   " + what);
    }

    static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\r", "\\r") + "\"";
    }

    static void words(String line) {
        check(BackupWait.text(line) == BackupWait.REKEY_BATCH, "text(" + show(line) + ") is REKEY_BATCH");
    }

    static void none(String line) {
        String t = BackupWait.text(line);
        check(t == null, "text(" + show(line) + ") is null, got " + show(t));
    }

    public static void main(String[] a) {
        words("WAIT rekey-batch");
        words("WAIT rekey-batch\r");
        words("  WAIT rekey-batch ");
        none(null);
        none("");
        none("WAIT");
        none("WAIT other");
        none("WAIT rekey-batchx");
        none("OK");
        none("BUSY rekey-batch");
        String w = BackupWait.REKEY_BATCH;
        check(w != null && w.startsWith("Backing up…"), "REKEY_BATCH starts with \"Backing up…\"");
        check(w != null && !w.contains("OK"), "REKEY_BATCH holds no \"OK\"");
        check(w != null && !w.contains("Cancel"), "REKEY_BATCH holds no \"Cancel\"");
        if (fails > 0) { System.out.println(fails + " FAILED"); System.exit(1); }
        System.out.println("PASS: BackupWait cases");
    }
}
