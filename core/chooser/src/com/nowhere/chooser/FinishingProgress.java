package com.nowhere.chooser;

/** The gate's "Finishing up" progress while the Installed apps install (pure Java, no android.*, so a javac suite
 *  runs it).
 *
 *  NWP-20261208-25 ('"Finishing up…" sits at 95% with no per-app progress while every Installed app installs and the
 *  permissions are re-granted'; words approved by Chester, 2026-11-17, NWP-20261116-48): under the bar the gate shows
 *  "Installing <app> (<i> of <n>)", the bar moves through the 95-100% band as the installs finish, and the status
 *  line reads "Finishing up… — <N>%".
 *
 *  D7 (NWP-20260823-04): 100 is painted only immediately before the switch, so pct stops at 99. */
final class FinishingProgress {
    private FinishingProgress() {}

    /** The bar after `done` of `n` installs: 95 when nothing has finished (or nothing is listed), 99 when all have. */
    static int pct(int done, int n) {
        if (n <= 0) return 95;
        int d = done < 0 ? 0 : (done > n ? n : done);
        return 95 + (4 * d) / n;
    }

    static String status(int pct) {
        return "Finishing up… — " + pct + "%";
    }

    static String line(String app, int i, int n) {
        return "Installing " + app + " (" + i + " of " + n + ")";
    }
}
