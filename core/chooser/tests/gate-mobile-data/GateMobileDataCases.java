// GateMobileDataCases -- NWP-20261107-13: the Owner settings Mobile data switch's pure decisions. The suite
// (core/vendor-common/bin/test-gate-mobile-data-java.sh) prepends the package line and compiles this beside
// GateMobileData.java.
public class GateMobileDataCases {
    static int fails = 0;

    static void check(String what, boolean ok) {
        if (ok) System.out.println("ok   " + what);
        else { System.out.println("FAIL " + what); fails++; }
    }

    public static void main(String[] a) {
        check("settled: the wanted value read at once", GateMobileData.settled(true, true, 0));
        check("settled: the other value read early is not done", !GateMobileData.settled(true, false, 100));
        check("settled: the other value read at the bound is done", GateMobileData.settled(true, false, 3000));
        check("settled: no read at the bound is done", GateMobileData.settled(true, null, 3000));
        check("settled: no read early is not done", !GateMobileData.settled(true, null, 0));
        check("settled: off wanted and read off", GateMobileData.settled(false, false, 0));

        check("toast: confirmed on", "Mobile data on".equals(GateMobileData.toast(true, true)));
        check("toast: confirmed off", "Mobile data off".equals(GateMobileData.toast(false, false)));
        String no = "The phone hasn't confirmed the change.";
        check("toast: on wanted, off read", no.equals(GateMobileData.toast(true, false)));
        check("toast: off wanted, on read", no.equals(GateMobileData.toast(false, true)));
        check("toast: on wanted, no read", no.equals(GateMobileData.toast(true, null)));
        check("toast: off wanted, no read", no.equals(GateMobileData.toast(false, null)));

        check("ROW", "Mobile data".equals(GateMobileData.ROW));
        check("ROW_SUB", "The phone's own setting, used at the gate and between sessions".equals(GateMobileData.ROW_SUB));
        check("NOTE", ("Turns mobile data on or off for the phone itself. A profile can change it for its own session; "
                + "when that session ends or goes into standby, the phone comes back to this setting.")
                .equals(GateMobileData.NOTE));
        check("READBACK_MS", GateMobileData.READBACK_MS == 3000);
        check("STEP_MS", GateMobileData.STEP_MS == 100);

        // The screen's loop against a phone that never confirms, on a fake clock: it must end at the bound.
        long t = 0;
        int iterations = 0;
        while (true) {
            iterations++;
            if (GateMobileData.settled(true, false, t) || iterations > 1000) break;
            t += GateMobileData.STEP_MS;
        }
        check("loop: a phone that never confirms ends within the bound (" + iterations + " reads)",
                iterations <= GateMobileData.READBACK_MS / GateMobileData.STEP_MS + 1);

        if (fails > 0) System.exit(1);
    }
}
