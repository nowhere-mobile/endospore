// NWP-20261103-14: the cases for StoreService.indexRefreshAllowed, run against Lifted (run.sh).
public final class Cases {
    static int fails = 0, runs = 0;

    static void eq(String label, boolean want, boolean got) {
        runs++;
        if (want != got) {
            fails++;
            System.out.println("FAIL " + label + ": want " + want + " got " + got);
        }
    }

    public static void main(String[] a) {
        eq("unmetered, no reply", true, Lifted.indexRefreshAllowed(false, null));
        eq("unmetered, switch off", true, Lifted.indexRefreshAllowed(false, "0"));
        eq("metered, switch on", true, Lifted.indexRefreshAllowed(true, "1"));
        eq("metered, switch on with newline", true, Lifted.indexRefreshAllowed(true, "1\n"));
        eq("metered, switch on padded", true, Lifted.indexRefreshAllowed(true, " 1 "));
        eq("metered, switch off", false, Lifted.indexRefreshAllowed(true, "0"));
        eq("metered, no reply", false, Lifted.indexRefreshAllowed(true, null));
        eq("metered, empty reply", false, Lifted.indexRefreshAllowed(true, ""));
        eq("metered, OK is not 1", false, Lifted.indexRefreshAllowed(true, "OK"));
        eq("metered, 10 is not 1", false, Lifted.indexRefreshAllowed(true, "10"));
        eq("metered, 11 is not 1", false, Lifted.indexRefreshAllowed(true, "11"));
        System.out.println(runs + " cases, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
