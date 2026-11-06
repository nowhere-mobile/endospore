package com.nowhere.chooser;

/**
 * NWP-20261125-04 (h55 #2 in docs/product-decisions.md, decided 2026-11-03): the line the gate's sign-in screen and
 * Profile show once GrapheneOS full support for this phone has ended. Staging bakes the device's support-end file
 * (editions/endospore/devices/<device>/support-end) to /system/etc/nowhere/support-end; the two screens read it
 * offline and pass its text here with today's UTC date and the build. A missing, unreadable or malformed file shows
 * nothing: a false warning is worse than none, and refusing a release without a good file is build-device.sh's job.
 *
 * The file: '#' lines and blank lines are ignored; exactly two data lines, "last-supported YYYY-MM" (or YYYY-MM-DD)
 * then "source <text>". Past the date means any day of a later month for a month, any later day for a day.
 *
 * The words are drafts for Chester to correct at the device run. The decision names "the agent and chooser reading
 * it"; the line needs no agent read, so none is added. That is an inference, not stated by Chester.
 * Pure (java.lang only), so test-support-end-java.sh compiles it off the build host.
 */
final class SupportEnd {
    private SupportEnd() {}

    private static final String[] MONTHS = {"January", "February", "March", "April", "May", "June", "July",
            "August", "September", "October", "November", "December"};

    /** The last supported date ("YYYY-MM" or "YYYY-MM-DD") from the file's text, or null for null or malformed text. */
    static String lastSupported(String fileText) {
        if (fileText == null) return null;
        String[] data = new String[2];
        int n = 0;
        for (String raw : fileText.split("\n", -1)) {
            String l = raw.trim();
            if (l.isEmpty() || l.startsWith("#")) continue;
            if (n == 2) return null;
            data[n++] = l;
        }
        if (n != 2) return null;
        if (!data[0].startsWith("last-supported ") || !data[1].startsWith("source ")) return null;
        if (data[1].substring("source ".length()).trim().isEmpty()) return null;
        String d = data[0].substring("last-supported ".length());
        return validDate(d) ? d : null;
    }

    /** Whether todayIso (YYYY-MM-DD) is past last; false for any bad input. */
    static boolean ended(String last, String todayIso) {
        if (!validDate(last) || todayIso == null || todayIso.length() != 10 || !validDate(todayIso)) return false;
        if (last.length() == 7) return todayIso.substring(0, 7).compareTo(last) > 0;
        return todayIso.compareTo(last) > 0;
    }

    /** "May 2028" for a month, "31 May 2028" for a day; null for a bad date. */
    static String label(String last) {
        if (!validDate(last)) return null;
        String my = MONTHS[Integer.parseInt(last.substring(5, 7)) - 1] + " " + last.substring(0, 4);
        return last.length() == 7 ? my : Integer.parseInt(last.substring(8, 10)) + " " + my;
    }

    /** The line to show, or null unless the file is good and today is past its date. */
    static String line(String fileText, String todayIso, String build) {
        String last = lastSupported(fileText);
        if (last == null || !ended(last, todayIso)) return null;
        String b = build == null ? "" : build.trim();
        return "This phone no longer gets security updates. GrapheneOS full support for it ended after " + label(last)
                + ". This is " + (b.isEmpty() ? "this build" : "build " + b) + ".";
    }

    private static boolean validDate(String v) {
        if (v == null || (v.length() != 7 && v.length() != 10)) return false;
        for (int i = 0; i < v.length(); i++) {
            char c = v.charAt(i);
            if (i == 4 || i == 7) {
                if (c != '-') return false;
            } else if (c < '0' || c > '9') {
                return false;
            }
        }
        int y = Integer.parseInt(v.substring(0, 4));
        int m = Integer.parseInt(v.substring(5, 7));
        if (m < 1 || m > 12) return false;
        if (v.length() == 7) return true;
        int d = Integer.parseInt(v.substring(8, 10));
        int[] days = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
        int max = days[m - 1] + (m == 2 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 1 : 0);
        return d >= 1 && d <= max;
    }
}
