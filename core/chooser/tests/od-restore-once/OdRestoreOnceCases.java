package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Supplier;

/** NWP-20261202-38: OdRestoreOnce's cases C1-C10 (test-od-restore-once-java.sh compiles them with OdRestoreOnce ALONE).
 *  Every wait is a 30 s hang guard that FAILS, never a timing assertion. */
public class OdRestoreOnceCases {
    static int fails = 0;
    static final long GUARD_S = 30;

    static void check(String id, boolean cond, String what) {
        System.out.println((cond ? "ok " : "FAIL ") + id + " " + what);
        if (!cond) fails++;
    }

    /** A sender that counts its calls and answers reply. */
    static Supplier<String> counting(AtomicInteger n, String reply) {
        return () -> { n.incrementAndGet(); return reply; };
    }

    static final List<String> LOG = new ArrayList<>();

    static String send(String pkg, long stamp, Supplier<String> s) {
        return OdRestoreOnce.send(pkg, stamp, s, m -> { synchronized (LOG) { LOG.add(m); } });
    }

    static String shared(String pkg, long stamp, Supplier<String> s) {
        return OdRestoreOnce.sendShared(pkg, stamp, s, m -> { synchronized (LOG) { LOG.add(m); } });
    }

    static Thread start(Runnable r) {
        Thread t = new Thread(r);
        t.setDaemon(true); // a hung thread (M7) never keeps the JVM up after the case FAILs
        t.start();
        return t;
    }

    static boolean joined(Thread t) throws InterruptedException {
        t.join(GUARD_S * 1000);
        return !t.isAlive();
    }

    static boolean pollWaiting(String pkg, int want) throws InterruptedException {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(GUARD_S);
        while (System.nanoTime() < end) {
            if (OdRestoreOnce.waiting(pkg) == want) return true;
            Thread.sleep(5);
        }
        return false;
    }

    /** C2 and C10's shape: a leader whose sender blocks until released, then a follower started while it is in flight.
     *  Returns {leader reply, follower reply, follower sender calls} or null on a guard failure (already reported). */
    static String[] flight(String id, String pkg, long stamp, boolean followerShared) throws InterruptedException {
        CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicReference<String> lr = new AtomicReference<>(), fr = new AtomicReference<>();
        AtomicInteger fn = new AtomicInteger();
        Thread leader = start(() -> lr.set(send(pkg, stamp, () -> {
            started.countDown();
            try { release.await(GUARD_S, TimeUnit.SECONDS); } catch (InterruptedException e) { return ""; }
            return "OK " + pkg;
        })));
        if (!started.await(GUARD_S, TimeUnit.SECONDS)) { check(id, false, "hang guard: the leader's sender never ran"); return null; }
        Thread follower = start(() -> fr.set(followerShared ? shared(pkg, stamp, counting(fn, "OK follower"))
                : send(pkg, stamp, counting(fn, "OK follower"))));
        boolean w = pollWaiting(pkg, 1);
        release.countDown();
        boolean lj = joined(leader), fj = joined(follower);
        if (!w) { check(id, false, "hang guard: the follower never waited on the in-flight send (it sent " + fn.get() + ")"); return null; }
        if (!lj || !fj) { check(id, false, "hang guard: a thread did not finish"); return null; }
        return new String[] {lr.get(), fr.get(), Integer.toString(fn.get())};
    }

    public static void main(String[] a) throws Exception {
        // A watchdog: a mutant that hangs or spins after its own case FAILs still ends this run, with a FAIL.
        Thread dog = new Thread(() -> {
            try { Thread.sleep(GUARD_S * 4 * 1000); } catch (InterruptedException e) { return; }
            System.out.println("FAIL CW watchdog: the cases ran past " + GUARD_S * 4 + " s");
            System.out.flush();
            Runtime.getRuntime().halt(1);
        });
        dog.setDaemon(true);
        dog.start();
        // C1: a second send of the same install after an OK does not call its sender and returns the first reply.
        OdRestoreOnce.resetForTest();
        {
            AtomicInteger n1 = new AtomicInteger(), n2 = new AtomicInteger();
            String r1 = send("p", 100, counting(n1, " OK p \n"));
            String r2 = send("p", 100, counting(n2, "OK second"));
            check("C1", n1.get() == 1 && n2.get() == 0 && "OK p".equals(r1) && "OK p".equals(r2),
                    "a later sender of a landed install sends nothing and takes its reply (calls " + n1 + "/" + n2 + ", " + r2 + ")");
        }
        // C2: a follower of an in-flight send of the same install waits, sends nothing and returns the leader's reply.
        OdRestoreOnce.resetForTest();
        {
            String[] r = flight("C2", "p", 100, false);
            if (r != null) check("C2", "0".equals(r[2]) && "OK p".equals(r[0]) && "OK p".equals(r[1]),
                    "a follower of an in-flight send shares its reply (follower sent " + r[2] + ", got " + r[1] + ")");
        }
        // C3: a non-OK reply records nothing: the next send calls its sender.
        {
            boolean ok = true;
            StringBuilder why = new StringBuilder();
            for (String bad : new String[] {"ERR-NOTREADY", "", "ERR-WORKER-BUSY", null}) {
                OdRestoreOnce.resetForTest();
                AtomicInteger n = new AtomicInteger();
                send("p", 100, () -> bad);
                String r = send("p", 100, counting(n, "OK p"));
                if (n.get() != 1 || !"OK p".equals(r)) { ok = false; why.append(" after ").append(bad); }
            }
            check("C3", ok, "a non-OK reply is sent again" + why);
        }
        // C4: a new stamp (a new install or an update) sends again.
        OdRestoreOnce.resetForTest();
        {
            AtomicInteger n = new AtomicInteger();
            send("p", 100, () -> "OK p");
            String r = send("p", 200, counting(n, "OK2"));
            check("C4", n.get() == 1 && "OK2".equals(r), "a new install's stamp gets its own restore (sent " + n + ", got " + r + ")");
        }
        // C5: stamp -1 (unreadable) always sends.
        OdRestoreOnce.resetForTest();
        {
            AtomicInteger n = new AtomicInteger();
            send("p", -1, counting(n, "OK p"));
            send("p", -1, counting(n, "OK p"));
            check("C5", n.get() == 2, "an unreadable stamp always sends (sent " + n + " of 2)");
        }
        // C6: a throwing sender releases the claim; the next send calls its sender.
        OdRestoreOnce.resetForTest();
        {
            boolean threw = false;
            try {
                send("p", 100, () -> { throw new RuntimeException("socket"); });
            } catch (RuntimeException e) {
                threw = true;
            }
            AtomicInteger n = new AtomicInteger();
            AtomicReference<String> r = new AtomicReference<>();
            OdRestoreOnce.waitMs = 2_000L; // a leaked claim would make this wait; the assertion is on the call count
            Thread t = start(() -> r.set(send("p", 100, counting(n, "OK p"))));
            boolean j = joined(t);
            check("C6", threw && j && n.get() == 1 && "OK p".equals(r.get()),
                    "a throwing sender releases its claim (threw " + threw + ", next sent " + n + ", got " + r.get() + ")");
        }
        // C7: a follower of a leader that never answers returns "" without sending once waitMs runs out.
        OdRestoreOnce.resetForTest();
        {
            OdRestoreOnce.waitMs = 200L;
            CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1);
            Thread leader = start(() -> send("p", 100, () -> {
                started.countDown();
                try { release.await(GUARD_S * 2, TimeUnit.SECONDS); } catch (InterruptedException e) { return ""; }
                return "OK p";
            }));
            if (!started.await(GUARD_S, TimeUnit.SECONDS)) check("C7", false, "hang guard: the leader's sender never ran");
            else {
                AtomicInteger n = new AtomicInteger();
                AtomicReference<String> r = new AtomicReference<>();
                Thread f = start(() -> r.set(send("p", 100, counting(n, "OK follower"))));
                boolean j = joined(f);
                check("C7", j && n.get() == 0 && "".equals(r.get()),
                        j ? "a timed-out follower returns \"\" unsent (sent " + n + ", got " + r.get() + ")"
                          : "hang guard: the follower waited past 30 s -- the wait is unbounded");
            }
            release.countDown();
            joined(leader);
        }
        // C8: record() stores an OK only, and never for stamp -1.
        OdRestoreOnce.resetForTest();
        {
            AtomicInteger np = new AtomicInteger(), nq = new AtomicInteger(), nr = new AtomicInteger();
            OdRestoreOnce.record("p", 100, "ERR-NOTREADY");
            send("p", 100, counting(np, "OK p"));
            OdRestoreOnce.record("q", 100, " OK q ");
            String rq = send("q", 100, counting(nq, "OK other"));
            OdRestoreOnce.record("r", -1, "OK r");
            send("r", -1, counting(nr, "OK r"));
            OdRestoreOnce.record("s", 100, null);
            AtomicInteger ns = new AtomicInteger();
            send("s", 100, counting(ns, "OK s"));
            check("C8", np.get() == 1 && nq.get() == 0 && "OK q".equals(rq) && nr.get() == 1 && ns.get() == 1,
                    "record keeps an OK only (p sent " + np + ", q sent " + nq + " got " + rq + ", r sent " + nr + ", s sent " + ns + ")");
        }
        // C9: two packages never share a reply.
        OdRestoreOnce.resetForTest();
        {
            AtomicInteger n = new AtomicInteger();
            send("a", 100, () -> "OK a");
            String r = send("b", 100, counting(n, "OK b"));
            check("C9", n.get() == 1 && "OK b".equals(r), "another package sends its own restore (sent " + n + ", got " + r + ")");
        }
        // C10: sendShared ignores a landed OK, but shares an in-flight send.
        OdRestoreOnce.resetForTest();
        {
            AtomicInteger n = new AtomicInteger();
            send("p", 100, () -> "OK p");
            String r = shared("p", 100, counting(n, "OK again"));
            String[] f = flight("C10", "p", 300, true);
            if (f != null) check("C10", n.get() == 1 && "OK again".equals(r) && "0".equals(f[2]) && "OK p".equals(f[1]),
                    "sendShared sends after a landed OK (sent " + n + ") and shares an in-flight one (sent " + f[2] + ", got " + f[1] + ")");
        }
        // The log lines name no package.
        synchronized (LOG) {
            boolean clean = !LOG.isEmpty();
            for (String m : LOG) if (!m.startsWith("od-restore-once: ") || !m.endsWith("(NWP-20261202-38)")) clean = false;
            check("CL", clean, "every log line is an od-restore-once line naming no package (" + LOG.size() + " lines)");
        }
        System.exit(fails == 0 ? 0 : 1);
    }
}
