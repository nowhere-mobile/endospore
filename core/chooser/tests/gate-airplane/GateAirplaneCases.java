// GateAirplaneCases -- NWP-20261109-21: the gate Settings Airplane mode switch's pure decisions. The suite
// (core/vendor-common/bin/test-gate-airplane-java.sh) prepends the package line and compiles this beside
// GateAirplane.java.
public class GateAirplaneCases {
    static int fails = 0;

    static void check(String what, boolean ok) {
        if (ok) System.out.println("ok   " + what);
        else { System.out.println("FAIL " + what); fails++; }
    }

    public static void main(String[] a) {
        check("settled: the wanted value read at once", GateAirplane.settled(true, true, 0));
        check("settled: the other value read early is not done", !GateAirplane.settled(true, false, 100));
        check("settled: the other value read at the bound is done", GateAirplane.settled(true, false, 3000));
        check("settled: no read at the bound is done", GateAirplane.settled(false, null, 3000));
        check("settled: no read early is not done", !GateAirplane.settled(true, null, 0));
        check("settled: off wanted and read off", GateAirplane.settled(false, false, 0));

        check("toast: confirmed on", "Airplane mode on".equals(GateAirplane.toast(true, true)));
        check("toast: confirmed off", "Airplane mode off".equals(GateAirplane.toast(false, false)));
        String no = "The phone didn't confirm the change";
        check("toast: on wanted, off read", no.equals(GateAirplane.toast(true, false)));
        check("toast: off wanted, on read", no.equals(GateAirplane.toast(false, true)));
        check("toast: on wanted, no read", no.equals(GateAirplane.toast(true, null)));
        check("toast: off wanted, no read", no.equals(GateAirplane.toast(false, null)));

        check("ROW", "Airplane mode".equals(GateAirplane.ROW));
        check("SUB", "A sign-in in airplane mode is an offline session".equals(GateAirplane.SUB));
        check("READBACK_MS", GateAirplane.READBACK_MS == 3000);
        check("STEP_MS", GateAirplane.STEP_MS == 100);

        // The screen's loop against a phone that never confirms, on a fake clock: it must end at the bound.
        long t = 0;
        int iterations = 0;
        while (true) {
            iterations++;
            if (GateAirplane.settled(true, false, t) || iterations > 1000) break;
            t += GateAirplane.STEP_MS;
        }
        check("loop: a phone that never confirms ends within the bound (" + iterations + " reads)",
                iterations <= GateAirplane.READBACK_MS / GateAirplane.STEP_MS + 1);

        if (fails > 0) System.exit(1);
    }
}
