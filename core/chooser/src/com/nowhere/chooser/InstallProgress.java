package com.nowhere.chooser;

/**
 * NWP-20261122-14 (h51 #3, decided 2026-11-01): the add's notification gets a real bar and "12 MB of 46 MB", as a
 * tapped app's does. StoreService.getApp asks FETCH-APP with the `progress` opt-in, and the daemon answers with
 * "PROGRESS &lt;got&gt; &lt;total&gt;" lines before its one verdict line. This class reads one such line and says what
 * the notification shows for it.
 *
 * Pure (java.* only), so core/vendor-common/bin/test-install-progress-java.sh compiles and runs it without the
 * Android SDK.
 */
final class InstallProgress {
    private InstallProgress() {}

    /** True when the line's first space-separated token is exactly PROGRESS. Any other line is the verdict. */
    static boolean isProgress(String line) {
        if (line == null) return false;
        int sp = line.indexOf(' ');
        return (sp < 0 ? line : line.substring(0, sp)).equals("PROGRESS");
    }

    /** {got, total} for exactly "PROGRESS &lt;got&gt; &lt;total&gt;" with two non-negative decimal counts, else null.
     *  A malformed line is skipped by the reader, never shown. */
    static long[] parse(String line) {
        if (line == null) return null;
        String[] f = line.split(" ", -1);
        if (f.length != 3 || !f[0].equals("PROGRESS")) return null;
        long got = count(f[1]), total = count(f[2]);
        if (got < 0 || total < 0) return null;
        return new long[] { got, total };
    }

    private static long count(String s) {
        if (s.isEmpty() || s.length() > 19) return -1;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') return -1;
        }
        try {
            return Long.parseLong(s);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** The notification's text, "&lt;got&gt; of &lt;total&gt;" with fmtB's rule, or null when the entry states no
     *  size (total 0): the caller then keeps its indeterminate text. got never shows above total. */
    static String text(long got, long total) {
        if (total <= 0) return null;
        return fmtB(Math.min(got, total)) + " of " + fmtB(total);
    }

    /** {max, value} for Notification.Builder.setProgress, or null when total is 0 (stay indeterminate). Byte counts
     *  above Integer.MAX_VALUE are divided down so both fit an int; value never exceeds max. */
    static int[] bar(long got, long total) {
        if (total <= 0) return null;
        long d = total / Integer.MAX_VALUE + 1;
        long g = Math.min(Math.max(got, 0), total);
        return new int[] { (int) (total / d), (int) (g / d) };
    }

    /** UnarchiveService.fmtB, copied verbatim so a tapped app and an added one read the same figures (UnarchiveService
     *  keeps its own copy free-standing). test-install-progress-java.sh holds the two copies together. */
    static String fmtB(long b) {
        if (b < 0) b = 0;
        if (b < 1024 * 1024) return Math.max(1, b / 1024) + " KB";
        double mb = b / (1024.0 * 1024.0);
        if (Math.round(mb * 10) < 100) return String.format(java.util.Locale.US, "%.1f MB", mb);
        if (Math.round(mb) < 1024) return Math.round(mb) + " MB";
        return String.format(java.util.Locale.US, "%.1f GB", mb / 1024.0);
    }
}
