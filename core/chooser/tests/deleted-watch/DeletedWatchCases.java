package com.nowhere.chooser;

/** Cases for DeletedWatch (NWP-20261105-02, Q117). Literal values on purpose: a changed constant must be caught. */
final class DeletedWatchCases {
    private static int passed, failed;

    private static void check(String label, String got, String want) {
        if (want.equals(got)) {
            passed++;
        } else {
            failed++;
            System.out.println("FAIL " + label + ": got " + got + ", want " + want);
        }
    }

    private static void check(String label, boolean ok) {
        check(label, String.valueOf(ok), "true");
    }

    public static void main(String[] args) {
        check("0 s waits", DeletedWatch.action(0, 0, false, 0, false), "WAIT");
        check("59 s waits", DeletedWatch.action(59_000, 0, false, 0, false), "WAIT");
        check("60 s reboots", DeletedWatch.action(60_000, 0, false, 0, false), "REBOOT");
        check("2 misses wait", DeletedWatch.action(10_000, 2, false, 0, false), "WAIT");
        check("3 misses reboot", DeletedWatch.action(10_000, 3, false, 0, false), "REBOOT");
        check("asked 14 s waits", DeletedWatch.action(70_000, 5, true, 14_000, false), "WAIT");
        check("asked 15 s powers", DeletedWatch.action(70_000, 5, true, 15_000, false), "POWER");
        check("asked and threw powers", DeletedWatch.action(70_000, 5, true, 0, true), "POWER");
        long[] waits = {0, 59_000, 60_000, 600_000};
        int[] misses = {0, 2, 3, 10};
        long[] sinces = {0, 14_999, 15_000, 100_000};
        for (long w : waits) {
            for (int m : misses) {
                for (long s : sinces) {
                    String got = DeletedWatch.action(w, m, true, s, false);
                    check("asked w=" + w + " m=" + m + " s=" + s, got, s >= 15_000 ? "POWER" : "WAIT");
                }
            }
        }
        check("constants", DeletedWatch.POLL_MS == 2000 && DeletedWatch.DEADLINE_MS == 60_000
                && DeletedWatch.MISSES == 3 && DeletedWatch.REBOOT_GRACE_MS == 15_000);
        String msg = DeletedWatch.POWER_MESSAGE;
        check("message names the power button", msg.contains("power button"));
        check("message claims no save", !msg.toLowerCase().contains("saved"));
        check("message starts Profile deleted", msg.startsWith("Profile deleted"));
        System.out.println("DeletedWatchCases: " + passed + " passed, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
