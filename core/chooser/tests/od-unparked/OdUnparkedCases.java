package com.nowhere.chooser;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** NWP-20261129-13: test-od-unparked-java.sh compiles this with OdUnparked.java, ALONE, and runs it. */
public final class OdUnparkedCases {
    static int bad = 0;

    static void is(String id, String what, String text, String... want) {
        Set<String> w = new HashSet<>(Arrays.asList(want));
        Set<String> got = OdUnparked.parse(text);
        if (w.equals(got)) { System.out.println("ok " + id + " " + what); return; }
        System.out.println("FAIL " + id + " " + what + ": want " + w + ", got " + got);
        bad++;
    }

    public static void main(String[] a) {
        is("C1", "a two-name list", "com.a\ncom.b\n", "com.a", "com.b");
        is("C1", "no newline after the last name", "com.a\ncom.b", "com.a", "com.b");
        is("C2", "blank lines are ignored", "\n\ncom.a\n\n", "com.a");
        is("C3", "CRLF lines", "com.a\r\ncom.b\r\n", "com.a", "com.b");
        for (String junk : new String[] { "nodot", "a/b.c", "a b.c", ".a.b", "a..b", "a.b." })
            is("C4", "the junk line '" + junk + "' is ignored", junk + "\ncom.good\n", "com.good");
        is("C5", "an empty text", "");
        is("C5", "a null text", null);
        is("C6", "1a.b, which the reap lists, is kept", "1a.b\n", "1a.b");
        if (bad != 0) System.exit(1);
    }
}
