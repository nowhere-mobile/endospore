// NWP-20261210-21: cases for EmergencyEditGate, the pure rule for EmergencyInfo's two editors in user 0.
// run.sh prepends the package line, so these reach the package-private class.

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

public class EmergencyEditGateCases {
    static int fails = 0;

    static void eq(String label, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("ok      " + label);
        } else {
            System.out.println("--- FAIL " + label + ": want " + want + ", got " + got);
            fails++;
        }
    }

    interface Case { void run() throws Throwable; }

    static void check(String label, Case c) {
        try {
            c.run();
        } catch (Throwable x) {
            System.out.println("--- FAIL " + label + ": threw " + x);
            fails++;
        }
    }

    static final String LINE = "^emergency-edit state=(owner|locked) changed=\\d+ kept=\\d+ failed=\\d+$";

    public static void main(String[] args) {
        // C1: locked wants DISABLED (2), owner stood down wants DEFAULT (0).
        check("C1 wanted(false)", () -> eq("C1 wanted(false) is DISABLED", 2, EmergencyEditGate.wanted(false)));
        check("C1 wanted(true)", () -> eq("C1 wanted(true) is DEFAULT", 0, EmergencyEditGate.wanted(true)));

        // C2: exactly the two editors; the read-only view is never listed.
        check("C2 editors", () -> {
            Set<String> want = new HashSet<>(Arrays.asList(
                    "com.android.emergency.edit.EditInfoActivity",
                    "com.android.emergency.edit.EditMedicalInfoActivity"));
            eq("C2 EDITORS has two entries", 2, EmergencyEditGate.EDITORS.length);
            eq("C2 EDITORS is exactly the two editors", want, new HashSet<>(Arrays.asList(EmergencyEditGate.EDITORS)));
            boolean view = false;
            for (String e : EmergencyEditGate.EDITORS) view |= e.contains(".view.");
            eq("C2 no EDITORS entry names .view.", false, view);
            eq("C2 PKG", "com.android.emergency", EmergencyEditGate.PKG);
        });

        // C3: write only on a transition.
        int[][] t = {{0, 2}, {1, 2}, {2, 0}, {1, 0}};
        for (int[] p : t) {
            check("C3 needsWrite" + Arrays.toString(p), () -> eq("C3 needsWrite(" + p[0] + "," + p[1] + ") is true",
                    true, EmergencyEditGate.needsWrite(p[0], p[1])));
        }
        int[][] f = {{2, 2}, {0, 0}};
        for (int[] p : f) {
            check("C3 needsWrite" + Arrays.toString(p), () -> eq("C3 needsWrite(" + p[0] + "," + p[1] + ") is false",
                    false, EmergencyEditGate.needsWrite(p[0], p[1])));
        }

        // C4: a disable kills an editor left open; an enable keeps the app running.
        check("C4 flags(2)", () -> eq("C4 flags(DISABLED) is 0", 0, EmergencyEditGate.flags(2)));
        check("C4 flags(0)", () -> eq("C4 flags(DEFAULT) is DONT_KILL_APP", 1, EmergencyEditGate.flags(0)));

        // C5: the log line is counts only, in its fixed shape.
        check("C5 line locked", () -> {
            String l = EmergencyEditGate.line(false, 2, 0, 0);
            eq("C5 locked line [" + l + "] has the fixed shape", true, l.matches(LINE));
            eq("C5 locked line says locked", true, l.startsWith("emergency-edit state=locked changed=2 "));
        });
        check("C5 line owner", () -> {
            String l = EmergencyEditGate.line(true, 0, 1, 1);
            eq("C5 owner line [" + l + "] has the fixed shape", true, l.matches(LINE));
            eq("C5 owner line", "emergency-edit state=owner changed=0 kept=1 failed=1", l);
        });

        if (fails > 0) {
            System.out.println(fails + " case(s) FAILED");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
