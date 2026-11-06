// RestageCases -- NWP-20261019-27: TelIngest's re-stage kind filter (restageBase) and line builder (restageLine),
// lifted into Lifted by run.sh. Exit 1 on the first count of failures.
public class RestageCases {
    static int fails = 0;

    static void eq(String what, Object want, Object got) {
        boolean ok = want == null ? got == null : want.equals(got);
        if (!ok) { fails++; System.out.println("FAIL " + what + ": want " + want + " got " + got); }
        else System.out.println("ok   " + what);
    }

    static String[] row(String s) { return s.split(" "); }

    static final String CALL5 = "call 1700000000000 +15550100 60 1";
    static final String SIM = "-0123456789abcdef";
    static final String CALL6 = CALL5 + " " + SIM;
    static final String SMS6 = "sms 1700000000000 +15550100 aGk= 0 1";
    static final String MMS3 = "mms 1700000000000 eyJhIjoxfQ==";

    public static void main(String[] a) {
        // restageBase
        eq("base call/6 calls=true", 6, Lifted.restageBase(row(CALL6), true));
        eq("base call/6 calls=false", -1, Lifted.restageBase(row(CALL6), false));
        eq("base call/5", -1, Lifted.restageBase(row(CALL5), true));
        eq("base call/5 calls=false", -1, Lifted.restageBase(row(CALL5), false));
        eq("base sms/6 calls=true", -1, Lifted.restageBase(row(SMS6), true));
        eq("base sms/6 calls=false", 6, Lifted.restageBase(row(SMS6), false));
        eq("base sms/5", -1, Lifted.restageBase(row("sms 1 +1 aGk= 0"), false));
        eq("base mms/3", 3, Lifted.restageBase(row(MMS3), false));
        eq("base mms/3 calls=true", -1, Lifted.restageBase(row(MMS3), true));
        eq("base mms/2", -1, Lifted.restageBase(row("mms 1700000000000"), false));
        eq("base unknown calls=true", -1, Lifted.restageBase(row("fax 1 2 3 4 5 6"), true));
        eq("base unknown calls=false", -1, Lifted.restageBase(row("fax 1 2 3 4 5 6"), false));

        // restageLine: call rows
        eq("call no retry", CALL6 + " 1", Lifted.restageLine(row(CALL6), 6, 3));
        eq("call retry 2", CALL6 + " 3", Lifted.restageLine(row(CALL6 + " 2"), 6, 3));
        eq("call retry 3", null, Lifted.restageLine(row(CALL6 + " 3"), 6, 3));
        eq("call retry 9", null, Lifted.restageLine(row(CALL6 + " 9"), 6, 3));
        eq("call f5 verbatim", SIM, Lifted.restageLine(row(CALL6), 6, 3).split(" ")[5]);
        eq("call non-numeric retry", CALL6 + " 1", Lifted.restageLine(row(CALL6 + " x"), 6, 3));
        // restageLine: sms rows
        eq("sms no retry", SMS6 + " 1", Lifted.restageLine(row(SMS6), 6, 3));
        eq("sms retry 1", SMS6 + " 2", Lifted.restageLine(row(SMS6 + " 1"), 6, 3));
        eq("sms retry 3", null, Lifted.restageLine(row(SMS6 + " 3"), 6, 3));
        eq("sms non-numeric retry", SMS6 + " 1", Lifted.restageLine(row(SMS6 + " zz"), 6, 3));
        // restageLine: mms rows
        eq("mms no retry", MMS3 + " 1", Lifted.restageLine(row(MMS3), 3, 3));
        eq("mms retry 2", MMS3 + " 3", Lifted.restageLine(row(MMS3 + " 2"), 3, 3));
        eq("mms retry 3", null, Lifted.restageLine(row(MMS3 + " 3"), 3, 3));

        // the line keeps deliver()'s fields and adds exactly one token
        String[][] shapes = { {CALL6, "6"}, {SMS6, "6"}, {MMS3, "3"} };
        for (String[] sh : shapes) {
            String[] in = row(sh[0]);
            int base = Integer.parseInt(sh[1]);
            for (String extra : new String[] {"", " 1", " 2"}) {
                String[] src = row(sh[0] + extra);
                String[] out = Lifted.restageLine(src, base, 3).split(" ");
                boolean same = out.length == base + 1;
                for (int k = 0; same && k < base; k++) same = out[k].equals(in[k]);
                eq("fields kept " + in[0] + extra, true, same);
            }
        }
        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
