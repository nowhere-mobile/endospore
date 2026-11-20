package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** NWP-20261208-23: LandingLine's waiting words and LandingLine.Sweep's waiting record, run under javac by
 *  test-landing-waiting-java.sh. The record is static: the cases run in this order and compare ids, never values. */
public final class LandingWaitingCases {
    private static int fails;

    private static void check(String id, boolean ok) {
        System.out.println((ok ? "ok " : "FAIL ") + id);
        if (!ok) fails++;
    }

    public static void main(String[] a) {
        // C1 the approved headline, byte for byte (U+00B7 between "moment" and "0")
        String h = LandingLine.waitingHeadline(12);
        byte[] want = new byte[] {'S', 't', 'a', 'r', 't', 'i', 'n', 'g', ' ', 'i', 'n', ' ', 'a', ' ', 'm', 'o', 'm', 'e', 'n',
            't', ' ', (byte) 0xC2, (byte) 0xB7, ' ', '0', ' ', 'o', 'f', ' ', '1', '2'};
        check("C1 waitingHeadline(12) is \"Starting in a moment · 0 of 12\"",
                "Starting in a moment · 0 of 12".equals(h) && Arrays.equals(want, h.getBytes(StandardCharsets.UTF_8)));

        // C2-C4 the row words
        check("C2 state(false, false, true) is \"◷ waiting\"", "◷ waiting".equals(LandingLine.state(false, false, true)));
        check("C3 state(true, false, true) is \"✓ ready\"", "✓ ready".equals(LandingLine.state(true, false, true)));
        check("C4 the 2-arg state is unchanged",
                "✓ ready".equals(LandingLine.state(true, false))
                        && "installing".equals(LandingLine.state(false, true))
                        && "◷ coming back".equals(LandingLine.state(false, false))
                        && "installing".equals(LandingLine.state(false, true, false)));

        String[] rows = {"a.one", "a.two", "a.three"};
        // C5 a waiting card
        long w = LandingLine.Sweep.beginWaiting(rows);
        check("C5 beginWaiting: waiting, not done", w != 0 && LandingLine.Sweep.waiting(w) && !LandingLine.Sweep.done(w));
        // C7 go() for another id changes nothing
        check("C7 go(other) is false and the card still waits", !LandingLine.Sweep.go(w + 1000) && !LandingLine.Sweep.go(0)
                && LandingLine.Sweep.waiting(w));
        // C6 go() adopts once
        boolean first = LandingLine.Sweep.go(w);
        boolean second = LandingLine.Sweep.go(w);
        check("C6 go(w) is true once, then false, and the card no longer waits",
                first && !second && !LandingLine.Sweep.waiting(w) && !LandingLine.Sweep.done(w));

        // C8 begin() after beginWaiting does not wait
        long w2 = LandingLine.Sweep.beginWaiting(rows);
        long b = LandingLine.Sweep.begin(rows);
        check("C8 begin() after beginWaiting: neither id waits", b != w2 && !LandingLine.Sweep.waiting(b)
                && !LandingLine.Sweep.waiting(w2));

        // C9 drop
        long w3 = LandingLine.Sweep.beginWaiting(rows);
        LandingLine.Sweep.drop(w3);
        check("C9 drop(w): dropped and done", LandingLine.Sweep.dropped(w3) && LandingLine.Sweep.done(w3));
        // C10 dropped() for another id
        check("C10 dropped(other) and dropped(0) are false", !LandingLine.Sweep.dropped(w3 + 1000)
                && !LandingLine.Sweep.dropped(0) && !LandingLine.Sweep.dropped(b));
        // C11 dropped survives a later begin
        long b2 = LandingLine.Sweep.begin(rows);
        check("C11 dropped(w) survives a later begin; the new id is not dropped",
                LandingLine.Sweep.dropped(w3) && !LandingLine.Sweep.dropped(b2) && !LandingLine.Sweep.done(b2));
        // C11 drop of a stale id after the begin does nothing to the new card
        LandingLine.Sweep.drop(w3);
        check("C11 drop(stale id) leaves the new card open", !LandingLine.Sweep.done(b2) && !LandingLine.Sweep.dropped(b2));

        // C12 pkgs
        long w4 = LandingLine.Sweep.beginWaiting(rows);
        String[] p1 = LandingLine.Sweep.pkgs(w4);
        boolean equal = Arrays.equals(rows, p1);
        if (p1 != null && p1.length > 0) p1[0] = "changed";
        check("C12 pkgs(w) is a copy of the rows; pkgs(other) is null", equal
                && Arrays.equals(rows, LandingLine.Sweep.pkgs(w4)) && LandingLine.Sweep.pkgs(w4 + 1000) == null
                && LandingLine.Sweep.pkgs(0) == null);

        // C13 sameRows
        check("C13 sameRows: equal true", LandingLine.sameRows(new String[] {"x", "y"}, new String[] {"x", "y"}));
        check("C13 sameRows: reordered false", !LandingLine.sameRows(new String[] {"x", "y"}, new String[] {"y", "x"}));
        check("C13 sameRows: a null side false", !LandingLine.sameRows(null, new String[] {"x"})
                && !LandingLine.sameRows(new String[] {"x"}, null) && !LandingLine.sameRows(null, null));
        check("C13 sameRows: empty false", !LandingLine.sameRows(new String[0], new String[0]));

        // C14-C19 (RF-001) a waiting card shown late never replaces a running card's record. The record is ended first.
        long prior = LandingLine.Sweep.begin(rows);
        LandingLine.Sweep.end(prior);
        // C14 a waiting start that took its ticket, with no landing start after it, shows its card
        long t0 = LandingLine.Sweep.landingTicket();
        long ok = LandingLine.Sweep.beginWaiting(t0, rows);
        check("C14 beginWaiting(ticket): no landing start since the ticket, the card waits",
                ok != 0 && LandingLine.Sweep.waiting(ok) && !LandingLine.Sweep.gone(ok));
        LandingLine.Sweep.drop(ok);
        // C15 the reviewer's order: the waiting reader takes its ticket, the landing start begins the running card,
        // then the reader finishes. It gets 0 and the running card keeps its id, rows and progress.
        long t1 = LandingLine.Sweep.landingTicket();
        LandingLine.Sweep.landingStarts();
        // C16 a ticket taken after that landing start, while it runs and before it begins a card, is refused too
        long t2 = LandingLine.Sweep.landingTicket();
        check("C16 beginWaiting(ticket) while a landing start runs is refused", LandingLine.Sweep.beginWaiting(t2, rows) == 0);
        String[] runRows = {"r.one", "r.two"};
        long run = LandingLine.Sweep.begin(runRows);
        LandingLine.Sweep.started(run, "r.one");
        long late = LandingLine.Sweep.beginWaiting(t1, rows);
        check("C15 a late waiting card is refused and the running card keeps its record", late == 0
                && !LandingLine.Sweep.done(run) && !LandingLine.Sweep.waiting(run)
                && Arrays.equals(runRows, LandingLine.Sweep.pkgs(run)) && LandingLine.Sweep.installing(run) == 0);
        LandingLine.Sweep.landingEnds();
        // C17 an open card (begun, not ended: here a paused one) is never replaced, even with a fresh ticket
        LandingLine.Sweep.pause(run);
        long t3 = LandingLine.Sweep.landingTicket();
        check("C17 beginWaiting(fresh ticket) with an open card is refused",
                LandingLine.Sweep.beginWaiting(t3, rows) == 0 && LandingLine.Sweep.paused(run));
        LandingLine.Sweep.end(run);
        // C18 a ticket older than an ended landing start stays refused
        check("C18 beginWaiting(stale ticket) after the landing start ended is refused",
                LandingLine.Sweep.beginWaiting(t1, rows) == 0);
        // C19 gone(): adopted is not gone; dropped or replaced is
        long g = LandingLine.Sweep.beginWaiting(LandingLine.Sweep.landingTicket(), rows);
        LandingLine.Sweep.go(g);
        boolean adopted = g != 0 && !LandingLine.Sweep.gone(g);
        long g2 = LandingLine.Sweep.begin(rows);
        boolean replaced = LandingLine.Sweep.gone(g);
        LandingLine.Sweep.end(g2);
        long g3 = LandingLine.Sweep.beginWaiting(LandingLine.Sweep.landingTicket(), rows);
        LandingLine.Sweep.drop(g3);
        check("C19 gone(): an adopted card is not gone; a replaced or dropped one is; gone(0)",
                adopted && replaced && g3 != 0 && LandingLine.Sweep.gone(g3) && LandingLine.Sweep.gone(0));

        // C20 (RF-002) the waiting reader pauses between the record and the publish. In that pause a landing start runs
        // its whole cleanup: landingStarts, the take, the drop and landingEnds. It must wait for the publish, take the
        // card and drop it, so the reader then sees gone() and starts no card, and no waiting card is left.
        final java.util.concurrent.atomic.AtomicLong holder = new java.util.concurrent.atomic.AtomicLong(0);
        final java.util.concurrent.atomic.AtomicLong taken = new java.util.concurrent.atomic.AtomicLong(-1);
        final Thread landing = new Thread(() -> {
            LandingLine.Sweep.landingStarts();
            long left = holder.getAndSet(0);
            taken.set(left);
            if (left != 0) LandingLine.Sweep.drop(left);
            LandingLine.Sweep.landingEnds();
        });
        long rw = LandingLine.Sweep.beginWaiting(LandingLine.Sweep.landingTicket(), rows, x -> {
            landing.start();
            long until = System.nanoTime() + 5_000_000_000L;
            while (landing.getState() != Thread.State.BLOCKED && landing.getState() != Thread.State.TERMINATED
                    && System.nanoTime() < until) Thread.yield();
            holder.set(x);
        });
        try { landing.join(5000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        boolean starts = rw != 0 && !LandingLine.Sweep.gone(rw);
        check("C20 a landing cleanup in the pause between record and publish takes and drops the card; none starts",
                rw != 0 && !landing.isAlive() && taken.get() == rw && holder.get() == 0 && !starts
                        && LandingLine.Sweep.dropped(rw) && LandingLine.Sweep.done(rw));

        System.out.println(fails == 0 ? "all cases passed" : fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
