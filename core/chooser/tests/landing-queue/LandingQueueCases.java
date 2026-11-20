package com.nowhere.chooser;

import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/**
 * NWP-20261208-24: LandingQueue under javac, compiled ALONE with LandingQueue.java (test-landing-queue-java.sh).
 * Each case starts from resetForTest(). The times are short (tens of ms), so a case never waits on DECIDE_MS or
 * SHOW_MS themselves; the bounds below are generous so a loaded runner does not fail a correct queue. Every call that
 * can block runs on its own daemon thread with a bound, and a watchdog ends the run, so a mutant that waits forever
 * fails the cases instead of hanging the suite.
 */
public class LandingQueueCases {
    static int fails;

    static void check(String name, boolean ok, String why) {
        if (ok) System.out.println("PASS " + name);
        else { System.out.println("FAIL " + name + ": " + why); fails++; }
    }

    static long ms() { return System.nanoTime() / 1000000L; }

    /** Run r on a daemon thread. */
    static Thread bg(Runnable r) {
        Thread t = new Thread(r);
        t.setDaemon(true);
        t.start();
        return t;
    }

    static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { throw new RuntimeException(e); }
    }

    static void join(Thread t, long ms) {
        try { t.join(ms); } catch (InterruptedException e) { throw new RuntimeException(e); }
    }

    /** place() on its own thread; null when it did not answer within bound ms. */
    static LandingQueue.Place place(long maxMs, java.util.function.LongPredicate open, long bound) {
        AtomicReference<LandingQueue.Place> r = new AtomicReference<>();
        join(bg(() -> r.set(LandingQueue.place(maxMs, open))), bound);
        return r.get();
    }

    /** awaitGone() on its own thread; true when it returned within bound ms. */
    static boolean awaitGone(long showMs, long bound) {
        Thread t = bg(() -> LandingQueue.awaitGone(showMs));
        join(t, bound);
        return !t.isAlive();
    }

    public static void main(String[] a) {
        Thread dog = new Thread(() -> {
            sleep(60000);
            System.out.println("FAIL the cases did not finish within 60 s");
            System.exit(1);
        });
        dog.setDaemon(true);
        dog.start();

        // C1 no decision within maxMs: ALONE, after about maxMs.
        LandingQueue.resetForTest();
        long t0 = ms();
        LandingQueue.Place p = place(80, id -> true, 3000);
        long el = ms() - t0;
        check("C1 undecided past maxMs -> ALONE", p == LandingQueue.Place.ALONE && el >= 70, "place=" + p + " after " + el + " ms");

        // C2 decided(0): ALONE at once, well under maxMs.
        LandingQueue.resetForTest();
        LandingQueue.decided(0);
        t0 = ms();
        p = place(5000, id -> true, 3000);
        el = ms() - t0;
        check("C2 decided(0) -> ALONE at once", p == LandingQueue.Place.ALONE && el < 1000, "place=" + p + " after " + el + " ms");

        // C3 decided(c), the sweep runs: CARD, at once. The predicate is asked about c.
        LandingQueue.resetForTest();
        LandingQueue.decided(7);
        final long[] asked = {0};
        t0 = ms();
        p = place(5000, id -> { asked[0] = id; return true; }, 3000);
        el = ms() - t0;
        check("C3 decided(c), sweep open -> CARD", p == LandingQueue.Place.CARD && asked[0] == 7 && el < 1000,
                "place=" + p + " asked=" + asked[0] + " after " + el + " ms");

        // C4 decided(c), shown, the sweep done: place waits until the card is gone, then ALONE.
        LandingQueue.resetForTest();
        LandingQueue.decided(9);
        LandingQueue.cardShown(9);
        AtomicReference<LandingQueue.Place> got = new AtomicReference<>();
        Thread th = bg(() -> got.set(LandingQueue.place(5000, id -> false)));
        sleep(250);
        boolean waited = th.isAlive() && got.get() == null;
        LandingQueue.cardGone(9);
        join(th, 3000);
        check("C4 decided(c), sweep done -> waits until gone, then ALONE",
                waited && !th.isAlive() && got.get() == LandingQueue.Place.ALONE,
                "waited=" + waited + " alive=" + th.isAlive() + " place=" + got.get());

        // C5 the card is already gone: ALONE at once, even with an open sweep.
        LandingQueue.resetForTest();
        LandingQueue.decided(11);
        LandingQueue.cardShown(11);
        LandingQueue.cardGone(11);
        t0 = ms();
        p = place(5000, id -> true, 3000);
        el = ms() - t0;
        check("C5 gone card -> ALONE", p == LandingQueue.Place.ALONE && el < 1000, "place=" + p + " after " + el + " ms");

        // C6 a card never shown: awaitGone returns about showMs after the decision.
        LandingQueue.resetForTest();
        LandingQueue.decided(13);
        t0 = ms();
        Thread g6 = bg(() -> LandingQueue.awaitGone(100));
        join(g6, 3000);
        el = ms() - t0;
        check("C6 never shown within showMs -> awaitGone returns", !g6.isAlive() && el >= 80 && el < 3000,
                "alive=" + g6.isAlive() + " after " + el + " ms");

        // C6b a shown card holds awaitGone past showMs, until it is gone.
        LandingQueue.resetForTest();
        LandingQueue.decided(15);
        LandingQueue.cardShown(15);
        Thread g6b = bg(() -> LandingQueue.awaitGone(50));
        sleep(250);
        boolean held = g6b.isAlive();
        LandingQueue.cardGone(15);
        join(g6b, 3000);
        check("C6b a shown card holds awaitGone past showMs until it is gone", held && !g6b.isAlive(),
                "held=" + held + " alive=" + g6b.isAlive());

        // C7 the first decision wins: decided(a) then decided(b) leaves a.
        LandingQueue.resetForTest();
        LandingQueue.decided(21);
        LandingQueue.decided(22);
        final long[] seen = {0};
        p = place(1000, id -> { seen[0] = id; return true; }, 3000);
        LandingQueue.resetForTest();
        LandingQueue.decided(23);
        LandingQueue.decided(0);
        LandingQueue.Place p7b = place(1000, id -> true, 3000);
        check("C7 the first decided wins", p == LandingQueue.Place.CARD && seen[0] == 21 && p7b == LandingQueue.Place.CARD,
                "place=" + p + " card=" + seen[0] + " then decided(0) after a card: " + p7b);

        // C8 shown and gone for another id are ignored: the card stays up, and an unshown card frees after showMs.
        LandingQueue.resetForTest();
        LandingQueue.decided(31);
        LandingQueue.cardShown(32);
        LandingQueue.cardGone(32);
        LandingQueue.cardGone(0);
        p = place(1000, id -> true, 3000);
        t0 = ms();
        boolean back8 = awaitGone(100, 3000);
        el = ms() - t0;
        check("C8 shown/gone for another id ignored", p == LandingQueue.Place.CARD && back8 && el >= 50,
                "place=" + p + " awaitGone back=" + back8 + " after " + el + " ms (another id's gone must not free it at once)");

        // C9 lines in the order they were added; lines() is a copy.
        LandingQueue.resetForTest();
        LandingQueue.addLine("first", 0);
        LandingQueue.addLine("second", 100);
        LandingQueue.addLine("third", 0);
        List<String> l = LandingQueue.lines();
        l.add("not kept");
        List<String> l2 = LandingQueue.lines();
        check("C9 lines in order", l2.equals(Arrays.asList("first", "second", "third")), "lines=" + l2);

        // C10 takeSkipTimes: each time once; a 0 skip time is never queued.
        LandingQueue.resetForTest();
        LandingQueue.addLine("a", 0);
        LandingQueue.addLine("b", 1700000000L);
        long[] k1 = LandingQueue.takeSkipTimes();
        long[] k2 = LandingQueue.takeSkipTimes();
        LandingQueue.addLine("c", 1700000005L);
        long[] k3 = LandingQueue.takeSkipTimes();
        check("C10 takeSkipTimes once each", Arrays.equals(k1, new long[] {1700000000L}) && k2.length == 0
                && Arrays.equals(k3, new long[] {1700000005L}),
                "k1=" + Arrays.toString(k1) + " k2=" + Arrays.toString(k2) + " k3=" + Arrays.toString(k3));

        // C11 shown BEFORE decided counts: awaitGone still waits past showMs, and cardGone frees it.
        LandingQueue.resetForTest();
        LandingQueue.cardShown(41);
        LandingQueue.decided(41);
        Thread g11 = bg(() -> LandingQueue.awaitGone(50));
        sleep(250);
        boolean held11 = g11.isAlive();
        LandingQueue.cardGone(41);
        join(g11, 3000);
        check("C11 shown before decided counts", held11 && !g11.isAlive(), "held=" + held11 + " alive=" + g11.isAlive());

        // C12 gone BEFORE decided counts: place answers ALONE at once with an open sweep; awaitGone returns at once.
        LandingQueue.resetForTest();
        LandingQueue.cardShown(51);
        LandingQueue.cardGone(51);
        LandingQueue.decided(51);
        t0 = ms();
        p = place(5000, id -> true, 3000);
        boolean back12 = awaitGone(5000, 3000);
        el = ms() - t0;
        check("C12 gone before decided counts", p == LandingQueue.Place.ALONE && back12 && el < 1000,
                "place=" + p + " awaitGone back=" + back12 + " after " + el + " ms");

        // C13 a waiting place() is released by the decision, not by maxMs.
        LandingQueue.resetForTest();
        AtomicReference<LandingQueue.Place> got13 = new AtomicReference<>();
        long s13 = ms();
        Thread th13 = bg(() -> got13.set(LandingQueue.place(5000, id -> true)));
        sleep(50);
        LandingQueue.decided(61);
        join(th13, 3000);
        long el13 = ms() - s13;
        check("C13 the decision releases a waiting place()", got13.get() == LandingQueue.Place.CARD && el13 < 3000,
                "place=" + got13.get() + " after " + el13 + " ms");

        if (fails != 0) {
            System.out.println("LandingQueueCases: " + fails + " FAILED");
            System.exit(1);
        }
        System.out.println("LandingQueueCases: all passed");
    }
}
