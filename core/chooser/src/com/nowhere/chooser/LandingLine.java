package com.nowhere.chooser;

/**
 * NWP-20261122-15 (h50 #5, docs/product-decisions.md, 2026-11-01 "twenty-two answers to harvests 50, 51 and 52 ..."):
 * a sign-in whose Auto sweep has apps to fetch tells the user once, so the empty-looking home reads as filling in.
 * NWP-20261126-05 (docs/product-decisions.md, 2026-11-03 "the Auto sweep's landing notice is a checklist card, and
 * Profile Help's cards show where to tap", option D): {@link LandingNoticeActivity} shows it as a checklist card. These
 * are the card's rules and words. Up to {@link #ROWS_MAX} apps: one row per app, in sweep order. From
 * {@code ROWS_MAX + 1}: a headline count, a bar, at most {@link #ROWS_BIG} rows and one "+<n> more" row, so the card
 * keeps one size and never scrolls. The notification stays the record.
 *
 * ⚠ The words are the mockup's and stay DRAFTS for Chester to correct (the 2026-11-03 entry's inference).
 * {@link #CLOSE_AFTER_MS} = 4000 is this slice's inference for the decision's "a few seconds".
 *
 * Once per sign-in: {@link UnarchiveService} keys it on the Android user's serial, which is new at every sign-in and
 * unchanged across a cold-lock resume, and stamps the serial it showed the card for. Pure (java.lang only), so
 * test-landing-line-java.sh runs it under javac.
 */
final class LandingLine {
    private LandingLine() {}

    static final String TITLE = "Welcome back";
    static final String READY = "ready";
    static final String COMING = "coming back";
    static final String KEEP = "You can keep using the phone.";
    static final String GOT_IT = "Got it";
    /** The glyphs beside READY and COMING (the mockup's tick and clock). Text, not emoji, so they take the text colour. */
    static final String TICK = "✓";
    static final String CLOCK = "◷";

    /** Up to this many apps, the card shows one row per app. */
    static final int ROWS_MAX = 4;
    /** From ROWS_MAX + 1 apps, the card shows at most this many app rows. */
    static final int ROWS_BIG = 3;
    /** The card closes this long after the sweep ends (an inference for "a few seconds"). */
    static final long CLOSE_AFTER_MS = 4000L;
    /** The card's share of the screen width. */
    static final float WIDTH_SHARE = 0.85f;

    /** ProfileActivity opens Your apps when its intent carries EXTRA_OPEN = OPEN_YOUR_APPS ("+<n> more"). */
    static final String EXTRA_OPEN = "nowhere.profile.open";
    static final String OPEN_YOUR_APPS = "your-apps";

    /** The headline of the card from ROWS_MAX + 1 apps. */
    static String headline(int landed, int total) {
        if (landed == total) return "All " + total + " apps are back";
        return landed + " of " + total + " apps back";
    }

    /** The last row of the card from ROWS_MAX + 1 apps. */
    static String more(int n) {
        return "+" + n + " more";
    }

    /** The card's window width for a screen {@code screenPx} wide. */
    static int widthPx(int screenPx) {
        return Math.round(screenPx * WIDTH_SHARE);
    }

    /** True when the card shows the count, the bar and at most ROWS_BIG rows. */
    static boolean big(int total) {
        return total > ROWS_MAX;
    }

    /** The indices of the apps the card shows a row for. Up to ROWS_MAX apps: every app, in order. From ROWS_MAX + 1:
     *  the first ROWS_BIG apps not {@code landed}, in sweep order (fewer near the end). A null array or a length
     *  mismatch shows nothing. */
    static int[] rows(String[] pkgs, boolean[] landed) {
        if (pkgs == null || landed == null || pkgs.length != landed.length) return new int[0];
        int total = pkgs.length;
        if (!big(total)) {
            int[] all = new int[total];
            for (int i = 0; i < total; i++) all[i] = i;
            return all;
        }
        int[] pick = new int[ROWS_BIG];
        int k = 0;
        for (int i = 0; i < total && k < ROWS_BIG; i++) {
            if (!landed[i]) pick[k++] = i;
        }
        int[] out = new int[k];
        System.arraycopy(pick, 0, out, 0, k);
        return out;
    }

    /** The n of the "+<n> more" row: the apps not {@code landed} beyond the rows. 0 (no row) up to ROWS_MAX apps. */
    static int moreCount(String[] pkgs, boolean[] landed) {
        if (pkgs == null || landed == null || pkgs.length != landed.length || !big(pkgs.length)) return 0;
        int left = 0;
        for (int i = 0; i < landed.length; i++) {
            if (!landed[i]) left++;
        }
        return left - rows(pkgs, landed).length;
    }

    /**
     * The card's sweep, held in this process (RAM only, never on disk) so the card cannot miss an outcome or the end.
     * The service starts the card asynchronously and goes on sweeping, and a recreated card has a receiver gap, so a
     * broadcast alone can be lost. sweepAuto records here first and broadcasts after; the card registers its receiver
     * first and reads here after, and reads again on every broadcast. Only the sweep that showed the card is recorded:
     * {@link #begin} gives its id, and a call with another id changes nothing.
     */
    static final class Sweep {
        private Sweep() {}

        private static long seq, id;
        private static String[] pkgs = new String[0];
        private static boolean[] landed = new boolean[0], settled = new boolean[0];
        private static boolean done;

        /** A new card sweep over {@code work}, in sweep order; returns its id (never 0). */
        static synchronized long begin(String[] work) {
            id = ++seq;
            pkgs = work == null ? new String[0] : work.clone();
            landed = new boolean[pkgs.length];
            settled = new boolean[pkgs.length];
            done = false;
            return id;
        }

        /** One app's outcome: the first app of that package with no outcome yet. Only {@code ok} lands it; a failed
         *  app stays "coming back". */
        static synchronized void outcome(long sweep, String pkg, boolean ok) {
            if (sweep != id || pkg == null) return;
            for (int i = 0; i < pkgs.length; i++) {
                if (settled[i] || !pkg.equals(pkgs[i])) continue;
                settled[i] = true;
                landed[i] = ok;
                return;
            }
        }

        /** The sweep ended. */
        static synchronized void end(long sweep) {
            if (sweep == id) done = true;
        }

        /** A copy of the sweep's landed flags; null when {@code sweep} is not the recorded one. */
        static synchronized boolean[] landed(long sweep) {
            return sweep == id && sweep != 0 ? landed.clone() : null;
        }

        /** True when the sweep ended. A sweep that is not the recorded one (an id 0, a newer card sweep, a process
         *  that restarted) reads as ended, so its card closes and never waits forever. */
        static synchronized boolean done(long sweep) {
            return sweep == 0 || sweep != id || done;
        }
    }

    /** Show the card? Only on the switch-landing sweep ({@code landing}), with apps to fetch, for a known sign-in
     *  ({@code thisSignIn}, the user serial; null shows nothing) the card was not yet shown for ({@code shownFor}, the
     *  stamp). */
    static boolean show(boolean landing, int toFetch, String shownFor, String thisSignIn) {
        return landing && toFetch > 0 && thisSignIn != null && !thisSignIn.equals(shownFor);
    }
}
