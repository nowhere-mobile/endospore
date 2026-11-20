package com.nowhere.chooser;

/**
 * NWP-20261207-12 (Q106 S6b, half 2; docs/media-after-gate.md §6, §8 row S6, §10 O3): the media half of the landing
 * line -- the rule and the words. Pure (java.* only), so test-media-landing-java.sh compiles it with its cases alone.
 *
 * Decision (docs/product-decisions.md), 2026-11-02 "user media restored after the gate needs no regroup and no
 * re-upload, ... says so on the landing line only for a large set, ...", O3: the landing line mentions media only for a
 * large set, over 200 files or 50 MB; a smaller set shows only the notification (S6a). MediaLandingNoticeActivity.check
 * reads the set from mediad's RESTORING line and puts {@link #IN_CARD} in the Auto sweep's card when one is open, else
 * shows {@link #ALONE} in a one-line card of its own. Both close with {@link LandingLine#GOT_IT}.
 *
 * ⚠ THE WORDS ARE DRAFTS. §6 gives only an example of the merged words, and h50 #5's line has since become the
 * checklist card (2026-11-03, option D), so neither sentence nor its place is decided verbatim. Chester approved the
 * words in advance on 2026-11-15; he reviews the mockup in 0.5.58 and corrects the words on the handset (O3).
 *
 * Inferences this slice makes: 50 MB is {@link #BYTES_OVER} = 50 MiB, the unit the notification's humanBytes shows;
 * "over" is strictly greater, for files and for bytes; the set is the FIRST valid RESTORING line's total bytes and
 * files left, read within {@link #WAIT_MS} of the switch-landing.
 *
 * Residuals:
 * 1. An apps card that begins after the alone card was started gives two cards. The sentence is in the alone card
 *    only, because the alone arm does not set the record. Each card closes with Got it.
 * 2. A user who closes the apps card with Got it before the media decision, while its sweep still runs, does not see
 *    the sentence: the sweep is open, so it goes to a card that is gone. A missed line is the safe side.
 * 3. The record is process-static. A card recreated in a new chooser process does not show the sentence.
 * 4. The apps card closes LandingLine.CLOSE_AFTER_MS after its sweep ends; the sentence goes with it. The
 *    notification stays.
 * 5. A RESTORING line that first appears WAIT_MS or more after the switch-landing is not read, and a reply that
 *    arrives at or after that deadline is discarded ({@link #firstRestoring}). The notification still shows the
 *    progress.
 */
final class MediaLanding {
    private MediaLanding() {}

    /** O3: more files than this is a large set. */
    static final int FILES_OVER = 200;
    /** O3: more bytes than this is a large set. 50 MiB, the unit the notification shows. */
    static final long BYTES_OVER = 50L * 1024 * 1024;
    /** How long check() waits for the first RESTORING line after the switch-landing, and how often it asks. */
    static final long WAIT_MS = 30000;
    static final long STEP_MS = 2000;
    /** The longest one GET-MEDIA-STATUS round trip may take; firstRestoring also bounds it by the time left. */
    static final long ASK_MS = 5000;

    /** DRAFT (§6's example): the sentence in the Auto sweep's card. */
    static final String IN_CARD = "Your photos and files are coming back too. Progress shows in your notifications.";
    /** DRAFT (§6's example): the one-line card when no Auto sweep card is open. */
    static final String ALONE = "Your photos and files are coming back in the background. You can use the phone now; progress shows in your notifications.";

    /** One GET-MEDIA-STATUS round trip: MediaStatus.restoring of the reply, or null. {@code capMs} bounds its read. */
    interface Ask {
        long[] restoring(long capMs);
    }

    /** The clock and the sleep check() waits with; the cases give a simulated one. */
    interface Clock {
        long now();
        void sleep(long ms) throws InterruptedException;
    }

    /**
     * The first RESTORING line read within {@link #WAIT_MS} of the call, or null. It asks every {@link #STEP_MS}. It
     * checks the deadline before each ask and after each reply, and it discards a reply that arrives at or after the
     * deadline. Each ask and each sleep is bounded by the time left, so no ask starts and no reply counts outside the
     * window. An interrupt ends the wait with null.
     */
    static long[] firstRestoring(Ask ask, Clock clock) {
        long end = clock.now() + WAIT_MS;
        while (true) {
            long left = end - clock.now();
            if (left <= 0) return null;
            long[] r = ask.restoring(Math.min(ASK_MS, left));
            left = end - clock.now();
            if (left <= 0) return null;
            if (r != null) return r;
            try {
                clock.sleep(Math.min(STEP_MS, left));
            } catch (InterruptedException e) {
                return null;
            }
        }
    }

    /** The process-static record: the serial whose media sentence went to the apps card. RAM only, never logged. */
    private static volatile String shownFor;

    /** A large set: {@code r} is MediaStatus.restoring's {done, total bytes, files left}. Null is not large. */
    static boolean large(long[] r) {
        if (r == null || r.length != 3) return false;
        return r[2] > FILES_OVER || r[1] > BYTES_OVER;
    }

    /** Show the line: the set is large and this sign-in (its user serial) has not shown it yet (the stamp). */
    static boolean show(boolean large, String stamp, String serial) {
        return large && serial != null && !serial.equals(stamp);
    }

    /** The media sentence for this sign-in went to the apps card. Only check()'s card arm sets it. */
    static void mark(String serial) {
        shownFor = serial;
    }

    /** True when the media sentence of the sign-in {@code serial} went to the apps card. */
    static boolean shownFor(String serial) {
        return serial != null && serial.equals(shownFor);
    }
}
