package com.nowhere.chooser;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

/** NWP-20261109-25: ExportXml.attr against the real ExportXml.java, by exact text and by a conforming parser. Exit 1
 *  on any failed case. */
public class ExportXmlCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("  FAIL " + what); } else System.out.println("  ok   " + what);
    }

    static void eq(String name, String in, String want) {
        String got = ExportXml.attr(in);
        check(want.equals(got), name + (want.equals(got) ? "" : " -- got [" + got + "]"));
    }

    /** What a parser must read back: CRLF and lone CR become one LF; forbidden code points and unpaired surrogates
     *  become U+FFFD. */
    static String expect(String s) {
        StringBuilder b = new StringBuilder();
        int i = 0, n = s.length();
        while (i < n) {
            int cp = s.codePointAt(i);
            i += Character.charCount(cp);
            if (cp == '\r') { if (i < n && s.charAt(i) == '\n') i++; b.append('\n'); }
            else if (cp == '\n' || cp == '\t') b.append((char) cp);
            else if ((cp >= 0x20 && cp <= 0xD7FF) || (cp >= 0xE000 && cp <= 0xFFFD) || (cp >= 0x10000 && cp <= 0x10FFFF))
                b.appendCodePoint(cp);
            else b.append('\uFFFD');
        }
        return b.toString();
    }

    static void parses(String name, String in) {
        try {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            f.setFeature("http://xml.org/sax/features/external-general-entities", false);
            f.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            f.setExpandEntityReferences(false);
            DocumentBuilder db = f.newDocumentBuilder();
            db.setErrorHandler(null);
            String xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<sms body=\"" + ExportXml.attr(in) + "\"/>\n";
            String got = db.parse(new ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8)))
                    .getDocumentElement().getAttribute("body");
            String want = expect(in);
            check(want.equals(got), "parse " + name + (want.equals(got) ? "" : " -- read back [" + got + "]"));
        } catch (Exception e) {
            check(false, "parse " + name + " -- " + e);
        }
    }

    public static void main(String[] a) {
        eq("null is empty", null, "");
        eq("the four specials", "a&b<c>\"d", "a&amp;b&lt;c&gt;&quot;d");
        eq("CRLF, LF and CR each one &#10;", "x\r\ny\nz\rw", "x&#10;y&#10;z&#10;w");
        eq("tab is &#9;", "a\tb", "a&#9;b");
        eq("NUL is U+FFFD", "\u0000", "\uFFFD");
        eq("ESC is U+FFFD", "\u001B", "\uFFFD");
        eq("VT is U+FFFD", "\u000B", "\uFFFD");
        eq("U+FFFE is U+FFFD", "\uFFFE", "\uFFFD");
        eq("U+FFFF is U+FFFD", "\uFFFF", "\uFFFD");
        eq("lone high surrogate", "\uD800", "\uFFFD");
        eq("lone low surrogate", "\uDC00", "\uFFFD");
        eq("high surrogate before text", "\uD800a", "\uFFFDa");
        eq("emoji kept whole", "\uD83D\uDE00", "\uD83D\uDE00");
        eq("ASCII unchanged", "Hello, world 123", "Hello, world 123");
        eq("e-acute unchanged", "\u00E9", "\u00E9");

        String[][] wf = {
            {"empty", ""}, {"specials", "a&b<c>\"d"}, {"newlines", "x\r\ny\nz\rw"}, {"tab", "a\tb"},
            {"NUL", "a\u0000b"}, {"ESC", "\u001B[0m"}, {"VT", "\u000B"}, {"FF", "\u000C"}, {"U+FFFE", "\uFFFE"},
            {"U+FFFF", "\uFFFF"}, {"lone high", "\uD800"}, {"lone low", "\uDC00"}, {"high then text", "x\uD800y"},
            {"emoji", "\uD83D\uDE00"}, {"ASCII", "plain"}, {"e-acute", "\u00E9"}, {"mixed", "t\ta\u0001\r\n\uD83D\uDE00&"},
        };
        for (String[] c : wf) parses(c[0], c[1]);
        System.out.println(fails == 0 ? "all cases passed" : fails + " case(s) FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
