package com.nowhere.chooser;

import java.util.Arrays;

/** NWP-20261122-14: what the add's notification shows for one FETCH-APP PROGRESS line (InstallProgress's isProgress,
 *  parse, text and bar), compiled with InstallProgress ALONE (java.* only). */
public class InstallProgressCases {
    static final long MIB = 1024L * 1024L;
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static void parsesTo(String line, long got, long total) {
        long[] p = InstallProgress.parse(line);
        check("parse " + line, p != null && p[0] == got && p[1] == total, Arrays.toString(p));
    }

    static void refused(String line) {
        long[] p = InstallProgress.parse(line);
        check("parse refuses " + line, p == null, Arrays.toString(p));
    }

    public static void main(String[] a) {
        parsesTo("PROGRESS 0 100", 0, 100);
        parsesTo("PROGRESS 5 0", 5, 0);
        parsesTo("PROGRESS 48234496 48234496", 48234496, 48234496);
        refused("PROGRESS");
        refused("PROGRESS 1");
        refused("PROGRESS 1 2 3");
        refused("PROGRESS -1 2");
        refused("PROGRESS +1 2");
        refused("PROGRESS a 2");
        refused("PROGRESS 1  2");
        refused("PROGRESS 99999999999999999999 1");
        refused("PROGRESSX 1 2");
        refused(null);

        check("isProgress PROGRESS x", InstallProgress.isProgress("PROGRESS x"), "false");
        check("isProgress a bare PROGRESS", InstallProgress.isProgress("PROGRESS"), "false");
        check("isProgress OK pkg sig is a verdict", !InstallProgress.isProgress("OK org.example 0123"), "true");
        check("isProgress ERR-UNVERIFIED is a verdict", !InstallProgress.isProgress("ERR-UNVERIFIED"), "true");
        check("isProgress PROGRESSX 1 2 is a verdict", !InstallProgress.isProgress("PROGRESSX 1 2"), "true");
        check("isProgress null is a verdict", !InstallProgress.isProgress(null), "true");

        String t = InstallProgress.text(12 * MIB, 46 * MIB);
        check("text 12 MiB of 46 MiB is fmtB's \"12 MB of 46 MB\"", "12 MB of 46 MB".equals(t), t);
        t = InstallProgress.text(5 * MIB + MIB / 2, 46 * MIB);
        check("text 5.5 MiB of 46 MiB is \"5.5 MB of 46 MB\"", "5.5 MB of 46 MB".equals(t), t);
        t = InstallProgress.text(0, 46 * MIB);
        check("text the start line is fmtB's floor \"1 KB of 46 MB\"", "1 KB of 46 MB".equals(t), t);
        t = InstallProgress.text(3L << 30, 5L << 30);
        check("text 3 GiB of 5 GiB is \"3.0 GB of 5.0 GB\"", "3.0 GB of 5.0 GB".equals(t), t);
        t = InstallProgress.text(50 * MIB, 46 * MIB);
        check("text got above total shows total", "46 MB of 46 MB".equals(t), t);
        t = InstallProgress.text(12 * MIB, 0);
        check("text total 0 is null (keep the indeterminate text)", t == null, t);

        int[] b = InstallProgress.bar(5, 10);
        check("bar 5 of 10 is {10, 5}", b != null && b[0] == 10 && b[1] == 5, Arrays.toString(b));
        b = InstallProgress.bar(12 * MIB, 0);
        check("bar total 0 is null (indeterminate)", b == null, Arrays.toString(b));
        b = InstallProgress.bar(3L << 32, 4L << 32);
        check("bar above Integer.MAX_VALUE is scaled into an int, value <= max, ratio 0.75",
                b != null && b[0] > 0 && b[1] <= b[0] && Math.abs((double) b[1] / b[0] - 0.75) < 0.01,
                Arrays.toString(b));
        b = InstallProgress.bar(Long.MAX_VALUE, Long.MAX_VALUE);
        check("bar Long.MAX_VALUE of Long.MAX_VALUE is full", b != null && b[0] > 0 && b[1] == b[0],
                Arrays.toString(b));
        b = InstallProgress.bar(Integer.MAX_VALUE, Integer.MAX_VALUE);
        check("bar Integer.MAX_VALUE of Integer.MAX_VALUE is full", b != null && b[0] > 0 && b[1] == b[0],
                Arrays.toString(b));
        b = InstallProgress.bar(20, 10);
        check("bar got above total is full", b != null && b[1] == b[0], Arrays.toString(b));

        System.out.println((fails == 0 ? "PASS" : "FAILED") + ": " + (runs - fails) + "/" + runs + " cases");
        if (fails != 0) System.exit(1);
    }
}
