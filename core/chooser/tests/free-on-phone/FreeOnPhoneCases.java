package com.nowhere.chooser;

/** NWP-20261125-11 (h51 #4 B2): which "What's using your space" row offers Free on this phone, and which verdict
 *  lets ReArchiveReceiver.freeNow archive. Compiled with FreeOnPhone ALONE (java.* only). */
public class FreeOnPhoneCases {
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    /** The positive control: a downloaded On-demand app whose code is in the store. */
    static boolean control() { return FreeOnPhone.offer("ondemand", true, false, true, true, false); }

    /** A "not offered" case passes only when the control is offered, so a mutant that offers nothing fails it. */
    static void refused(String name, boolean offered) {
        boolean c = control();
        check(name, c && !offered, "control=" + c + " offered=" + offered);
    }

    public static void main(String[] args) {
        check("ondemand, installed, code in store is offered", control(), "" + control());
        refused("auto is not offered", FreeOnPhone.offer("auto", true, false, true, true, false));
        refused("installed mode is not offered", FreeOnPhone.offer("installed", true, false, true, true, false));
        refused("not installed is not offered", FreeOnPhone.offer("ondemand", false, false, true, true, false));
        refused("bundled is not offered", FreeOnPhone.offer("ondemand", true, true, true, true, false));
        refused("apps not measured is not offered", FreeOnPhone.offer("ondemand", true, false, false, true, false));
        refused("ondemand without code is not offered", FreeOnPhone.offer("ondemand", true, false, true, false, false));
        refused("Play stack is not offered", FreeOnPhone.offer("ondemand", true, false, true, true, true));
        refused("null and empty mode are not offered", FreeOnPhone.offer(null, true, false, true, true, false)
                || FreeOnPhone.offer("", true, false, true, true, false));
        check("unread source with a job is unread", "unread".equals(FreeOnPhone.verdict("x", true)),
                FreeOnPhone.verdict("x", true));
        check("unread source without a job is unread", "unread".equals(FreeOnPhone.verdict("x", false)),
                FreeOnPhone.verdict("x", false));
        check("a held job is kept", "job".equals(FreeOnPhone.verdict(null, true)), FreeOnPhone.verdict(null, true));
        check("no job and every source read is ok", "ok".equals(FreeOnPhone.verdict(null, false)),
                FreeOnPhone.verdict(null, false));
        check("messages name the reason", FreeOnPhone.KEPT.equals(FreeOnPhone.message("job"))
                && FreeOnPhone.UNREAD.equals(FreeOnPhone.message("unread"))
                && FreeOnPhone.FAILED.equals(FreeOnPhone.message("failed")),
                FreeOnPhone.message("job") + " / " + FreeOnPhone.message("unread") + " / "
                        + FreeOnPhone.message("failed"));
        check("the link says Free on this phone", "Free on this phone".equals(FreeOnPhone.LINK), FreeOnPhone.LINK);
        if (fails == 0) System.out.println("PASS " + runs + " cases");
        System.exit(fails == 0 ? 0 : 1);
    }
}
