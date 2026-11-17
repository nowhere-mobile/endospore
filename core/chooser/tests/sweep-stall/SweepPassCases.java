package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/** NWP-20261203-03: the sweep's pass ownership, run by core/vendor-common/bin/test-sweep-stall-java.sh. The suite builds
 *  SweepPass from UnarchiveService's REAL sweepPassBegin, sweepPassEnd, sweepSockOwn and sweepSockRelease (LocalSocket
 *  read as AutoCloseable) and compiles it with SweepStall and this file. Each "thread" below is a real Thread run to its
 *  end with join(), so the order is fixed:
 *    R1  C begins, D begins (a new start after C's SweepJoin.exit), C ends: SWEEP_THREAD stays D; an owner's own end
 *        clears it.
 *    R2  A's socket release after B owns a socket leaves B's socket; B's release clears it; a tap's socket is not owned.
 *    R3  a begin clears the thread's interrupt and starts a new, not abandoned pass; after an abandon, the sweep
 *        thread's next socket is closed and refused.
 *    R4  the abandon of a pass runs under the SweepStall monitor; when a send of that pass's tick starts a new pass,
 *        the abandon is not called. */
public final class SweepPassCases {
    static int bad = 0;
    static void check(String id, boolean cond, String what) {
        if (cond) return;
        System.out.println("FAIL " + id + " " + what);
        bad++;
    }

    static final class Sock implements AutoCloseable {
        boolean closed;
        @Override public void close() { closed = true; }
    }

    public static void main(String[] a) throws Exception {
        // R1: C owns the sweep; D begins (a new start after C's SweepJoin.exit); then C's outer finally runs.
        int b0 = bad;
        SweepPass.SWEEP_THREAD = null;
        final Thread[] owner = new Thread[3];
        Thread c = new Thread(() -> {
            SweepPass.sweepPassBegin();
            owner[0] = SweepPass.SWEEP_THREAD;
            Thread d = new Thread(SweepPass::sweepPassBegin);
            owner[2] = d;
            d.start();
            try { d.join(); } catch (InterruptedException e) { return; }
            SweepPass.sweepPassEnd(); // C's end, after D took the sweep
            owner[1] = SweepPass.SWEEP_THREAD;
        });
        c.start(); c.join();
        check("R1", owner[0] == c && owner[1] == owner[2] && owner[1] != null,
                "C's end after D began left SWEEP_THREAD " + owner[1] + ", want D");
        Thread[] last = new Thread[1];
        Thread e = new Thread(() -> { SweepPass.sweepPassBegin(); SweepPass.sweepPassEnd(); last[0] = SweepPass.SWEEP_THREAD; });
        e.start(); e.join();
        check("R1", last[0] == null, "the owner's own end did not clear SWEEP_THREAD");
        if (bad == b0) System.out.println("ok R1 an old pass's end never clears a new owner; the owner's end clears it");

        // R2
        b0 = bad;
        Sock sa = new Sock(), sb = new Sock(), st = new Sock();
        Object[] seen = new Object[3];
        Thread f = new Thread(() -> {
            SweepPass.sweepPassBegin();
            SweepPass.sweepSockOwn(sa);
            Thread g = new Thread(() -> { SweepPass.sweepPassBegin(); SweepPass.sweepSockOwn(sb); });
            g.start();
            try { g.join(); } catch (InterruptedException x) { return; }
            SweepPass.sweepSockRelease(sa); // F's socket closes after G owns its own
            seen[0] = SweepPass.SWEEP_SOCK;
        });
        f.start(); f.join();
        check("R2", seen[0] == sb, "an old socket's release cleared the new pass's socket (SWEEP_SOCK " + seen[0] + ")");
        SweepPass.sweepSockRelease(sb);
        check("R2", SweepPass.SWEEP_SOCK == null, "the owning socket's release did not clear SWEEP_SOCK");
        boolean tapOk = SweepPass.sweepSockOwn(st); // main is not the sweep thread
        check("R2", tapOk && SweepPass.SWEEP_SOCK == null && !st.closed, "a tap's socket was recorded or closed");
        if (bad == b0) System.out.println("ok R2 a socket's release never clears a newer pass's socket; a tap's is not owned");

        // R3
        b0 = bad;
        boolean[] r3 = new boolean[5];
        Sock late = new Sock();
        Thread h = new Thread(() -> {
            SweepPass.sweepPassBegin();
            long p0 = SweepStall.pass();
            SweepStall.enter(SweepStall.FETCH, 1, 2, 0);
            SweepStall.tick(SweepStall.HARD_MS, new SweepStall.Sink() {
                @Override public void send(String req) {}
                @Override public void abandon() { Thread.currentThread().interrupt(); }
            });
            r3[0] = SweepStall.abandoned();
            r3[1] = !SweepPass.sweepSockOwn(late) && late.closed && SweepPass.SWEEP_SOCK == null;
            SweepPass.sweepPassBegin(); // the joined rerun
            r3[2] = !Thread.currentThread().isInterrupted();
            r3[3] = !SweepStall.abandoned() && SweepStall.pass() == p0 + 1;
            SweepPass.sweepPassEnd();
        });
        h.start(); h.join();
        check("R3", r3[0], "the tick at HARD_MS did not abandon the pass");
        check("R3", r3[1], "after the abandon the sweep thread's next socket was not closed and refused");
        check("R3", r3[2], "a begin did not clear the abandoned pass's interrupt");
        check("R3", r3[3], "a begin did not start a new, not abandoned pass");
        if (bad == b0) System.out.println("ok R3 a begin clears the interrupt; an abandoned pass's next socket is refused");

        // R4
        b0 = bad;
        List<String> got = new ArrayList<>();
        SweepStall.reset();
        SweepStall.enter(SweepStall.RESTORE, 1, 3, 0);
        SweepStall.tick(SweepStall.HARD_MS, new SweepStall.Sink() {
            @Override public void send(String req) {}
            @Override public void abandon() { got.add(Thread.holdsLock(SweepStall.class) ? "locked" : "unlocked"); }
        });
        check("R4", got.size() == 1 && got.get(0).equals("locked"), "the abandon ran " + got + ", want once, locked");
        got.clear();
        SweepStall.reset();
        SweepStall.enter(SweepStall.RESTORE, 1, 3, 0);
        SweepStall.tick(SweepStall.HARD_MS, new SweepStall.Sink() {
            @Override public void send(String req) {
                if (!req.startsWith("AUTO-SWEEP-STEP\nabandoned\n")) return;
                // a fresh pass starts while the abandoned line is sent
                SweepStall.reset();
                SweepStall.enter(SweepStall.FETCH, 1, 1, SweepStall.HARD_MS);
            }
            @Override public void abandon() { got.add("abandon"); }
        });
        check("R4", got.isEmpty() && !SweepStall.abandoned(), "the earlier pass's abandon reached the fresh pass " + got);
        if (bad == b0) System.out.println("ok R4 the abandon runs under the monitor and only for the pass that went past HARD_MS");

        System.out.println(bad == 0 ? "pass cases: all pass" : "pass cases: " + bad + " failed");
        System.exit(bad == 0 ? 0 : 1);
    }
}
