// NWP-20261206-03: cases for EmergencyWindowRule, the pure half of the Q047 emergency-window client.
// run.sh prepends the package line, so these reach the package-private class.

import java.util.function.Supplier;

public class EmergencyWindowCases {
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

    static final String LOCAL = "an emergency call left this phone ";

    public static void main(String[] args) {
        final long T = 1_000_000_000L;
        final Supplier<String> never = () -> { throw new AssertionError("ask called on a local hit"); };

        check("window", () -> eq("WINDOW_MS is 15 minutes", 900_000L, EmergencyWindowRule.WINDOW_MS));

        check("local 0s hits", () -> eq("local 0s hits", LOCAL + "0s ago", EmergencyWindowRule.localReason(T, T)));
        check("local 899s hits", () -> eq("local 899s hits", LOCAL + "899s ago", EmergencyWindowRule.localReason(T, T + 899_000L)));
        check("local 900s misses", () -> eq("local 900s misses", null, EmergencyWindowRule.localReason(T, T + 900_000L)));
        check("local negative age counts as 0", () -> eq("local negative age counts as 0", LOCAL + "0s ago", EmergencyWindowRule.localReason(T, T - 5_000L)));
        check("local markedAt 0 misses", () -> eq("local markedAt 0 misses", null, EmergencyWindowRule.localReason(0L, T)));
        check("local markedAt -1 misses", () -> eq("local markedAt -1 misses", null, EmergencyWindowRule.localReason(-1L, T)));

        String[][] daemon = {
            {null, EmergencyWindowRule.FAIL_OPEN},
            {"YES 0", LOCAL + "0s ago (daemon)"},
            {"YES 61\n", LOCAL + "61s ago (daemon)"},
            {"YES -1", null},
            {"YES x", null},
            {"YES", null},
            {"NO", null},
            {"DENIED", null},
            {"ERR clock", null},
            {"", null},
        };
        for (String[] c : daemon) {
            final String label = "daemon [" + (c[0] == null ? "null" : c[0].replace("\n", "\\n")) + "]";
            check(label, () -> eq(label, c[1], EmergencyWindowRule.daemonReason(c[0])));
        }

        check("exempt local hit never asks", () -> eq("exempt local hit never asks", LOCAL + "10s ago",
                EmergencyWindowRule.exemptReason(T, T + 10_000L, never)));
        check("exempt local miss + YES hits", () -> eq("exempt local miss + YES hits", LOCAL + "30s ago (daemon)",
                EmergencyWindowRule.exemptReason(T, T + 900_000L, () -> "YES 30")));
        check("exempt local miss + NO is null", () -> eq("exempt local miss + NO is null", null,
                EmergencyWindowRule.exemptReason(T, T + 900_000L, () -> "NO")));
        check("exempt local miss + no answer fails open", () -> eq("exempt local miss + no answer fails open",
                EmergencyWindowRule.FAIL_OPEN, EmergencyWindowRule.exemptReason(T, T + 900_000L, () -> null)));
        check("exempt markedAt 0 + YES hits", () -> eq("exempt markedAt 0 + YES hits", LOCAL + "5s ago (daemon)",
                EmergencyWindowRule.exemptReason(0L, T, () -> "YES 5")));

        String[][] mark = {
            {"OK", null},
            {"OK\n", null},
            {"", "no-answer"},
            {null, "no-answer"},
            {"DENIED", "denied"},
            {"ERR clock", "clock"},
            {"ERR other", "other"},
            {"weird", "other"},
        };
        for (String[] c : mark) {
            final String label = "markFailure [" + (c[0] == null ? "null" : c[0].replace("\n", "\\n")) + "]";
            check(label, () -> eq(label, c[1], EmergencyWindowRule.markFailure(c[0])));
        }

        System.out.println(fails == 0 ? "PASS" : fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
