package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** NWP-20261112-06: the cases for TapUpdate, Q050's tap update (made-up certs only, no real keys). */
public final class TapUpdateCases {
    private static int failed = 0;
    private static int ran = 0;

    private static String show(Object o) { return o == null ? "null" : "\"" + o.toString().replace("\n", "\\n").replace("\r", "\\r") + "\""; }

    private static void check(String what, boolean cond) {
        ran++;
        if (!cond) { failed++; System.out.println("FAIL " + what); }
    }

    /** A thrown exception is a failed case, never a pass. */
    private static void parse(String reply, long wantVc, String wantCert) {
        ran++;
        TapUpdate.Pin p;
        try { p = TapUpdate.parse(reply); } catch (Throwable t) { failed++; System.out.println("FAIL parse(" + show(reply) + ") threw " + t); return; }
        if (wantCert == null) {
            if (p != null) { failed++; System.out.println("FAIL parse(" + show(reply) + "): want null, got vc=" + p.vc + " cert=" + show(p.cert)); }
            return;
        }
        if (p == null || p.vc != wantVc || !wantCert.equals(p.cert)) {
            failed++;
            System.out.println("FAIL parse(" + show(reply) + "): want vc=" + wantVc + " cert=" + show(wantCert)
                    + ", got " + (p == null ? "null" : "vc=" + p.vc + " cert=" + show(p.cert)));
        }
    }

    private static void take(String what, long sealedVc, List<String> certs, TapUpdate.Pin pin, boolean want) {
        ran++;
        boolean got;
        try { got = TapUpdate.takeCatalog(sealedVc, certs, pin); } catch (Throwable t) { failed++; System.out.println("FAIL takeCatalog " + what + " threw " + t); return; }
        if (got != want) { failed++; System.out.println("FAIL takeCatalog " + what + ": want " + want + " got " + got); }
    }

    private static String name(int o) {
        return o == TapUpdate.INSTALLED ? "INSTALLED" : o == TapUpdate.SEALED ? "SEALED" : o == TapUpdate.STOP ? "STOP" : "?" + o;
    }

    private static void after(String reply, String verdict, int want) {
        ran++;
        int got;
        try { got = TapUpdate.afterFetch(reply, verdict); } catch (Throwable t) { failed++; System.out.println("FAIL afterFetch(" + show(reply) + ", " + show(verdict) + ") threw " + t); return; }
        if (got != want) { failed++; System.out.println("FAIL afterFetch(" + show(reply) + ", " + show(verdict) + "): want " + name(want) + " got " + name(got)); }
    }

    private static void hex(String what, byte[] in, String want) {
        ran++;
        String got;
        try { got = TapUpdate.certHex(in); } catch (Throwable t) { failed++; System.out.println("FAIL certHex " + what + " threw " + t); return; }
        if (!want.equals(got)) { failed++; System.out.println("FAIL certHex " + what + ": want " + want + " got " + show(got)); }
    }

    public static void main(String[] args) {
        String hex = "0123456789abcdef" + "fedcba9876543210" + "00112233445566778899aabbccddeeff";
        String up = hex.toUpperCase(java.util.Locale.ROOT);
        String other = "f" + hex.substring(1);

        // T1 parse
        parse("OK 42 " + up, 42, hex);
        parse("OK 42 " + hex, 42, hex);
        parse("OK 42 " + hex + "\r", 42, hex);
        parse("NONE", 0, null);
        parse("ERR-PKG", 0, null);
        parse("OK 42", 0, null);
        parse("OK x " + hex, 0, null);
        parse("OK 0 " + hex, 0, null);
        parse("OK -1 " + hex, 0, null);
        parse("OK +42 " + hex, 0, null);
        parse("OK 42 " + hex.substring(1), 0, null);
        parse("OK 42 " + hex + "a", 0, null);
        parse("OK 42 " + "g" + hex.substring(1), 0, null);
        parse("OK 42 " + hex + " extra", 0, null);
        parse("ok 42 " + hex, 0, null);
        parse("", 0, null);
        parse(null, 0, null);

        // T2 takeCatalog (the archived package is at 41, signed by hex)
        List<String> mine = Collections.singletonList(hex);
        take("newer, same cert", 41, mine, new TapUpdate.Pin(42, hex), true);
        take("newer, cert case differs", 41, Collections.singletonList(up), new TapUpdate.Pin(42, hex), true);
        take("newer, one of two signers", 41, Arrays.asList(other, hex), new TapUpdate.Pin(42, hex), true);
        take("same vc", 41, mine, new TapUpdate.Pin(41, hex), false);
        take("older vc", 41, mine, new TapUpdate.Pin(40, hex), false);
        take("newer, other cert", 41, mine, new TapUpdate.Pin(42, other), false);
        take("empty certs", 41, Collections.<String>emptyList(), new TapUpdate.Pin(42, hex), false);
        take("null certs", 41, null, new TapUpdate.Pin(42, hex), false);
        take("null pin", 41, mine, null, false);

        // T3 afterFetch
        check("INSTALLED, SEALED and STOP are distinct",
                TapUpdate.INSTALLED != TapUpdate.SEALED && TapUpdate.SEALED != TapUpdate.STOP && TapUpdate.INSTALLED != TapUpdate.STOP);
        String ok = "OK com.a.b " + hex;
        after(ok, "OK", TapUpdate.INSTALLED);
        after(ok, "PENDING", TapUpdate.STOP);
        after(ok, "FAIL", TapUpdate.SEALED);
        after(ok, "NOSIGNER", TapUpdate.SEALED);
        after(ok, null, TapUpdate.SEALED);
        after("ERR-FETCH", null, TapUpdate.SEALED);
        after("ERR-UNVERIFIED", null, TapUpdate.SEALED);
        after("ERR-NOSIGNER", null, TapUpdate.SEALED);
        after("ERR-STAGE", null, TapUpdate.SEALED);
        after("NONE", null, TapUpdate.SEALED);
        after(null, null, TapUpdate.SEALED);
        after("", null, TapUpdate.SEALED);
        after("ERR-OVERPLAN short=1 used=2 covered=3 add=4", null, TapUpdate.SEALED);
        after("ERR-FETCH", "OK", TapUpdate.SEALED);
        after("ERR-CANCELLED", null, TapUpdate.STOP);
        after("ERR-CANCELLED for a sign-out", null, TapUpdate.STOP);

        // T4 certHex: the SHA-256 test vectors
        hex("of \"abc\"", "abc".getBytes(java.nio.charset.StandardCharsets.US_ASCII),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        hex("of no bytes", new byte[0], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

        if (failed == 0) System.out.println("PASS " + ran + " cases");
        else System.out.println("FAILED " + failed + " of " + ran + " cases");
        System.exit(failed == 0 ? 0 : 1);
    }
}
