package com.nowhere.chooser;

import java.util.Arrays;
import java.util.List;

/** NWP-20261210-20: FetchQueue's counting rules, compiled with FetchQueue.java, LandingLine.java and AppDeps.java
 *  (test-fetch-queue-java.sh). Each line starts "ok <case>" or "FAIL <case>"; a mutant is convicted by the case it names. */
public class FetchQueueCases {
    static int fails = 0;

    static final String GMS = "com.google.android.gms", GSF = "com.google.android.gsf", VENDING = "com.android.vending";
    static final String YT = "com.google.android.youtube";

    static void check(String id, String what, boolean ok, String got) {
        if (ok) { System.out.println("ok " + id + " " + what); return; }
        fails++;
        System.out.println("FAIL " + id + " " + what + ": got " + got);
    }

    /** The "(n of m)" the notification shows, and the named member. */
    static String show(FetchQueue q) {
        FetchQueue.Snapshot s = q.snapshot();
        return s.position + " of " + s.total + (s.named == null ? "" : " " + s.named);
    }

    static void at(String id, String what, FetchQueue q, int pos, int total) {
        FetchQueue.Snapshot s = q.snapshot();
        check(id, what + " reads " + pos + " of " + total, s.position == pos && s.total == total, show(q));
    }

    static void pendingIs(String id, String what, FetchQueue q, int n) {
        check(id, what + ": " + n + " pending", q.pendingSize() == n, String.valueOf(q.pendingSize()));
    }

    static List<String> list(String... s) {
        return Arrays.asList(s);
    }

    public static void main(String[] a) {
        // F1 three members count 1, 2, 3 of 3; the drain ends the batch, so the next counts from 1.
        FetchQueue q = new FetchQueue();
        q.enqueue(list("a", "b", "c"));
        q.start("a");
        at("F1", "a runs", q, 1, 3);
        q.finish("a");
        q.start("b");
        at("F1", "b runs", q, 2, 3);
        q.finish("b");
        q.start("c");
        at("F1", "c runs", q, 3, 3);
        q.finish("c");
        at("F1", "drained", q, 0, 0);
        check("F1", "drained: nothing named", q.snapshot().named == null && q.current() == null, show(q));
        q.enqueue(list("d"));
        at("F1", "the next batch", q, 1, 1);

        // F2 the double count: a tap's S finishes without landing while the sweep's A is pending; the sweep then queues
        // S and A again in the same batch. Two apps, never three.
        q = new FetchQueue();
        q.enqueue(list("A"));
        q.enqueue(list("S"));
        q.start("S");
        q.finish("S");
        q.enqueue(list("S", "A"));
        at("F2", "S finished, [S, A] queued again", q, 2, 2);
        pendingIs("F2", "only A", q, 1);
        q.start("A");
        q.finish("A");
        at("F2", "drained", q, 0, 0);

        // F3 the Play-stack ask declined during a sweep: the tap takes back its own claim on S, not the sweep's.
        q = new FetchQueue();
        q.enqueue(list(GMS, GSF, "A", "S"));
        q.enqueue(list("S"));
        q.release(list("S"));
        at("F3", "the tap's claim released", q, 1, 4);
        check("F3", "S still pending", q.snapshot().rest.contains("S"), String.valueOf(q.snapshot().rest));
        for (String p : list(GMS, GSF, "A")) { q.start(p); q.finish(p); }
        q.start("S");
        at("F3", "the sweep runs S", q, 4, 4);
        q.finish("S");
        q.release(list(GMS, GSF, "A", "S"));
        at("F3", "the sweep's end release after S finished", q, 0, 0);

        // F4 the deps from the first frame: the total is the card's row count for a work list with a Play client.
        java.util.Map<String, String> none = new java.util.HashMap<>(), groups = new java.util.HashMap<>();
        for (String s : new String[] {VENDING, GMS, GSF}) groups.put(s, "sandboxed-play");
        List<String> work = list("a", YT, "b");
        List<String> deferred = list("a", YT, "b", GMS, GSF);
        java.util.Set<String> clients = new java.util.HashSet<>(list(YT));
        String[] rows = LandingLine.cardPkgs(work,
                p -> AppDeps.appDeps(p, none, groups, deferred, clients, GMS, GSF, VENDING), p -> false);
        q = new FetchQueue();
        q.batch(7L);
        q.enqueue(Arrays.asList(rows));
        check("F4", "the card has rows beyond the work list", rows.length > work.size(), Arrays.toString(rows));
        at("F4", "the first frame", q, 1, rows.length);

        // F5 Pause and Resume of one card: 1 of 8 finished, the 7 released, the service cleared; the same card's batch
        // and the 7 queued again read 2 of 8.
        final long K = 41L, K2 = 42L;
        List<String> eight = list("p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7");
        List<String> seven = eight.subList(1, 8);
        q = paused(K, eight, seven);
        q.batch(K);
        q.enqueue(seven);
        at("F5", "the Resume of the same card", q, 2, 8);
        // F5b another card or no card counts the 7 afresh.
        q = paused(K, eight, seven);
        q.batch(K2);
        q.enqueue(seven);
        at("F5b", "another card's batch", q, 1, 7);
        q = paused(K, eight, seven);
        q.batch(0L);
        q.enqueue(seven);
        at("F5b", "a batch with no card", q, 1, 7);
        // F5c a key-0 batch that drains in between keeps K's record.
        q = paused(K, eight, seven);
        q.enqueue(list("tap"));
        q.start("tap");
        q.finish("tap");
        at("F5c", "the tap's batch drained", q, 0, 0);
        q.batch(K);
        q.enqueue(seven);
        at("F5c", "the Resume after it", q, 2, 8);
        // a second Pause and Resume of the same card keeps the total again
        q.release(seven);
        q.clear();
        q.batch(K);
        q.enqueue(seven);
        at("F5c", "a second Pause and Resume", q, 2, 8);

        // F6 two holders: one release keeps it; the second removes it uncounted; absent, finished and below 0: no-ops.
        q = new FetchQueue();
        q.enqueue(list("x", "y"));
        q.enqueue(list("x"));
        q.release(list("x"));
        at("F6", "x released once of two holders", q, 1, 2);
        q.release(list("x"));
        at("F6", "x released twice: uncounted", q, 1, 1);
        q.release(list("x"));
        q.release(list("absent"));
        at("F6", "release below zero and of an absent member", q, 1, 1);
        q.enqueue(list("z"));
        q.start("y");
        q.finish("y");
        q.release(list("y"));
        at("F6", "release of a finished member", q, 2, 2);
        q.release(list("z"));
        at("F6", "the last release drains", q, 0, 0);

        // F7 a failed group: the sweep holds [gms, A], the group adds [gms, A], the dep fails: the group's release and
        // A finished leave gms pending under the sweep's claim; the sweep's end release drains.
        q = new FetchQueue();
        q.enqueue(list(GMS, "A"));
        q.enqueue(list(GMS, "A"));
        q.start(GMS);
        q.release(list(GMS, "A"));
        q.finish("A");
        pendingIs("F7", "gms still held by the sweep", q, 1);
        check("F7", "gms is the named member", GMS.equals(q.snapshot().named), show(q));
        q.release(list(GMS, "A"));
        at("F7", "the sweep's end release", q, 0, 0);

        // F8 start of a finished member names it and counts nothing; named falls to the first pending; rest keeps order.
        q = new FetchQueue();
        q.enqueue(list("a", "b", "c", "d"));
        check("F8", "nothing runs: the first pending is named", "a".equals(q.snapshot().named)
                && q.snapshot().current == null, show(q));
        check("F8", "rest is the others in order", q.snapshot().rest.equals(list("b", "c", "d")),
                String.valueOf(q.snapshot().rest));
        q.start("c");
        check("F8", "c runs: c named, rest a, b, d", "c".equals(q.snapshot().named)
                && q.snapshot().rest.equals(list("a", "b", "d")), show(q) + " " + q.snapshot().rest);
        q.finish("c");
        q.start("c");
        at("F8", "a finished member started again", q, 2, 4);
        check("F8", "it is named and current", "c".equals(q.snapshot().named) && "c".equals(q.current()), show(q));
        pendingIs("F8", "not pending again", q, 3);
        q.start("e");
        at("F8", "a new member started joins the batch", q, 2, 5);

        // F9 the sweep's claim, replayed as sweepAuto keeps it (RF-001): `claim` is the sweep's queued list. An app leaves
        // it when materializeAndInstall (or the catch) has taken back or finished the sweep's holder; an exit releases
        // rest(work, i) and the loop's end removes the work list; the finally releases only what is left. A tap's holder
        // stays.
        List<String> sweepWork = list("A", "S");
        q = new FetchQueue();
        q.batch(41);
        List<String> claim = new java.util.ArrayList<>(sweepWork);
        q.enqueue(claim);
        q.enqueue(list("S"));                        // a tap for S, waiting behind MAT_LOCK
        q.start("A");
        q.finish("A");                               // materializeAndInstall's end
        claim.remove("A");
        q.release(sweepWork.subList(1, sweepWork.size())); // Pause: qDrop(SignOutGate.rest(work, i))
        claim.removeAll(sweepWork);                  // the loop's end
        q.release(claim);                            // the finally: qDrop(queued)
        pendingIs("F9", "a Pause, then the end release: the tap's S", q, 1);
        at("F9", "a Pause, then the end release", q, 2, 2);
        q.start("S");
        q.finish("S");
        at("F9", "the tap lands S: drained", q, 0, 0);

        // F9b a busy lane on the last app drains the batch; the retry claims it again under the card's key.
        q = new FetchQueue();
        q.batch(42);
        claim = new java.util.ArrayList<>(sweepWork);
        q.enqueue(claim);
        q.start("A");
        q.finish("A");
        claim.remove("A");
        q.enqueue(list("S"));                        // materializeLocked's qEnqueue(group)
        q.start("S");
        q.release(list("S"));                        // the busy arm's qDrop(group)
        q.release(list("S"));                        // materializeAndInstall: BUSY takes back the caller's claim
        at("F9b", "the busy release drained the batch", q, 0, 0);
        q.batch(42);                                 // the RETRY arm: qBatch(card); qEnqueue(singletonList(pkg))
        q.enqueue(list("S"));
        at("F9b", "the retry counts on from the card's finished", q, 2, 2);
        q.enqueue(list("S"));
        q.start("S");
        q.finish("S");
        claim.remove("S");
        claim.removeAll(sweepWork);
        q.release(claim);
        at("F9b", "S lands: drained", q, 0, 0);

        // F9c a throw out of materializeAndInstall: the catch releases the sweep's holder; a tap's holder stays.
        q = new FetchQueue();
        claim = new java.util.ArrayList<>(sweepWork);
        q.enqueue(claim);
        q.enqueue(list("A"));                        // a tap for A
        q.start("A");
        q.release(list("A"));                        // the catch: qDrop(singletonList(pkg))
        claim.remove("A");
        q.release(sweepWork.subList(1, sweepWork.size())); // a sign-out: qDrop(SignOutGate.rest(work, i))
        claim.removeAll(sweepWork);
        q.release(claim);
        pendingIs("F9c", "a throw, then a sign-out: the tap's A", q, 1);

        // F10 the remembered tap's claim, replayed as sweepAuto's remembered-tap loop keeps it (RF-002): `held` is its
        // tapHeld. Each call ends with the claim taken back or finished; a busy retry claims the app again; the cleanup
        // releases only a claim still held. A live tap for S holds S all along and must stay counted.
        q = new FetchQueue();
        q.enqueue(list("S"));                        // the remembered tap: qEnqueue(singletonList(pkg)); tapHeld = true
        boolean held = true;
        q.enqueue(list("S"));                        // a live tap for S, waiting behind MAT_LOCK
        for (int attempt = 1; attempt <= 2; attempt++) {
            held = false;                            // tapHeld = false; materializeAndInstall(pkg, true)
            q.enqueue(list("S"));                    // materializeLocked's qEnqueue(group)
            q.start("S");
            q.release(list("S"));                    // the busy arm's qDrop(group)
            q.release(list("S"));                    // materializeAndInstall: BUSY takes back the caller's claim
            pendingIs("F10", "busy attempt " + attempt + ": the live tap's S", q, 1);
            q.enqueue(list("S"));                    // the retry: qEnqueue(singletonList(pkg)); tapHeld = true
            held = true;
        }
        if (held) q.release(list("S"));              // a sign-out ends the loop: the cleanup releases the held claim
        pendingIs("F10", "a sign-out after a retry's claim: the live tap's S", q, 1);
        q.start("S");
        q.finish("S");                               // the live tap lands S
        at("F10", "the live tap lands S: drained", q, 0, 0);

        // F10b a throw: the catch takes the claim back, and the cleanup (tapHeld false) releases nothing more.
        q = new FetchQueue();
        q.enqueue(list("S"));
        held = true;
        q.enqueue(list("S"));                        // a live tap for S
        held = false;
        q.start("S");
        q.release(list("S"));                        // the catch: qDrop(singletonList(pkg))
        if (held) q.release(list("S"));
        pendingIs("F10b", "a throw, then the cleanup: the live tap's S", q, 1);

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases pass");
    }

    /** A batch keyed K: 8 queued, the first finished, the 7 released (a Pause), then the service's clear. */
    static FetchQueue paused(long k, List<String> eight, List<String> seven) {
        FetchQueue q = new FetchQueue();
        q.batch(k);
        q.enqueue(eight);
        q.start(eight.get(0));
        q.finish(eight.get(0));
        q.release(seven);
        q.clear();
        return q;
    }
}
