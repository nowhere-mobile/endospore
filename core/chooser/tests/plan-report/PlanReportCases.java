package com.nowhere.chooser;

/** NWP-20261118-17: the Storage screen's "Report this" rule, compiled with PlanReport ALONE (java.* only). */
public class PlanReportCases {
    static final long NOW = 1_800_000_000L;
    static final long E = NOW / 86_400L;   // the current daily epoch
    static final long WK = NOW / 604_800L; // the current weekly epoch
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String line(long through, String extra) {
        return "OK credit=0 through=" + through + " epochsec=86400 sub=0" + extra;
    }

    static boolean o(String reply, long entitled) { return PlanReport.offer(reply, entitled, NOW); }

    public static void main(String[] args) {
        String live = line(E + 10, "");
        check("a live term with entitled 0 is reportable", o(live, 0), "false");
        check("entitled -1 is not reportable", !o(live, -1), "true");
        check("entitled 5 is not reportable", !o(live, 5), "true");
        check("through=0 is not reportable", !o(line(0, ""), 0), "true");
        check("through one epoch in the past is not reportable", !o(line(E - 1, ""), 0), "true");
        check("through == the current epoch is reportable", o(line(E, ""), 0), "false");
        check("moving=1700000000 is not reportable", !o(line(E + 10, " moving=1700000000"), 0), "true");
        check("moving=0 is reportable", o(line(E + 10, " moving=0"), 0), "false");
        check("moving=abc is reportable", o(line(E + 10, " moving=abc"), 0), "false");
        // WK is the current epoch under 604800 and long dead under 86400 (E is about seven times larger).
        check("no epochsec uses the weekly default", o("OK credit=0 through=" + WK + " sub=0", 0), "false");
        check("reply NONE is not reportable", !o("NONE", 0), "true");
        check("null reply is not reportable", !o(null, 0), "true");
        check("a non-OK reply with a live through is not reportable",
                !o("ERR through=" + (E + 10) + " epochsec=86400", 0), "true");
        boolean liveR = o("OK sub=0 epochsec=86400 credit=0 through=" + (E + 10), 0);
        boolean movingR = o("OK moving=1700000000 epochsec=86400 through=" + (E + 10) + " credit=0", 0);
        boolean pastR = o("OK epochsec=86400 through=" + (E - 1) + " credit=0", 0);
        check("tokens in another order give the same answers", liveR && !movingR && !pastR,
                "live=" + liveR + " moving=" + movingR + " past=" + pastR);
        if (fails == 0) System.out.println("PASS " + runs + " cases");
        System.exit(fails == 0 ? 0 : 1);
    }
}
