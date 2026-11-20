package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.function.LongPredicate;

/**
 * NWP-20261208-24 (backlog "Up to four separate pop-ups can land together right after sign-in: the Auto sweep card, the
 * last-save notice, the passphrase-change skip notice and the Google Play setup card"; design approved by Chester
 * 2026-11-17, NWP-20261116-48): one sign-in's landing card and the notices that wait on it. Pure, java.* only.
 *
 * sweepAuto reports its card decision ({@link #decided}: the card's sweep id, 0 for no card; the first call wins). The
 * card reports itself shown at onCreate and gone at a finishing onDestroy, by sweep id. sweepAuto starts the card BEFORE
 * it calls decided(card), so a report can come first: both are kept by id and matched against the decided card when
 * read, never dropped for want of a decision.
 *
 * The last-save line and the skip notice ask {@link #place}: CARD while the decided card is up and its sweep runs, and
 * they fold into it as an amber line ({@link #addLine}, then a package-local broadcast); otherwise they wait for the
 * card to close and show alone, as before. The Google Play setup card waits the same way and never folds.
 *
 * {@link #DECIDE_MS} and {@link #SHOW_MS} are inferences, not decided numbers. DECIDE_MS: sweepAuto decides within a few
 * seconds of the switch, so 30 s only bounds a sweep that never gets there (the notices then show alone, as before).
 * SHOW_MS: a card whose start failed never reports shown, so 10 s after the decision the queue stops waiting for it.
 * A card that did report shown is waited for without a bound: the approved design shows the Play card only after it.
 *
 * RAM only, never logged: the chooser process lives in the session's Android user, so a new sign-in is a new queue.
 */
final class LandingQueue {
    /** How long a notice waits for sweepAuto's card decision. An inference (see the class comment). */
    static final long DECIDE_MS = 30000;
    /** How long after the decision a card that never reported shown still holds the queue. An inference. */
    static final long SHOW_MS = 10000;

    /** CARD: fold into the open landing card. ALONE: show the notice's own card, as before. */
    enum Place { CARD, ALONE }

    private static boolean decided;
    /** The decided card's sweep id; 0 = no card. */
    private static long card;
    /** When the decision came, in ms of System.nanoTime. */
    private static long decidedAt;
    /** Every sweep id a card reported shown or gone, with or without a decision (0 is never kept). */
    private static final Set<Long> SHOWN = new HashSet<>();
    private static final Set<Long> GONE = new HashSet<>();
    /** The folded words, in the order they came. */
    private static final List<String> LINES = new ArrayList<>();
    /** The skip notices' times, each handed out once by takeSkipTimes. */
    private static final List<Long> SKIP = new ArrayList<>();
    private static int skipTaken;

    private LandingQueue() {}

    private static long now() {
        return System.nanoTime() / 1000000L;
    }

    /** sweepAuto's card decision: the card's sweep id, 0 for no card. The first call wins; later calls do nothing. */
    static synchronized void decided(long c) {
        if (decided) return;
        decided = true;
        card = c;
        decidedAt = now();
        LandingQueue.class.notifyAll();
    }

    /** The card of sweep {@code id} is on screen (its onCreate). Kept by id; counts only for the decided card. */
    static synchronized void cardShown(long id) {
        if (id == 0) return;
        SHOWN.add(id);
        LandingQueue.class.notifyAll();
    }

    /** The card of sweep {@code id} closed (a finishing onDestroy). Kept by id; counts only for the decided card. */
    static synchronized void cardGone(long id) {
        if (id == 0) return;
        GONE.add(id);
        LandingQueue.class.notifyAll();
    }

    /** The caller holds the monitor. */
    private static boolean shown() {
        return card != 0 && SHOWN.contains(card);
    }

    /** The caller holds the monitor. */
    private static boolean gone() {
        return card != 0 && GONE.contains(card);
    }

    /** Wait up to {@code maxMs} for the card decision; true when it came. */
    static synchronized boolean awaitDecided(long maxMs) {
        long end = now() + maxMs;
        while (!decided) {
            long left = end - now();
            if (left <= 0) break;
            try {
                LandingQueue.class.wait(left);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        return decided;
    }

    /**
     * Where a notice goes. Waits up to {@code maxMs} for the decision. CARD when a card was decided, is not gone and
     * {@code sweepOpen} says its sweep still runs. Otherwise waits until the card is gone ({@link #awaitGone}) and
     * answers ALONE.
     */
    static synchronized Place place(long maxMs, LongPredicate sweepOpen) {
        awaitDecided(maxMs);
        if (decided && card != 0 && !gone() && sweepOpen.test(card)) return Place.CARD;
        awaitGone(SHOW_MS);
        return Place.ALONE;
    }

    /**
     * Return when no card was decided, when the decided card is gone, or when it did not report shown within
     * {@code showMs} of the decision. A shown card is waited for until it goes.
     */
    static synchronized void awaitGone(long showMs) {
        while (decided && card != 0 && !gone()) {
            long wait = 0;
            if (!shown()) {
                wait = showMs - (now() - decidedAt);
                if (wait <= 0) return;
            }
            try {
                LandingQueue.class.wait(wait);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    /** Fold {@code words} into the card. {@code skipTime} is the skip notice's time, 0 for any other line. */
    static synchronized void addLine(String words, long skipTime) {
        LINES.add(words);
        if (skipTime != 0) SKIP.add(skipTime);
    }

    /** The folded words, in order. A copy. */
    static synchronized List<String> lines() {
        return new ArrayList<>(LINES);
    }

    /** The skip times not taken yet. Each time is returned once, ever. */
    static synchronized long[] takeSkipTimes() {
        long[] out = new long[SKIP.size() - skipTaken];
        for (int i = 0; i < out.length; i++) out[i] = SKIP.get(skipTaken + i);
        skipTaken = SKIP.size();
        return out;
    }

    /** Tests only: forget everything, as a new process would. */
    static synchronized void resetForTest() {
        decided = false;
        card = 0;
        decidedAt = 0;
        SHOWN.clear();
        GONE.clear();
        LINES.clear();
        SKIP.clear();
        skipTaken = 0;
        LandingQueue.class.notifyAll();
    }
}
