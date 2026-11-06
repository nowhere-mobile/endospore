package com.nowhere.chooser;

/**
 * Cases for StrengthHint (NWP-20261116-25), compiled with the real ReplyCopy. A strong reply reads "✓ <text>", a weak
 * one "• <text>", and any other reply the bare UNKNOWN text; the words are always ReplyCopy.strength's. Exits 1 on any
 * failure.
 */
public class StrengthHintCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\r", "\\r").replace("\n", "\\n") + "\"";
    }

    private static void one(String reply, String wantLine, boolean wantStrong) {
        String got = StrengthHint.line(reply);
        check("line(" + show(reply) + ") = " + show(wantLine) + ", is " + show(got), wantLine.equals(got));
        check("strong(" + show(reply) + ") = " + wantStrong, StrengthHint.strong(reply) == wantStrong);
        String words = ReplyCopy.strength(reply).text;
        check("line(" + show(reply) + ") ends with ReplyCopy's words " + show(words),
                got != null && got.endsWith(words));
    }

    public static void main(String[] args) {
        String unknown = ReplyCopy.strength("").text;
        check("the UNKNOWN text is set", unknown != null && !unknown.isEmpty());
        check("the UNKNOWN text has no prefix", !unknown.startsWith("✓ ") && !unknown.startsWith("• "));
        one("OK\n", "✓ strong", true);
        one("WEAK use at least 12 characters\n", "• use at least 12 characters", false);
        one("WEAK\n", "• too weak", false);
        one("", unknown, false);
        one(null, unknown, false);
        one("OKAY", unknown, false);
        if (failures > 0) { System.err.println("  " + failures + " case(s) failed"); System.exit(1); }
        System.out.println("  cases ok");
    }
}
