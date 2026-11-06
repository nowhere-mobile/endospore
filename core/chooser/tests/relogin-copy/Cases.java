package com.nowhere.chooser;

/** NWP-20261103-09 (Q068): the reconnect prompt's copy and the verdict of RELOGIN's reply, against the verbatim
 *  ReloginCopy. Exit 1 on any failed case. */
public class Cases {
    static int bad = 0;

    static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) bad++;
    }

    static void verdict(String shown, String reply, ReloginCopy.Verdict want) {
        check("verdict " + shown + " -> " + want, ReloginCopy.verdict(reply) == want);
    }

    public static void main(String[] a) {
        verdict("OK", "OK", ReloginCopy.Verdict.LOADING);
        verdict("NOSTORED", "NOSTORED", ReloginCopy.Verdict.KEPT);
        verdict("ERR-STORE", "ERR-STORE", ReloginCopy.Verdict.RETRY);
        verdict("null", null, ReloginCopy.Verdict.RETRY);
        verdict("empty", "", ReloginCopy.Verdict.RETRY);
        verdict("NONE", "NONE", ReloginCopy.Verdict.RETRY);
        verdict("BUSY", "BUSY", ReloginCopy.Verdict.RETRY);
        verdict("OK-LATER (never a prefix match)", "OK-LATER", ReloginCopy.Verdict.RETRY);
        verdict("OK + newline", "OK\n", ReloginCopy.Verdict.LOADING);
        verdict("padded NOSTORED", " NOSTORED ", ReloginCopy.Verdict.KEPT);

        String b = ReloginCopy.RECONNECT_BODY;
        check("body is conditional", b.contains("If this name has saved data"));
        check("body names the action", b.contains("Load my saved data"));
        check("body has no unconditional discard sentence", !b.contains("will be discarded."));
        check("body does not promise saved data", !b.contains("Your saved data isn't loaded yet"));
        check("body says nothing is lost otherwise", b.contains("nothing is lost"));
        System.exit(bad == 0 ? 0 : 1);
    }
}
