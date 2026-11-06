package com.nowhere.chooser;

import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** NWP-20261117-24: the cases for MmsText (test-mms-text-java.sh). Non-ASCII text is written as unicode escapes so the
 *  file's encoding cannot matter. The pass-through cases use non-ASCII UTF-8 on purpose: a decode under any other
 *  charset changes those bytes. */
public final class MmsTextCases {
    private static int fails = 0;

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) fails++;
    }

    private static byte[] utf8(String s) { return s.getBytes(StandardCharsets.UTF_8); }

    public static void main(String[] args) {
        String cafe = "café";
        String privet = "Привет";
        String euro = "€";

        check("1 ISO-8859-1 (4) text/plain becomes UTF-8",
                Arrays.equals(MmsText.toUtf8("text/plain", 4, cafe.getBytes(StandardCharsets.ISO_8859_1)), utf8(cafe)));
        check("2 UTF-16BE (1013) text/plain becomes UTF-8",
                Arrays.equals(MmsText.toUtf8("text/plain", 1013, privet.getBytes(StandardCharsets.UTF_16BE)),
                        utf8(privet)));
        byte[] bom = privet.getBytes(StandardCharsets.UTF_16);
        check("3 UTF-16 with a BOM (1015) text/plain becomes UTF-8",
                bom[0] == (byte) 0xFE && bom[1] == (byte) 0xFF
                        && Arrays.equals(MmsText.toUtf8("text/plain", 1015, bom), utf8(privet)));
        check("4 windows-1252 (2252) text/plain becomes UTF-8",
                Arrays.equals(MmsText.toUtf8("text/plain", 2252, euro.getBytes(Charset.forName("windows-1252"))),
                        utf8(euro)));

        byte[] u = utf8(cafe);
        check("5 UTF-8 (106) passes through, the same array", MmsText.toUtf8("text/plain", 106, u) == u);
        check("6 an unset charset (0) passes through, the same array", MmsText.toUtf8("text/plain", 0, u) == u);
        check("7 US-ASCII (3) passes through, the same array", MmsText.toUtf8("text/plain", 3, u) == u);
        check("8 an unknown charset (99999) passes through, the same array",
                MmsText.toUtf8("text/plain", 99999, u) == u);

        byte[] latin = cafe.getBytes(StandardCharsets.ISO_8859_1);
        check("9 image/jpeg under ISO-8859-1 (4) passes through, the same array",
                MmsText.toUtf8("image/jpeg", 4, latin) == latin);
        check("10 application/smil under UTF-16 (1015) becomes UTF-8",
                Arrays.equals(MmsText.toUtf8("application/smil", 1015, "<smil/>".getBytes(StandardCharsets.UTF_16)),
                        utf8("<smil/>")));
        check("11 text/plain with null data stays null", MmsText.toUtf8("text/plain", 4, null) == null);

        check("12 storedAsText: text/plain, text/html, text/x-vCard, application/smil",
                MmsText.storedAsText("text/plain") && MmsText.storedAsText("text/html")
                        && MmsText.storedAsText("text/x-vCard") && MmsText.storedAsText("application/smil"));
        check("13 not storedAsText: image/png, application/octet-stream",
                !MmsText.storedAsText("image/png") && !MmsText.storedAsText("application/octet-stream"));

        if (fails > 0) {
            System.out.println(fails + " case(s) FAILED");
            System.exit(1);
        }
        System.out.println("all cases ok");
    }
}
