package com.nowhere.chooser;

/** NWP-20261114-28: the cases for DeviceName, run by core/vendor-common/bin/test-device-name-java.sh. */
public final class DeviceNameCases {
    private static int fails = 0;

    private static void eq(String name, String got, String want) {
        if (want.equals(got)) System.out.println("  ok   " + name);
        else { System.out.println("  FAIL " + name + ": got " + show(got) + ", want " + show(want)); fails++; }
    }

    private static void is(String name, boolean got, boolean want) {
        if (got == want) System.out.println("  ok   " + name);
        else { System.out.println("  FAIL " + name + ": got " + got + ", want " + want); fails++; }
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\n", "\\n").replace("\t", "\\t") + "\"";
    }

    private static String rep(String s, int n) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < n; i++) b.append(s);
        return b.toString();
    }

    /** cap as an append at the end of dest; the result as a String, or null for "take it whole". */
    private static String capped(String dest, String source) {
        CharSequence c = DeviceName.cap(source, 0, source.length(), dest, dest.length(), dest.length());
        return c == null ? null : c.toString();
    }

    public static void main(String[] args) {
        final String phone = new String(Character.toChars(0x1F4F1)); // two UTF-16 units, one code point

        eq("seed(\"Pixel 7a\")", DeviceName.seed("Pixel 7a"), "Pixel 7a");
        eq("seed trims the model", DeviceName.seed("  Pixel 7a  "), "Pixel 7a");
        eq("seed(\"  \") is empty", DeviceName.seed("  "), "");
        eq("seed(null) is empty", DeviceName.seed(null), "");
        eq("seed of a 41-char model is empty", DeviceName.seed(rep("a", 41)), "");
        eq("seed of a 40-char model is the model", DeviceName.seed(rep("a", 40)), rep("a", 40));
        eq("seed of a model with a newline is empty", DeviceName.seed("Pixel\n7a"), "");

        is("valid(\"Pixel 7a\")", DeviceName.valid("Pixel 7a"), true);
        is("valid(\"\") is false", DeviceName.valid(""), false);
        is("valid(\"   \") is false", DeviceName.valid("   "), false);
        is("valid(null) is false", DeviceName.valid(null), false);
        is("valid with a newline is false", DeviceName.valid("a\nb"), false);
        is("valid with a tab is false", DeviceName.valid("a\tb"), false);
        is("valid with a CR is false", DeviceName.valid("a\rb"), false);
        is("valid with a BEL is false", DeviceName.valid("\u0007x"), false);
        is("valid with 40 code points", DeviceName.valid(rep("a", 40)), true);
        is("valid with 41 code points is false", DeviceName.valid(rep("a", 41)), false);
        is("valid counts code points: 40 supplementary", DeviceName.valid(rep(phone, 40)), true);
        is("valid counts code points: 41 supplementary is false", DeviceName.valid(rep(phone, 41)), false);
        is("valid trims first", DeviceName.valid("  x  "), true);
        is("valid with a right single quote", DeviceName.valid("Chester\u2019s phone"), true);
        is("valid with a zero width space is false", DeviceName.valid("a\u200Bb"), false);
        is("valid with a lone high surrogate is false", DeviceName.valid("a\uD83Db"), false);

        // RF-002: the trim is Go's strings.TrimSpace, not Java's whitespace categories
        is("valid with a trailing U+001C is false (a control char, not space)", DeviceName.valid("Pixel\u001c"), false);
        is("valid with a leading U+001F is false", DeviceName.valid("\u001fPixel"), false);
        eq("seed trims a trailing U+0085", DeviceName.seed("Pixel\u0085"), "Pixel");
        eq("seed trims a no-break space", DeviceName.seed("\u00a0Pixel 7a\u00a0"), "Pixel 7a");
        eq("seed trims an em space and U+3000", DeviceName.seed("\u2003Pixel\u3000"), "Pixel");
        eq("seed trims a vertical tab and a form feed", DeviceName.seed("\u000bPixel\f"), "Pixel");
        eq("trim keeps U+001C", DeviceName.trim("Pixel\u001c"), "Pixel\u001c");
        is("space: U+0085 and U+00A0", DeviceName.space(0x85) && DeviceName.space(0xA0), true);
        is("space: not U+001C..U+001F", DeviceName.space(0x1C) || DeviceName.space(0x1D) || DeviceName.space(0x1E)
                || DeviceName.space(0x1F), false);
        is("space: not a zero width space", DeviceName.space(0x200B), false);

        // RF-001: the field's cap counts code points, as InputFilter.filter does it
        is("cap takes 40 supplementary whole", capped("", rep(phone, 40)) == null, true);
        eq("cap keeps 40 of 41 supplementary", show(capped("", rep(phone, 41))), show(rep(phone, 40)));
        eq("cap keeps 40 of 41 ascii", show(capped("", rep("a", 41))), show(rep("a", 40)));
        is("cap takes 40 ascii whole", capped("", rep("a", 40)) == null, true);
        eq("cap: a full field takes nothing", show(capped(rep(phone, 40), "x")), show(""));
        eq("cap: 39 in the field, one more fits", show(capped(rep(phone, 39), phone + phone)), show(phone));
        is("cap: replacing a selection frees its room",
                DeviceName.cap(phone, 0, phone.length(), rep(phone, 40), 0, phone.length()) == null, true);
        eq("cap never splits a surrogate pair", show(capped(rep("a", 39), phone + "b")), show(phone));

        eq("request shape", DeviceName.request("Pixel 7a"), "SET-DEVICE-LABEL\nPixel 7a\n");
        eq("request trims the label", DeviceName.request("  Pixel 7a "), "SET-DEVICE-LABEL\nPixel 7a\n");
        String r = DeviceName.request("x");
        is("request ends with a newline", r.endsWith("\n"), true);
        is("request has exactly two newlines", r.length() - r.replace("\n", "").length() == 2, true);

        is("MAX is 40", DeviceName.MAX == 40, true);
        String l = DeviceName.INVALID_LINE;
        is("INVALID_LINE is one non-empty line", !l.isEmpty() && l.indexOf('\n') < 0, true);
        is("INVALID_LINE offers no way past", !l.contains("Skip") && !l.contains("Not now") && !l.contains("no recovery"), true);

        if (fails > 0) { System.out.println("FAIL " + fails + " case(s)"); System.exit(1); }
        System.out.println("  cases ok");
    }
}
