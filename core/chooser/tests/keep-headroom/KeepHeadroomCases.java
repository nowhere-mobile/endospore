// NWP-20261104-07: the KEEP-HEADROOM payload line and the daemon's verdict. Run by run.sh, in com.nowhere.chooser.
public class KeepHeadroomCases {
    static int fails = 0;

    static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            System.out.println("--- FAIL " + what + ": want [" + want + "] got [" + got + "]");
            fails++;
        } else {
            System.out.println("ok " + what);
        }
    }

    static void req(String pkg, long bytes, String want) {
        eq("request " + pkg + " " + bytes, want, KeepHeadroom.request(pkg, bytes));
    }

    static void verdict(String reply, Boolean want) {
        eq("verdict " + (reply == null ? "null" : "[" + reply.replace("\n", "\\n") + "]"), want, KeepHeadroom.verdict(reply));
    }

    public static void main(String[] a) {
        req("a.b", 5, "a.b:5");
        req("a.b", 0, "a.b:0");
        req("a.b", -1, null);
        req(null, 5, null);
        req("", 5, null);
        req("a b", 5, null);
        req("a:b", 5, null);

        verdict("OK add=1", Boolean.FALSE);
        verdict("OK", Boolean.FALSE);
        verdict(" OK add=0\n", Boolean.FALSE);
        verdict("ERR-OVERPLAN short=1 used=2 covered=3 add=4", Boolean.TRUE);
        verdict("ERR-OVERPLAN", Boolean.TRUE);
        verdict("NONE", null);
        verdict("LOCAL", null);
        verdict("ERR-ARG", null);
        verdict("ERR unknown", null);
        verdict("OKAY", null);
        verdict("ERR-OVERPLANX", null);
        verdict("", null);
        verdict(null, null);

        if (fails > 0) {
            System.out.println(fails + " case(s) failed");
            System.exit(1);
        }
    }
}
