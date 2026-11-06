package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Cases for MmsInFlight (#150): the txn claim, the per-SIM policy count, that the policy call sits under the
 *  lock, and the process-start reset of idle SIMs (NWP-20261110-15). Every cross-thread wait is bounded, so a hang fails the case instead of the run. */
public final class MmsInFlightCases {
    private static int bad = 0;

    private static void check(String name, boolean ok, String detail) {
        if (ok) { System.out.println("PASS " + name); return; }
        System.out.println("FAIL " + name + ": " + detail);
        bad++;
    }

    /** Records every set() in order, optionally blocking a chosen (subId, on) call on a latch. */
    private static final class Rec implements MmsInFlight.Policy {
        final List<String> calls = Collections.synchronizedList(new ArrayList<>());
        final int blockSub; final boolean blockOn;
        final CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        Rec() { this(-99, false); }
        Rec(int blockSub, boolean blockOn) { this.blockSub = blockSub; this.blockOn = blockOn; }
        @Override public void set(int subId, boolean on) {
            if (subId == blockSub && on == blockOn) {
                entered.countDown();
                try { release.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignore) {}
            }
            calls.add(subId + ":" + on);
        }
    }

    private static String s(List<String> l) { return l.toString(); }

    public static void main(String[] args) throws Exception {
        final long H12 = 12 * 60 * 60_000L;

        MmsInFlight.reset();
        long t = 1_000_000L;
        check("C1 first claim true", MmsInFlight.claimTxn("a", t), "false");
        check("C1 second claim false", !MmsInFlight.claimTxn("a", t + 1), "true");
        MmsInFlight.releaseTxn("a");
        check("C1 claim after release true", MmsInFlight.claimTxn("a", t + 2), "false");
        check("C1 an entry at the horizon is kept", !MmsInFlight.claimTxn("a", t + 2 + H12), "pruned early");
        check("C1 an entry older than 12 h is pruned", MmsInFlight.claimTxn("a", t + 2 + H12 + 1), "kept");
        check("C1 empty is always true", MmsInFlight.claimTxn("", t) && MmsInFlight.claimTxn("", t), "false");
        check("C1 null is always true", MmsInFlight.claimTxn(null, t), "false");
        MmsInFlight.releaseTxn(""); MmsInFlight.releaseTxn(null);
        MmsInFlight.reset();
        check("C1 empty stored nothing", MmsInFlight.claimTxn("", t) && MmsInFlight.claimTxn("x", t), "stored");

        MmsInFlight.reset();
        Rec r = new Rec();
        MmsInFlight.register("d1", 1, r); MmsInFlight.register("d2", 1, r);
        check("C2 two registers give one on", s(r.calls).equals("[1:true]"), s(r.calls));
        check("C2 the first finish is true", MmsInFlight.finish("d1", r), "false");
        check("C2 the first finish sets nothing", s(r.calls).equals("[1:true]"), s(r.calls));
        check("C2 the second finish is true", MmsInFlight.finish("d2", r), "false");
        check("C2 the second finish sets off once", s(r.calls).equals("[1:true, 1:false]"), s(r.calls));
        check("C2 refs is 0 after", MmsInFlight.refs(1) == 0 && !MmsInFlight.inFlight("d1"), "refs=" + MmsInFlight.refs(1));

        MmsInFlight.reset();
        r = new Rec();
        MmsInFlight.register("a", 1, r); MmsInFlight.register("b", 2, r);
        check("C3 each SIM switches on", s(r.calls).equals("[1:true, 2:true]"), s(r.calls));
        MmsInFlight.finish("b", r);
        check("C3 finishing SIM 2 sets only SIM 2 off", s(r.calls).equals("[1:true, 2:true, 2:false]")
                && MmsInFlight.refs(1) == 1 && MmsInFlight.refs(2) == 0, s(r.calls) + " refs1=" + MmsInFlight.refs(1));

        MmsInFlight.reset();
        r = new Rec();
        check("C4 an unknown name is false", !MmsInFlight.finish("nope", r), "true");
        MmsInFlight.register("a", 1, r);
        MmsInFlight.finish("a", r);
        int before = r.calls.size();
        check("C4 an already finished name is false and sets nothing",
                !MmsInFlight.finish("a", r) && r.calls.size() == before, s(r.calls));

        // C5: finish holds the lock across its set.
        MmsInFlight.reset();
        r = new Rec(1, false);
        MmsInFlight.register("a", 1, r);
        final Rec r5 = r;
        Thread t1 = new Thread(() -> MmsInFlight.finish("a", r5));
        final CountDownLatch t2Done = new CountDownLatch(1);
        Thread t2 = new Thread(() -> { MmsInFlight.register("b", 1, r5); t2Done.countDown(); });
        t1.start();
        check("C5 finish reached its set", r.entered.await(5, TimeUnit.SECONDS), "never entered");
        t2.start();
        check("C5 a register waits while finish is inside set", !t2Done.await(300, TimeUnit.MILLISECONDS), "returned");
        r.release.countDown();
        t1.join(5000); t2.join(5000);
        check("C5 the register returns once released", t2Done.getCount() == 0, "hung");
        check("C5 off lands before on", s(r.calls).equals("[1:true, 1:false, 1:true]"), s(r.calls));

        // C5b: register holds the lock across its set.
        MmsInFlight.reset();
        r = new Rec(1, true);
        final Rec r5b = r;
        t1 = new Thread(() -> MmsInFlight.register("n", 1, r5b));
        final CountDownLatch fin = new CountDownLatch(1);
        t2 = new Thread(() -> { MmsInFlight.finish("n", r5b); fin.countDown(); });
        t1.start();
        check("C5b register reached its set", r.entered.await(5, TimeUnit.SECONDS), "never entered");
        t2.start();
        check("C5b a finish waits while register is inside set", !fin.await(300, TimeUnit.MILLISECONDS), "returned");
        r.release.countDown();
        t1.join(5000); t2.join(5000);
        check("C5b the finish returns once released", fin.getCount() == 0, "hung");
        check("C5b on lands before off", s(r.calls).equals("[1:true, 1:false]"), s(r.calls));
        check("C5b refs is 0", MmsInFlight.refs(1) == 0, "refs=" + MmsInFlight.refs(1));

        // C6-C9 (NWP-20261110-15): the process-start reset switches off only SIMs with no download registered.
        MmsInFlight.reset();
        r = new Rec();
        int k = MmsInFlight.resetIdle(Arrays.asList(1, 2), r);
        check("C6 an idle reset sets every SIM off", s(r.calls).equals("[1:false, 2:false]"), s(r.calls));
        check("C6 an idle reset counts every SIM", k == 2, "returned " + k);

        MmsInFlight.reset();
        r = new Rec();
        MmsInFlight.register("d", 1, r);
        k = MmsInFlight.resetIdle(Arrays.asList(1, 2), r);
        check("C7 a SIM with a download registered is skipped", s(r.calls).equals("[1:true, 2:false]"), s(r.calls));
        check("C7 the skipped SIM is not counted", k == 1, "returned " + k);
        check("C7 the download stays registered", MmsInFlight.refs(1) == 1 && MmsInFlight.inFlight("d"),
                "refs1=" + MmsInFlight.refs(1));

        MmsInFlight.reset();
        r = new Rec();
        k = MmsInFlight.resetIdle(Collections.<Integer>emptyList(), r);
        check("C8 an empty list sets nothing", r.calls.isEmpty() && k == 0, s(r.calls) + " returned " + k);

        // C9: the reset takes the lock, so a register already inside its set is counted and skipped.
        MmsInFlight.reset();
        r = new Rec(1, true);
        final Rec r9 = r;
        t1 = new Thread(() -> MmsInFlight.register("a", 1, r9));
        final AtomicInteger ret = new AtomicInteger(-1);
        final CountDownLatch rDone = new CountDownLatch(1);
        t2 = new Thread(() -> { ret.set(MmsInFlight.resetIdle(Arrays.asList(1), r9)); rDone.countDown(); });
        t1.start();
        check("C9 register reached its set", r.entered.await(5, TimeUnit.SECONDS), "never entered");
        t2.start();
        check("C9 a reset waits while register is inside set", !rDone.await(300, TimeUnit.MILLISECONDS), "returned");
        r.release.countDown();
        t1.join(5000); t2.join(5000);
        check("C9 the reset returns once released", rDone.getCount() == 0, "hung");
        check("C9 the reset sets nothing for the registered SIM", s(r.calls).equals("[1:true]") && ret.get() == 0,
                s(r.calls) + " returned " + ret.get());
        check("C9 refs is 1", MmsInFlight.refs(1) == 1, "refs=" + MmsInFlight.refs(1));

        System.exit(bad == 0 ? 0 : 1);
    }
}
