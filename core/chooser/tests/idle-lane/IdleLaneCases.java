package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** NWP-20261114-04: the cases for IdleLane, compiled with the REAL IdleLane.java unchanged (tests/idle-lane/run.sh).
 *  Each case uses its own lane instance, except L3, which reads the production static lane through post().
 *  Every wait is bounded, so a broken lane FAILS and never hangs. System.exit at the end: a mutant lane whose thread
 *  is not a daemon would otherwise keep the JVM alive. */
public final class IdleLaneCases {
    private static boolean failed;

    private static void check(String name, boolean ok, String detail) {
        if (ok) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + " -- " + detail); failed = true; }
    }

    /** L1: task B, posted after task A, never runs while A is still running. */
    static void l1() throws Exception {
        IdleLane lane = new IdleLane();
        final List<String> rec = Collections.synchronizedList(new ArrayList<>());
        final CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1), done = new CountDownLatch(1);
        lane.run(() -> {
            rec.add("A-start");
            started.countDown();
            try { release.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignore) {}
            rec.add("A-end");
        });
        lane.run(() -> { rec.add("B"); done.countDown(); });
        boolean aStarted = started.await(5, TimeUnit.SECONDS);
        Thread.sleep(200);
        String mid = rec.toString();
        release.countDown();
        boolean bRan = done.await(5, TimeUnit.SECONDS);
        check("L1 A started", aStarted, "A never ran");
        check("L1 B does not run while A blocks", "[A-start]".equals(mid), "record while A blocked: " + mid);
        check("L1 B runs after A ends", bRan && "[A-start, A-end, B]".equals(rec.toString()), "record: " + rec);
    }

    /** L2: a task that throws stops neither the lane nor its thread, and never reaches the uncaught handler. */
    static void l2() throws Exception {
        Thread.UncaughtExceptionHandler saved = Thread.getDefaultUncaughtExceptionHandler();
        final AtomicBoolean handlerCalled = new AtomicBoolean();
        Thread.setDefaultUncaughtExceptionHandler((th, ex) -> handlerCalled.set(true));
        try {
            IdleLane lane = new IdleLane();
            final AtomicReference<Thread> t1 = new AtomicReference<>(), t3 = new AtomicReference<>();
            final CountDownLatch after = new CountDownLatch(1), settle = new CountDownLatch(1);
            lane.run(() -> t1.set(Thread.currentThread()));
            lane.run(() -> { throw new RuntimeException("L2: a task throws"); });
            lane.run(() -> { t3.set(Thread.currentThread()); after.countDown(); });
            boolean ran = after.await(5, TimeUnit.SECONDS);
            check("L2a the task after the throw still runs", ran, "it never ran");
            check("L2b it runs on the same Thread as the task before the throw",
                    ran && t1.get() != null && t1.get() == t3.get(), "before=" + t1.get() + " after=" + t3.get());
            // A thread pool calls the handler AFTER it has started the replacement worker: settle before reading it.
            lane.run(settle::countDown);
            settle.await(5, TimeUnit.SECONDS);
            Thread.sleep(500);
            check("L2c the default uncaught-exception handler is never called", !handlerCalled.get(),
                    "the throw reached the uncaught-exception handler");
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(saved);
        }
    }

    /** L3: the production lane's thread is a daemon named nowhere-idle-binder. */
    static void l3() throws Exception {
        final AtomicReference<Thread> t = new AtomicReference<>();
        final CountDownLatch done = new CountDownLatch(1);
        IdleLane.post(() -> { t.set(Thread.currentThread()); done.countDown(); });
        boolean ran = done.await(5, TimeUnit.SECONDS);
        Thread th = t.get();
        check("L3 the lane thread is a daemon", ran && th != null && th.isDaemon(), "thread=" + th);
        check("L3 the lane thread is named nowhere-idle-binder",
                ran && th != null && "nowhere-idle-binder".equals(th.getName()), "thread=" + th);
    }

    /** L4: posts from two threads all run, and no two tasks overlap. */
    static void l4() throws Exception {
        final IdleLane lane = new IdleLane();
        final int per = 50;
        final AtomicInteger inFlight = new AtomicInteger(), maxSeen = new AtomicInteger(), ran = new AtomicInteger();
        final CountDownLatch go = new CountDownLatch(1), all = new CountDownLatch(2 * per);
        Runnable task = () -> {
            int now = inFlight.incrementAndGet();
            maxSeen.accumulateAndGet(now, Math::max);
            try { Thread.sleep(1); } catch (InterruptedException ignore) {}
            inFlight.decrementAndGet();
            ran.incrementAndGet();
            all.countDown();
        };
        Thread[] posters = new Thread[2];
        for (int p = 0; p < posters.length; p++) {
            posters[p] = new Thread(() -> {
                try { go.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignore) {}
                for (int i = 0; i < per; i++) lane.run(task);
            }, "l4-poster-" + p);
            posters[p].setDaemon(true);
            posters[p].start();
        }
        go.countDown();
        boolean done = all.await(10, TimeUnit.SECONDS);
        check("L4 every task posted from two threads runs", done && ran.get() == 2 * per, "ran " + ran.get() + " of " + 2 * per);
        check("L4 no two tasks overlap", maxSeen.get() == 1, "max tasks in flight: " + maxSeen.get());
    }

    public static void main(String[] args) throws Exception {
        l1();
        l2();
        l3();
        l4();
        System.out.println(failed ? "FAIL" : "PASS");
        System.exit(failed ? 1 : 0);
    }
}
