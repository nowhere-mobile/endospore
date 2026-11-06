public class DataRoamingCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) {
            fails++;
            System.out.println("--- FAIL " + what);
        }
    }

    static void eq(String want, String got, String what) {
        check(want == null ? got == null : want.equals(got), what + ": want " + want + " got " + got);
    }

    public static void main(String[] a) {
        eq("get", DataRoaming.parseOp("get", false, 0), "parseOp get");
        eq("set", DataRoaming.parseOp("set", true, 0), "parseOp set 0");
        eq("set", DataRoaming.parseOp("set", true, 1), "parseOp set 1");
        eq(null, DataRoaming.parseOp("set", false, 0), "parseOp set without a value");
        eq(null, DataRoaming.parseOp("set", true, 2), "parseOp set 2");
        eq(null, DataRoaming.parseOp("", true, 1), "parseOp empty");
        eq(null, DataRoaming.parseOp(null, true, 1), "parseOp null");
        eq(null, DataRoaming.parseOp("GET", false, 0), "parseOp GET");

        check(DataRoaming.pickSub(5, 3) == 5, "pickSub 5,3");
        check(DataRoaming.pickSub(-1, 3) == 3, "pickSub -1,3");
        check(DataRoaming.pickSub(0, 3) == 3, "pickSub 0,3");
        check(DataRoaming.pickSub(-1, -1) == -1, "pickSub -1,-1");

        eq("OK sub=4 data_roaming=1", DataRoaming.okLine(4, true), "okLine on");
        eq("OK sub=4 data_roaming=0", DataRoaming.okLine(4, false), "okLine off");

        for (String r : new String[] {"user", "arg", "nosub", "denied", "failed", "unreadable"})
            eq("ERR-DR " + r, DataRoaming.errLine(r), "errLine " + r);
        eq("ERR-DR failed", DataRoaming.errLine("bogus"), "errLine unlisted");
        eq("ERR-DR failed", DataRoaming.errLine(null), "errLine null");

        check(DataRoaming.readBackDone(false, 0, 1, 0), "readBackDone get at 0 ms");
        check(!DataRoaming.readBackDone(true, 1, 0, 0), "readBackDone set, old value, 0 ms");
        check(DataRoaming.readBackDone(true, 1, 1, 0), "readBackDone set, wanted value");
        check(!DataRoaming.readBackDone(true, 1, 0, 2999), "readBackDone set at 2999 ms");
        check(DataRoaming.readBackDone(true, 1, 0, 3000), "readBackDone set at 3000 ms");

        eq("com.nowhere.chooser.action.DATA_ROAMING", DataRoaming.ACTION, "ACTION");
        eq("op", DataRoaming.EXTRA_OP, "EXTRA_OP");
        eq("value", DataRoaming.EXTRA_VALUE, "EXTRA_VALUE");
        eq("sub", DataRoaming.EXTRA_SUB, "EXTRA_SUB");
        check(DataRoaming.READBACK_MS == 3000, "READBACK_MS");
        check(DataRoaming.READBACK_STEP_MS == 100, "READBACK_STEP_MS");

        System.out.println(fails == 0 ? "data-roaming cases: all passed" : "data-roaming cases: " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
