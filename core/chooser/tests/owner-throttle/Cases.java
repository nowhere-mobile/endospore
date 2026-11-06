// NWP-20261011-39: the cases for the owner verify's back-off, run against Lifted (run.sh). The clock is
// SystemClock.elapsedRealtime(): 'now' and 'last' are uptimes, and a 'last' larger than 'now' is either a reboot since
// the last counted attempt or a pre-NWP-20261011-39 file's wall-clock stamp. Neither may lift the wait.
public final class Cases {
    static int fails = 0, runs = 0;

    static void eq(String name, long want, long got) {
        runs++;
        if (want != got) {
            fails++;
            System.out.println("FAIL " + name + "\n     want: " + want + "\n     got:  " + got);
        }
    }

    static final long LEGACY = 1_700_000_000_000L; // a wall-clock 'last' as files before this slice hold it

    public static void main(String[] a) {
        // ---- the tiers ----
        eq("4 fails: no wait", 0, Lifted.owBackoffMs(4));
        eq("5 fails: 30 s", 30_000L, Lifted.owBackoffMs(5));
        eq("9 fails: 30 s", 30_000L, Lifted.owBackoffMs(9));
        eq("10 fails: 5 min", 300_000L, Lifted.owBackoffMs(10));
        eq("19 fails: 5 min", 300_000L, Lifted.owBackoffMs(19));
        eq("20 fails: 30 min", 1_800_000L, Lifted.owBackoffMs(20));

        // ---- fewer than five fails never waits, whatever the stamps say ----
        eq("0 fails, last 0", 0, Lifted.owWaitSecs(0, 5_000, 0));
        eq("4 fails, same instant", 0, Lifted.owWaitSecs(4, 5_000, 5_000));
        eq("4 fails, reboot", 0, Lifted.owWaitSecs(4, 5_000, 9_000_000));
        eq("4 fails, legacy wall-clock last", 0, Lifted.owWaitSecs(4, 5_000, LEGACY));

        // ---- same boot, within the wait: throttled, rounded UP to whole seconds ----
        eq("same boot, 0 s in", 30, Lifted.owWaitSecs(5, 1_000_000, 1_000_000));
        eq("same boot, 10 s in", 20, Lifted.owWaitSecs(5, 1_010_000, 1_000_000));
        eq("same boot, 10.001 s in rounds up", 20, Lifted.owWaitSecs(5, 1_010_001, 1_000_000));
        eq("same boot, 1 ms left", 1, Lifted.owWaitSecs(5, 1_029_999, 1_000_000));
        eq("same boot, 10 fails, 60 s in", 240, Lifted.owWaitSecs(10, 1_060_000, 1_000_000));
        eq("same boot, 20 fails, 1 s in", 1799, Lifted.owWaitSecs(20, 1_001_000, 1_000_000));

        // ---- same boot, after the wait: allowed ----
        eq("same boot, exactly 30 s in", 0, Lifted.owWaitSecs(5, 1_030_000, 1_000_000));
        eq("same boot, an hour in", 0, Lifted.owWaitSecs(20, 4_600_000, 1_000_000));

        // ---- last > now (a reboot since the last attempt): since = uptime, throttled while uptime < wait ----
        eq("reboot, 10 s up", 20, Lifted.owWaitSecs(5, 10_000, 5_000_000));
        eq("reboot, 29.999 s up", 1, Lifted.owWaitSecs(5, 29_999, 5_000_000));
        eq("reboot, 30 s up", 0, Lifted.owWaitSecs(5, 30_000, 5_000_000));
        eq("reboot, 30 min tier, 60 s up", 1740, Lifted.owWaitSecs(20, 60_000, 5_000_000));
        // ---- a legacy wall-clock 'last' (1.7e12, beyond any uptime) reads the same way ----
        eq("legacy last, 10 s up", 20, Lifted.owWaitSecs(5, 10_000, LEGACY));
        eq("legacy last, 30 s up", 0, Lifted.owWaitSecs(5, 30_000, LEGACY));
        eq("legacy last, 5 min tier, 100 s up", 200, Lifted.owWaitSecs(10, 100_000, LEGACY));
        // ---- a damaged negative 'last' never reads as more time than has passed ----
        eq("negative last, 10 s up", 20, Lifted.owWaitSecs(5, 10_000, -1));
        eq("very negative last, 10 s up", 20, Lifted.owWaitSecs(5, 10_000, Long.MIN_VALUE));

        // ---- owSinceMs is never negative and never more than 'now': on one boot the true time elapsed is now - last,
        // and across a reboot it is at least the uptime, which is all the device can prove ----
        eq("since, same boot", 7_000, Lifted.owSinceMs(10_000, 3_000));
        eq("since, same instant", 0, Lifted.owSinceMs(10_000, 10_000));
        eq("since, reboot", 10_000, Lifted.owSinceMs(10_000, 3_000_000));
        eq("since, legacy", 10_000, Lifted.owSinceMs(10_000, LEGACY));
        eq("since, negative last", 10_000, Lifted.owSinceMs(10_000, -5));
        long[] samples = { 0, 1, 999, 30_000, 86_400_000L, LEGACY, Long.MAX_VALUE, -1, Long.MIN_VALUE };
        for (long now : new long[] { 0, 1, 30_000, 86_400_000L }) {
            for (long last : samples) {
                long s = Lifted.owSinceMs(now, last);
                runs++;
                if (s < 0 || s > now) {
                    fails++;
                    System.out.println("FAIL since(" + now + ", " + last + ") = " + s + " is outside [0, uptime]");
                }
            }
        }

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
