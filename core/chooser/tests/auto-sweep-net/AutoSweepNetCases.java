package com.nowhere.chooser;

/** NWP-20261112-11: executes AutoSweepNet, the post-login Auto sweep's network rule (Q042). */
public class AutoSweepNetCases {
    static int runs = 0, fails = 0;

    static void eq(String name, boolean want, boolean got) {
        runs++;
        if (want != got) {
            fails++;
            System.out.println("FAIL " + name + "\n     want " + want + ", got " + got);
        }
    }

    public static void main(String[] args) {
        // A1 mayFetch(byHand, allowMetered, onWifi, hasInternet): the prefetch line's rule, a request by hand exempt.
        eq("A1 by hand, no network -> true", true, AutoSweepNet.mayFetch(true, false, false, false));
        eq("A1 by hand, cellular -> true", true, AutoSweepNet.mayFetch(true, false, false, true));
        eq("A1 switch on, cellular -> true", true, AutoSweepNet.mayFetch(false, true, false, true));
        eq("A1 switch on, no internet -> false", false, AutoSweepNet.mayFetch(false, true, false, false));
        eq("A1 switch off, cellular -> false", false, AutoSweepNet.mayFetch(false, false, false, true));
        eq("A1 switch off, Wi-Fi -> true", true, AutoSweepNet.mayFetch(false, false, true, true));

        // A2 meteredAllowed: the session's GET-PREFETCH-METERED reply.
        eq("A2 meteredAllowed(\"1\") -> true", true, AutoSweepNet.meteredAllowed("1"));
        eq("A2 meteredAllowed(\" 1\\n\") -> true", true, AutoSweepNet.meteredAllowed(" 1\n"));
        eq("A2 meteredAllowed(\"0\") -> false", false, AutoSweepNet.meteredAllowed("0"));
        eq("A2 meteredAllowed(\"\") -> false", false, AutoSweepNet.meteredAllowed(""));
        eq("A2 meteredAllowed(null) -> false", false, AutoSweepNet.meteredAllowed(null));
        eq("A2 meteredAllowed(\"ERR\") -> false", false, AutoSweepNet.meteredAllowed("ERR"));

        // A3 rekick(prevUid, prevNet, uid, net): only a no -> yes turn within one session.
        eq("A3 rekick(10,false,10,true) -> true", true, AutoSweepNet.rekick(10, false, 10, true));
        eq("A3 rekick(10,true,10,true) -> false", false, AutoSweepNet.rekick(10, true, 10, true));
        eq("A3 rekick(10,false,11,true) -> false", false, AutoSweepNet.rekick(10, false, 11, true));
        eq("A3 rekick(0,false,0,true) -> false", false, AutoSweepNet.rekick(0, false, 0, true));
        eq("A3 rekick(10,true,10,false) -> false", false, AutoSweepNet.rekick(10, true, 10, false));
        eq("A3 rekick(-1,false,10,true) -> false", false, AutoSweepNet.rekick(-1, false, 10, true));

        System.out.println(runs + " cases, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
