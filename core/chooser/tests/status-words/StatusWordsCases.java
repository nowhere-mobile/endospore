// NWP-20261122-19: the words the owner sees for three daemon tokens, run against the lifted helpers.
// ChooserActivity.otaApplyPhase (otad's PROG phase under "Installing update…"), ChooserActivity.otaFailReason (the
// FAILED code of otaResState) and ProfileActivity.coldLockWhy (the COLD-LOCK-STATUS line under "Locking…").
// run.sh lifts the three into Lifted, compiles this beside it and runs it; it pins the tokens to their producers.
// Each case prints PASS or FAIL; the exit status is 1 when any case failed.
final class StatusWordsCases {
    private static int fails = 0;

    private static void eq(String name, String got, String want) {
        if (want.equals(got)) {
            System.out.println("  PASS " + name);
        } else {
            fails++;
            System.out.println("  FAIL " + name + ": got [" + got + "] want [" + want + "]");
        }
    }

    private static void ends(String name, String got, String suffix) {
        if (got != null && got.endsWith(suffix)) {
            System.out.println("  PASS " + name);
        } else {
            fails++;
            System.out.println("  FAIL " + name + ": got [" + got + "] want it to end [" + suffix + "]");
        }
    }

    private static void starts(String name, String got, String prefix) {
        if (got != null && got.startsWith(prefix)) {
            System.out.println("  PASS " + name);
        } else {
            fails++;
            System.out.println("  FAIL " + name + ": got [" + got + "] want it to start [" + prefix + "]");
        }
    }

    // The fixed middle of every coldLockWhy line, copied from ProfileActivity.
    private static final String MID = " The phone locks itself as soon as it's done, so you can put it down.\nWaiting ";

    public static void main(String[] args) {
        // otaApplyPhase: one case per phase otad's update_engine case writes.
        eq("P1 oswrite", Lifted.otaApplyPhase("oswrite"), "Writing it to the phone");
        eq("P2 osverify", Lifted.otaApplyPhase("osverify"), "Checking the update");
        eq("P3 osfinalize", Lifted.otaApplyPhase("osfinalize"), "Finishing up");
        eq("P4 oscleanup", Lifted.otaApplyPhase("oscleanup"), "Tidying up the previous update");
        eq("P5 osdone", Lifted.otaApplyPhase("osdone"), "Done — restarting");
        eq("P6 empty", Lifted.otaApplyPhase(""), "Working");
        eq("P6 null", Lifted.otaApplyPhase(null), "Working");
        eq("P6 osdownload (the download's phase, not an apply phase)", Lifted.otaApplyPhase("osdownload"), "Working");
        eq("P6 oswriting (an unknown phase)", Lifted.otaApplyPhase("oswriting"), "Working");

        // otaFailReason: one case per FAILED code otaResState returns, then the fallbacks.
        eq("F1 ERR-CHECK", Lifted.otaFailReason("ERR-CHECK"), "couldn't reach the update service");
        eq("F2 ERR-RESTORE", Lifted.otaFailReason("ERR-RESTORE"), "couldn't download it");
        eq("F3 ERR-PAYLOAD", Lifted.otaFailReason("ERR-PAYLOAD"), "the download was incomplete");
        eq("F4 ERR-APPLY", Lifted.otaFailReason("ERR-APPLY"), "couldn't install it");
        eq("F5 ERR-STALE", Lifted.otaFailReason("ERR-STALE"), "the update stalled");
        eq("F6 ERR-NEW is shown raw", Lifted.otaFailReason("ERR-NEW"), "ERR-NEW");
        eq("F7 empty", Lifted.otaFailReason(""), "unknown error");

        // coldLockWhy: "WAITING <op> <secs>" from coldLockStatusLine; anything else hides the line.
        String c1 = Lifted.coldLockWhy("WAITING out 125");
        starts("C1 WAITING out 125 starts", c1, "Finishing a backup first.");
        ends("C1 WAITING out 125 ends", c1, "Waiting 2 minutes.");
        eq("C1 WAITING out 125 whole", c1, "Finishing a backup first." + MID + "2 minutes.");
        String c2 = Lifted.coldLockWhy("WAITING - 125");
        starts("C2 WAITING - 125 starts", c2, "Finishing another task first.");
        ends("C2 WAITING - 125 ends", c2, "Waiting 2 minutes.");
        eq("C2 WAITING - 125 whole", c2, "Finishing another task first." + MID + "2 minutes.");
        String c3 = Lifted.coldLockWhy("WAITING out 60");
        ends("C3 WAITING out 60 ends", c3, "Waiting 1 minute.");
        eq("C3 WAITING out 60 whole", c3, "Finishing a backup first." + MID + "1 minute.");
        ends("C4 WAITING - 0", Lifted.coldLockWhy("WAITING - 0"), "Waiting under a minute.");
        ends("C4 WAITING out 59", Lifted.coldLockWhy("WAITING out 59"), "Waiting under a minute.");
        for (String r : new String[] {"LOCKING", "NONE", "", "WAITING out", "WAITING out x", "WAITING out 5 extra"}) {
            eq("C5 [" + r + "] hides the line", Lifted.coldLockWhy(r), "");
        }

        System.exit(fails == 0 ? 0 : 1);
    }
}
