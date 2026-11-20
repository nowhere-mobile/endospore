/** NWP-20261208-19: ScanNetHold's whole rule, compiled against the real class (package line stripped) by
 *  core/chooser/test-scan-net-hold-java.sh. Prints "ok <id>" or "FAIL <id>"; exits 1 on any failure. */
public class ScanNetHoldCases {
    static int failed = 0;

    static void check(String id, boolean cond) {
        System.out.println((cond ? "  ok    " : "  FAIL  ") + id);
        if (!cond) failed++;
    }

    public static void main(String[] a) {
        final int RUN = ScanNetHold.RUN, HOLD = ScanNetHold.HOLD, SKIP = ScanNetHold.SKIP;
        check("C0 RUN, HOLD and SKIP are distinct", RUN != HOLD && HOLD != SKIP && RUN != SKIP);

        check("O1 on(\"1\") is true", ScanNetHold.on("1"));
        check("O2 on(\" 1\\n\") is true (the file as SettingsText.read returns it)", ScanNetHold.on(" 1\n"));
        check("O3 on(\"0\") is false", !ScanNetHold.on("0"));
        check("O4 on(\"\") is false (an absent file: any network)", !ScanNetHold.on(""));
        check("O5 on(null) is false (an unreadable file: any network)", !ScanNetHold.on(null));
        check("O6 on(\"11\") is false", !ScanNetHold.on("11"));

        check("D1 roamd's start (no extras), switch on, metered -> RUN", ScanNetHold.decide(false, false, true, false) == RUN);
        check("D2 an unlanded start with retry, switch on, metered -> RUN", ScanNetHold.decide(false, true, true, false) == RUN);
        check("D3 landing ask, switch off, metered -> RUN (the default: any network)", ScanNetHold.decide(true, false, false, false) == RUN);
        check("D4 landing ask, switch off, unmetered -> RUN", ScanNetHold.decide(true, false, false, true) == RUN);
        check("D5 landing ask, switch on, unmetered -> RUN", ScanNetHold.decide(true, false, true, true) == RUN);
        check("D6 landing ask, switch on, metered -> HOLD", ScanNetHold.decide(true, false, true, false) == HOLD);
        check("D7 re-ask, switch off, unmetered -> SKIP", ScanNetHold.decide(true, true, false, true) == SKIP);
        check("D7 re-ask, switch off, metered -> SKIP", ScanNetHold.decide(true, true, false, false) == SKIP);
        check("D8 re-ask, switch on, unmetered -> RUN", ScanNetHold.decide(true, true, true, true) == RUN);
        check("D8 re-ask, switch on, metered -> HOLD", ScanNetHold.decide(true, true, true, false) == HOLD);

        check("T1 retryNow(12, 12, true) is true", ScanNetHold.retryNow(12, 12, true));
        check("T2 retryNow(12, 12, false) is false (still metered)", !ScanNetHold.retryNow(12, 12, false));
        check("T3 retryNow(-1, 12, true) is false (nothing held)", !ScanNetHold.retryNow(-1, 12, true));
        check("T4 retryNow(12, 13, true) is false (another session)", !ScanNetHold.retryNow(12, 13, true));
        check("T5 retryNow(0, 0, true) is false (the gate)", !ScanNetHold.retryNow(0, 0, true));

        check("W1 LABEL is not empty", ScanNetHold.LABEL != null && !ScanNetHold.LABEL.trim().isEmpty());
        check("W1 SUB is not empty", ScanNetHold.SUB != null && !ScanNetHold.SUB.trim().isEmpty());
        check("K1 FILE is nowhere-scan-unmetered", "nowhere-scan-unmetered".equals(ScanNetHold.FILE));
        check("K2 the extras are rescanlanded and rescanretry",
                "rescanlanded".equals(ScanNetHold.EXTRA_LANDED) && "rescanretry".equals(ScanNetHold.EXTRA_RETRY));

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
    }
}
