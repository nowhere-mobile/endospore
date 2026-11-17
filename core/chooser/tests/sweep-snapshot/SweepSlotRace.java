package com.nowhere.chooser;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** NWP-20261203-07: the sweep-thread publication and clear, LIFTED from UnarchiveService.sweepPassBegin and
 *  sweepPassEnd (NWP-20261203-03's pass helpers, which sweepAutoJoined calls) into
 *  SweepSlotHarness by core/vendor-common/bin/test-sweep-snapshot-java.sh and executed here (R1-R3). The suite
 *  rewrites the clear's ownership check to `SweepSlotRace.seen(...)`, so R1 can stop the old sweep between its check
 *  and its clear and run a new sweep's publication in that gap, in a fixed order. */
public final class SweepSlotRace {
    static int bad = 0;
    static void check(String id, boolean cond, String what) {
        if (cond) { System.out.println("ok " + id + " " + what); return; }
        System.out.println("FAIL " + id + " " + what);
        bad++;
    }

    /** The thread that stops in seen(), or null for no stop. */
    static volatile Thread pauseIn;
    static volatile CountDownLatch atCheck = new CountDownLatch(1);
    static volatile CountDownLatch go = new CountDownLatch(1);

    /** The clear's ownership check calls this (the suite's rewrite). On pauseIn it signals that the check ran and
     *  waits for the go, at most 5 s. */
    static boolean seen(boolean owner) {
        if (Thread.currentThread() == pauseIn) {
            atCheck.countDown();
            try { go.await(5, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }
        return owner;
    }

    static void reset() {
        SweepSlotHarness.SWEEP_THREAD = null;
        pauseIn = null;
        atCheck = new CountDownLatch(1);
        go = new CountDownLatch(1);
    }

    /** Waits at most 5 s until t is BLOCKED, WAITING or TERMINATED. */
    static Thread.State settle(Thread t) throws InterruptedException {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < end) {
            Thread.State s = t.getState();
            if (s == Thread.State.BLOCKED || s == Thread.State.WAITING || s == Thread.State.TERMINATED) return s;
            Thread.sleep(1);
        }
        return t.getState();
    }

    public static void main(String[] args) throws Exception {
        // R1 the reviewed order: sweep A has left SweepJoin and passed its ownership check; sweep B publishes; A
        // clears. B must still be the published sweep thread.
        reset();
        final Thread[] b = new Thread[1];
        Thread a = new Thread(() -> {
            SweepSlotHarness.publish();
            pauseIn = Thread.currentThread();
            SweepSlotHarness.clear();
        });
        a.start();
        boolean checked = atCheck.await(5, TimeUnit.SECONDS);
        check("R1", checked, "sweep A reached its ownership check");
        b[0] = new Thread(SweepSlotHarness::publish);
        b[0].start();
        Thread.State bs = settle(b[0]);
        go.countDown();
        a.join(5000);
        b[0].join(5000);
        check("R1", bs == Thread.State.BLOCKED,
                "sweep B's publication waits while A is between its check and its clear (B was " + bs + ")");
        check("R1", SweepSlotHarness.SWEEP_THREAD == b[0],
                "after A's clear, B is still the sweep thread (it is " + who(SweepSlotHarness.SWEEP_THREAD, a, b[0]) + ")");

        // R2 one sweep that ends clears itself.
        reset();
        Thread one = new Thread(() -> { SweepSlotHarness.publish(); SweepSlotHarness.clear(); });
        one.start();
        one.join(5000);
        check("R2", SweepSlotHarness.SWEEP_THREAD == null, "a sweep that ends leaves no sweep thread");

        // R3 B published before A's clear began: A's clear leaves B in place.
        reset();
        CountDownLatch bDone = new CountDownLatch(1);
        Thread a3 = new Thread(() -> {
            SweepSlotHarness.publish();
            try { bDone.await(5, TimeUnit.SECONDS); } catch (InterruptedException e) { return; }
            SweepSlotHarness.clear();
        });
        a3.start();
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (SweepSlotHarness.SWEEP_THREAD != a3 && System.nanoTime() < end) Thread.sleep(1);
        Thread b3 = new Thread(SweepSlotHarness::publish);
        b3.start();
        b3.join(5000);
        bDone.countDown();
        a3.join(5000);
        check("R3", SweepSlotHarness.SWEEP_THREAD == b3,
                "a sweep's clear after another sweep published leaves that sweep (it is "
                        + who(SweepSlotHarness.SWEEP_THREAD, a3, b3) + ")");

        System.exit(bad == 0 ? 0 : 1);
    }

    static String who(Thread t, Thread a, Thread b) {
        return t == null ? "none" : t == a ? "A" : t == b ? "B" : "another thread";
    }
}
