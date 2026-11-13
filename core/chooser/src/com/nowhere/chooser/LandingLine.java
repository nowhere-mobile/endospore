package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import java.util.function.Predicate;

/**
 * NWP-20261122-15 (h50 #5, docs/product-decisions.md, 2026-11-01 "twenty-two answers to harvests 50, 51 and 52 ..."):
 * a sign-in whose Auto sweep has apps to fetch tells the user once, so the empty-looking home reads as filling in.
 * NWP-20261126-05 (docs/product-decisions.md, 2026-11-03 "the Auto sweep's landing notice is a checklist card, and
 * Profile Help's cards show where to tap", option D): {@link LandingNoticeActivity} shows it as a checklist card. These
 * are the card's rules and words. Up to {@link #ROWS_MAX} apps: one row per app, in sweep order. From
 * {@code ROWS_MAX + 1}: a headline count, a bar, at most {@link #ROWS_BIG} rows and one "+<n> more" row, so the card
 * keeps one size and never scrolls. The notification stays the record.
 *
 * NWP-20261201-34 (Chester, 2026-11-08; docs/product-decisions.md, 2026-11-09 "eight answers to harvest 62 ...", #3):
 * from {@code ROWS_MAX + 1} the rows are a rolling window: the app that landed last, the app installing and the next
 * app coming back, moving up as each app lands ({@link #rows}). Every row reads ready, installing or coming back
 * ({@link #state}). A card of up to {@code ROWS_MAX} apps keeps one row per app and gains only the installing state.
 *
 * NWP-20261130-09 (Chester, 2026-11-06, "Play store is already in it, but not play service"): the sweep fetches Play
 * services and GSF as deps of the first app that needs them, for minutes and outside its work list, so the card read as
 * if nothing was installing. {@link #cardPkgs} gives them rows ahead of the work list, and {@link Sweep#depLanded} ticks
 * them. The stack still installs in keep-set order; only the card's order differs.
 *
 * ⚠ The words are the mockup's and stay DRAFTS for Chester to correct (the 2026-11-03 entry's inference). So is
 * {@link #INSTALLING} (h62 #3): its mockup goes to Chester in the slice's plan.
 * {@link #CLOSE_AFTER_MS} = 4000 is this slice's inference for the decision's "a few seconds".
 *
 * Once per sign-in: {@link UnarchiveService} keys it on the Android user's serial, which is new at every sign-in and
 * unchanged across a cold-lock resume, and stamps the serial it showed the card for. Pure (java.* only), so
 * test-landing-line-java.sh runs it under javac.
 */
final class LandingLine {
    private LandingLine() {}

    static final String TITLE = "Welcome back";
    static final String READY = "ready";
    static final String COMING = "coming back";
    /** The bare word, with no glyph (h62 #3). */
    static final String INSTALLING = "installing";
    static final String KEEP = "You can keep using the phone.";
    static final String GOT_IT = "Got it";
    /** NWP-20261201-13: the card's Pause and Stop, and Your apps' row while paused. Drafts for Chester to correct. */
    static final String PAUSE = "Pause";
    static final String STOP = "Stop";
    static final String RESUME = "Resume";
    static final String PAUSED_LINE = "Paused. The rest wait until you resume.";
    static final String STOPPED_LINE = "Stopped. The rest install when you tap them.";
    static final String RESUME_ROW = "Resume installing apps";
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

    /** The launcher-less providers: ProfileActivity.GMS_PKG and GSF_PKG. */
    static final String GMS = "com.google.android.gms";
    static final String GSF = "com.google.android.gsf";

    /** The card's rows: GMS, then GSF, each when the sweep will fetch it as a dep and it is not in {@code work}, then
     *  {@code work} in sweep order. It will fetch one when it has no code and is in the deps of an app in {@code work}:
     *  {@code depsOf} and {@code hasCode} are the inputs pendingDeps reads, so the row and the install cannot disagree.
     *  GSF is absent on modern GrapheneOS, so it is in no dep list there and gets no row. First, so that a new card shows
     *  these rows before the first start: rows() keeps a row that installs in the window at any position. */
    static String[] cardPkgs(List<String> work, Function<String, List<String>> depsOf, Predicate<String> hasCode) {
        List<String> out = new ArrayList<>();
        for (String dep : new String[] {GMS, GSF}) {
            if (work.contains(dep) || hasCode.test(dep)) continue;
            for (String p : work) {
                if (depsOf.apply(p).contains(dep)) {
                    out.add(dep);
                    break;
                }
            }
        }
        out.addAll(work);
        return out.toArray(new String[0]);
    }

    /** A provider's name, the words ProfileActivity.keptLabel uses (they equal its installed label); null for any other
     *  package. It has no archived placeholder to read a label from. Only the name source: {@link Sweep#keepLabel} is
     *  what makes every row keep its first name. */
    static String depLabel(String pkg) {
        if (GMS.equals(pkg)) return "Google Play services";
        if (GSF.equals(pkg)) return "Google Services Framework";
        return null;
    }

    /** A row's state words: landed wins over installing. */
    static String state(boolean landed, boolean installing) {
        if (landed) return TICK + " " + READY;
        if (installing) return INSTALLING;
        return CLOCK + " " + COMING;
    }

    /** The headline of the card from ROWS_MAX + 1 apps. */
    static String headline(int landed, int total) {
        if (landed == total) return "All " + total + " apps are back";
        return landed + " of " + total + " apps back";
    }

    /** NWP-20261201-13: the line a paused or stopped card shows; null when it is neither or every app landed, so the card
     *  keeps its normal text and only a card with every app landed says "All <n> apps are back". */
    static String heldLine(boolean paused, boolean stopped, int landed, int total) {
        if (landed == total) return null;
        if (paused) return PAUSED_LINE;
        return stopped ? STOPPED_LINE : null;
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

    /** The indices of the apps the card shows a row for. Up to ROWS_MAX apps: every app, in order. From ROWS_MAX + 1, at
     *  most ROWS_BIG rows in this order: {@code lastLanded} when it is landed, {@code installing} when it is not landed,
     *  then the apps not landed after {@code installing}, then those before it (fewer near the end). -1 means none, and
     *  then the scan starts at the first app. A failed app is not landed, so it sits behind the scan and comes back into
     *  the window near the end. A null array or a length mismatch shows nothing. */
    static int[] rows(String[] pkgs, boolean[] landed, int installing, int lastLanded) {
        if (pkgs == null || landed == null || pkgs.length != landed.length) return new int[0];
        int total = pkgs.length;
        if (!big(total)) {
            int[] all = new int[total];
            for (int i = 0; i < total; i++) all[i] = i;
            return all;
        }
        int[] pick = new int[ROWS_BIG];
        int k = 0;
        if (lastLanded >= 0 && lastLanded < total && landed[lastLanded]) pick[k++] = lastLanded;
        boolean inRange = installing >= 0 && installing < total;
        if (inRange && !landed[installing]) pick[k++] = installing;
        int from = inRange ? installing + 1 : 0;
        for (int j = 0; j < total && k < ROWS_BIG; j++) {
            int i = (from + j) % total;
            if (!landed[i] && i != installing) pick[k++] = i;
        }
        int[] out = new int[k];
        System.arraycopy(pick, 0, out, 0, k);
        return out;
    }

    /** The n of the "+<n> more" row: the apps not {@code landed} beyond the rows. The ready row is landed, so it never
     *  counts. 0 (no row) up to ROWS_MAX apps. */
    static int moreCount(String[] pkgs, boolean[] landed, int installing, int lastLanded) {
        if (pkgs == null || landed == null || pkgs.length != landed.length || !big(pkgs.length)) return 0;
        int left = 0;
        for (int i = 0; i < landed.length; i++) {
            if (!landed[i]) left++;
        }
        for (int r : rows(pkgs, landed, installing, lastLanded)) {
            if (!landed[r]) left--;
        }
        return left;
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
        private static boolean done, paused, stopped;
        private static String[] labels = new String[0];
        /** Rows, -1 for none: the one the sweep works on now, the app to go back to after a dep, the last to land. */
        private static int installing = -1, resume = -1, lastLanded = -1;

        /** A new card sweep over {@code work}, the card's rows ({@link #cardPkgs}); returns its id (never 0). */
        static synchronized long begin(String[] work) {
            id = ++seq;
            pkgs = work == null ? new String[0] : work.clone();
            landed = new boolean[pkgs.length];
            settled = new boolean[pkgs.length];
            labels = new String[pkgs.length];
            done = false;
            paused = false;
            stopped = false;
            installing = resume = lastLanded = -1;
            return id;
        }

        /** The sweep starts an app: its first row with no outcome is the installing row, or none when it has no such
         *  row. Returns true when the installing row changed, so a retry of the same app changes nothing. */
        static synchronized boolean started(long sweep, String pkg) {
            if (sweep != id || done || pkg == null) return false;
            int was = installing;
            installing = -1;
            resume = -1;
            for (int i = 0; i < pkgs.length; i++) {
                if (settled[i] || !pkg.equals(pkgs[i])) continue;
                installing = i;
                break;
            }
            return installing != was;
        }

        /** One app's outcome: the first app of that package with no outcome yet. Only {@code ok} lands it; a failed
         *  app stays "coming back". An app's outcome ends its group, so it clears the installing row, also when a dep
         *  of that app failed and its row is the one installing. */
        static synchronized void outcome(long sweep, String pkg, boolean ok) {
            if (sweep != id || pkg == null) return;
            for (int i = 0; i < pkgs.length; i++) {
                if (settled[i] || !pkg.equals(pkgs[i])) continue;
                settled[i] = true;
                landed[i] = ok;
                if (ok) lastLanded = i;
                if (i == installing || i == resume) installing = resume = -1;
                return;
            }
        }

        /** A dep's code landed: its row ticks, and returns true when that changed a row. It takes no sweep id, because
         *  materializeLocked has none (a tap can land a dep during the sweep). It overrides an earlier failed outcome,
         *  because the code is now there, and {@link #outcome} cannot undo it. A failed dep records nothing: the next
         *  entry point retries the group, so its row stays open for that retry. The installing row goes back to the app
         *  the dep was fetched for. */
        static synchronized boolean depLanded(String pkg) {
            if (pkg == null) return false;
            for (int i = 0; i < pkgs.length; i++) {
                if (!pkg.equals(pkgs[i]) || landed[i]) continue;
                settled[i] = true;
                landed[i] = true;
                lastLanded = i;
                if (i == installing) {
                    installing = resume;
                    resume = -1;
                }
                return true;
            }
            return false;
        }

        /** NWP-20261201-31: a row keeps one name for the life of the card. Returns the row's kept name; the first
         *  non-null {@code read} of the recorded sweep is stored and nothing overwrites it. It lives here, not in the
         *  card, so a recreated card reads the same names. Another sweep or an index out of range stores nothing and
         *  returns {@code read}. RAM only, never logged. The card calls PackageManager first, never under this lock. */
        static synchronized String keepLabel(long sweep, int i, String read) {
            if (sweep == id && sweep != 0 && 0 <= i && i < labels.length) {
                if (labels[i] == null) labels[i] = read;
                return labels[i];
            }
            return read;
        }

        /** A dep's fetch starts: its row is the installing row, and the app it was fetched for waits in {@code resume}.
         *  It takes no sweep id, as {@link #depLanded}. It changes nothing once the sweep ended, so a tap after the end
         *  cannot mark a closing card. Returns true when the installing row changed. */
        static synchronized boolean depStarted(String pkg) {
            if (pkg == null || done) return false;
            for (int i = 0; i < pkgs.length; i++) {
                if (!pkg.equals(pkgs[i]) || landed[i]) continue;
                if (i == installing) return false;
                if (installing >= 0 && !settled[installing]) resume = installing;
                installing = i;
                return true;
            }
            return false;
        }

        /** The sweep ended: no row is installing. {@code lastLanded} stays, so the closing card keeps its last row. */
        static synchronized void end(long sweep) {
            if (sweep != id) return;
            done = true;
            installing = -1;
            resume = -1;
        }

        /** NWP-20261201-13: the sweep held the rest for a resume. Not ended, so the card stays. */
        static synchronized void pause(long sweep) {
            if (sweep != id || sweep == 0) return;
            paused = true;
            stopped = false;
            done = false;
        }

        /** NWP-20261201-13: the sweep stopped after the app in flight. Ended, so the card closes. */
        static synchronized void stop(long sweep) {
            if (sweep != id || sweep == 0) return;
            stopped = true;
            paused = false;
            done = true;
        }

        /** NWP-20261201-13: the sweep goes on from the next app. The resumed pass retries an app that failed before
         *  the pause, so each app not landed takes an outcome again; a landed app keeps its row. */
        static synchronized void resume(long sweep) {
            if (sweep != id || sweep == 0) return;
            paused = false;
            for (int i = 0; i < settled.length; i++) {
                if (!landed[i]) settled[i] = false;
            }
        }

        static synchronized boolean paused(long sweep) {
            return sweep == id && sweep != 0 && paused;
        }

        static synchronized boolean stopped(long sweep) {
            return sweep == id && sweep != 0 && stopped;
        }

        /** A copy of the sweep's landed flags; null when {@code sweep} is not the recorded one. */
        static synchronized boolean[] landed(long sweep) {
            return sweep == id && sweep != 0 ? landed.clone() : null;
        }

        /** The installing row; -1 for none or when {@code sweep} is not the recorded one. */
        static synchronized int installing(long sweep) {
            return sweep == id && sweep != 0 ? installing : -1;
        }

        /** The row that landed last; -1 for none or when {@code sweep} is not the recorded one. */
        static synchronized int lastLanded(long sweep) {
            return sweep == id && sweep != 0 ? lastLanded : -1;
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
