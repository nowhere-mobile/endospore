package com.nowhere.chooser;

/** NWP-20261125-04: SupportEnd's parser, its date rule either side of the date, its label and its line, run by
 *  test-support-end-java.sh. */
public final class SupportEndCases {
    private static int failed = 0;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failed++;
    }

    private static boolean eq(String a, String b) {
        return a == null ? b == null : a.equals(b);
    }

    public static void main(String[] args) {
        String month = "last-supported 2028-05\nsource https://example.invalid/pixel-updates\n";
        String day = "last-supported 2028-05-31\nsource https://example.invalid/pixel-updates\n";

        // lastSupported
        check(eq(SupportEnd.lastSupported(month), "2028-05"), "a good month file gives 2028-05");
        check(eq(SupportEnd.lastSupported(day), "2028-05-31"), "a good day file gives 2028-05-31");
        check(eq(SupportEnd.lastSupported("# the end of full support\n\n  # indented comment\nlast-supported 2028-05\n"
                + "# between\nsource Google's Pixel update page\n# after\n\n"), "2028-05"),
                "comments and blank lines before, between and after are skipped");
        check(eq(SupportEnd.lastSupported("last-supported 2028-05\r\nsource x\r\n"), "2028-05"), "CRLF line ends parse");
        check(SupportEnd.lastSupported("last-supported 2028-05\n") == null, "malformed: the source line missing");
        check(SupportEnd.lastSupported("source x\nlast-supported 2028-05\n") == null, "malformed: the two lines swapped");
        check(SupportEnd.lastSupported(month + "extra 1\n") == null, "malformed: a third data line");
        check(SupportEnd.lastSupported("last-supported 2028-13\nsource x\n") == null, "malformed: month 13");
        check(SupportEnd.lastSupported("last-supported 2028-02-30\nsource x\n") == null, "malformed: 30 February");
        check(SupportEnd.lastSupported("last-supported 2028-5\nsource x\n") == null, "malformed: a one-digit month");
        check(SupportEnd.lastSupported("last-supported 2028-05 soon\nsource x\n") == null, "malformed: trailing text");
        check(SupportEnd.lastSupported("last-supported 2028-05\nsource \n") == null, "malformed: an empty source");
        check(SupportEnd.lastSupported("end 2028-05\nsource x\n") == null, "malformed: an unknown keyword");
        check(SupportEnd.lastSupported("") == null, "malformed: an empty file");
        check(SupportEnd.lastSupported(null) == null, "null gives null");
        check(eq(SupportEnd.lastSupported("last-supported 2028-02-29\nsource x\n"), "2028-02-29"),
                "29 February of a leap year parses");

        // ended, either side of the date
        check(!SupportEnd.ended("2028-05", "2028-05-31"), "month form: the last day of the month is not past");
        check(SupportEnd.ended("2028-05", "2028-06-01"), "month form: the first day of the next month is past");
        check(!SupportEnd.ended("2028-05", "2028-05-01"), "month form: the first day of the month is not past");
        check(!SupportEnd.ended("2028-05", "2027-12-31"), "month form: an earlier year is not past");
        check(SupportEnd.ended("2028-05", "2029-01-01"), "month form: a later year is past");
        check(!SupportEnd.ended("2028-05-15", "2028-05-15"), "day form: the day itself is not past");
        check(SupportEnd.ended("2028-05-15", "2028-05-16"), "day form: the next day is past");
        check(!SupportEnd.ended("2028-05-15", "2028-05-14"), "day form: the day before is not past");
        check(!SupportEnd.ended("2028-05", "garbage"), "a bad today is never past");
        check(!SupportEnd.ended("2028-05", "2029-01"), "a month for today is never past");
        check(!SupportEnd.ended(null, "2029-01-01"), "a null date is never past");

        // label
        check(eq(SupportEnd.label("2028-05"), "May 2028"), "label: 2028-05 reads May 2028");
        check(eq(SupportEnd.label("2028-05-31"), "31 May 2028"), "label: 2028-05-31 reads 31 May 2028");
        check(eq(SupportEnd.label("2028-01-05"), "5 January 2028"), "label: the day has no leading zero");
        check(eq(SupportEnd.label("2030-12"), "December 2030"), "label: December");
        check(SupportEnd.label("2028-13") == null, "label: a bad date gives null");

        // line
        check(SupportEnd.line(month, "2028-05-31", "2028053100") == null, "line: before the date, no line");
        String l = SupportEnd.line(month, "2028-06-01", "2028053100");
        check(eq(l, "This phone no longer gets security updates. GrapheneOS full support for it ended after May 2028."
                + " This is build 2028053100."), "line: past the date, the exact sentence");
        check(l != null && l.contains("2028053100") && l.contains("May 2028"), "line: names the build AND the date");
        check(eq(SupportEnd.line(day, "2028-06-01", " 2028053100\n"), "This phone no longer gets security updates."
                + " GrapheneOS full support for it ended after 31 May 2028. This is build 2028053100."),
                "line: the day form, the build trimmed");
        String blank = "This phone no longer gets security updates. GrapheneOS full support for it ended after May 2028."
                + " This is this build.";
        check(eq(SupportEnd.line(month, "2028-06-01", "  "), blank), "line: a blank build reads this build");
        check(eq(SupportEnd.line(month, "2028-06-01", null), blank), "line: a null build reads this build");
        check(SupportEnd.line("last-supported 2028-05\n", "2099-01-01", "1") == null, "line: a malformed file, no line");
        check(SupportEnd.line(null, "2099-01-01", "1") == null, "line: no file, no line");

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases pass");
    }
}
