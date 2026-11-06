package com.nowhere.chooser;

/** NWP-20261023-04: the cases for StoreSignerPin (made-up certs only, no real keys). */
public final class StoreSignerPinCases {
    private static int failed = 0;

    private static String show(Object o) { return o == null ? "null" : "\"" + o.toString().replace("\n", "\\n").replace("\r", "\\r") + "\""; }

    /** A thrown exception is a failed case, never a pass. */
    private static void pin(String reply, String pkg, String want) {
        String got;
        try {
            got = StoreSignerPin.fromFetchReply(reply, pkg);
        } catch (Throwable t) {
            failed++;
            System.out.println("FAIL fromFetchReply(" + show(reply) + ") threw " + t);
            return;
        }
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL fromFetchReply(" + show(reply) + ", " + show(pkg) + "): want " + show(want) + " got " + show(got));
        }
    }

    private static String rep(char c, int n) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < n; i++) b.append(c);
        return b.toString();
    }

    public static void main(String[] args) {
        String pkg = "com.a.b";
        String hex = "0123456789abcdef" + "fedcba9876543210" + "00112233445566778899aabbccddeeff";
        String up = hex.toUpperCase(java.util.Locale.ROOT);

        pin("OK com.a.b " + hex, pkg, hex);
        pin("OK com.a.b " + up, pkg, hex);
        pin("  OK com.a.b " + hex + "\r", pkg, hex);
        pin("OK com.a.b -", pkg, "");
        pin("OK com.a.b -\r", pkg, "");
        pin("  OK   com.a.b   -  ", pkg, "");

        pin("OK com.a.b", pkg, null);
        pin("OK", pkg, null);
        pin("OK com.a.b " + hex + " extra", pkg, null);
        pin("OK com.a.b - extra", pkg, null);
        pin("OK com.other " + hex, pkg, null);
        pin("OK com.other -", pkg, null);
        pin("OK com.a.b abc", pkg, null);
        pin("OK com.a.b " + rep('a', 63), pkg, null);
        pin("OK com.a.b " + rep('a', 65), pkg, null);
        pin("OK com.a.b " + rep('g', 64), pkg, null);
        pin("ok com.a.b -", pkg, null);
        pin("OK-SESSION-ONLY com.a.b -", pkg, null);
        pin("OK-SESSION-ONLY com.a.b " + hex, pkg, null);
        pin("ERR-UNVERIFIED", pkg, null);
        pin(null, pkg, null);
        pin("", pkg, null);
        pin("   ", pkg, null);
        pin("OK com.a.b -", null, null);

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok");
    }
}
