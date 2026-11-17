package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** NWP-20261203-03: SweepStall, compiled with that file ALONE and executed by
 *  core/vendor-common/bin/test-sweep-stall-java.sh. A fake sink records each request and each abandon; the clock is
 *  the `now` each call passes (seconds below, as ms). */
public final class SweepStallCases {
    static final Set<String> failed = new LinkedHashSet<>();
    static int bad = 0;
    static void check(String id, boolean cond, String what) {
        if (cond) return;
        System.out.println("FAIL " + id + " " + what);
        failed.add(id);
        bad++;
    }
    static void ok(String id, String what) { if (!failed.contains(id)) System.out.println("ok " + id + " " + what); }

    static final class Sink implements SweepStall.Sink {
        final List<String> sent = new ArrayList<>();
        int abandons;
        @Override public void send(String req) { sent.add(req); }
        @Override public void abandon() { abandons++; }
    }

    static long s(long secs) { return secs * 1000L; }

    static String req(String kind, String step, int i, int n, long secs) {
        return "AUTO-SWEEP-STEP\n" + kind + "\n" + step + "\n" + i + "\n" + n + "\n" + secs + "\n";
    }

    /** One tick at `secs`; what it sent. */
    static List<String> tick(Sink k, long secs) {
        int from = k.sent.size();
        SweepStall.tick(s(secs), k);
        return new ArrayList<>(k.sent.subList(from, k.sent.size()));
    }

    public static void main(String[] a) {
        // S1: nothing before 5 minutes.
        SweepStall.reset();
        Sink k = new Sink();
        SweepStall.enter(SweepStall.FETCH, 2, 5, s(0));
        check("S1", tick(k, 0).isEmpty() && tick(k, 60).isEmpty() && tick(k, 299).isEmpty(),
                "a tick before STALL_MS sent " + k.sent);
        ok("S1", "no line before 5 minutes without progress");

        // S2: a stall at 5 minutes, again at 15, not at 10.
        List<String> at300 = tick(k, 300);
        check("S2", at300.size() == 1 && at300.get(0).equals(req("stall", "fetch", 2, 5, 300)),
                "at 300 s sent " + at300 + ", want one stall for fetch app 2/5 after 300s");
        check("S2", tick(k, 301).isEmpty() && tick(k, 600).isEmpty(), "a stall was repeated before REPEAT_MS");
        List<String> at900 = tick(k, 900);
        check("S2", at900.size() == 1 && at900.get(0).equals(req("stall", "fetch", 2, 5, 900)),
                "at 900 s sent " + at900 + ", want the second stall");
        check("S2", k.abandons == 0, "abandoned before HARD_MS");
        ok("S2", "a stall at 5 minutes, again at 15, not at 10");

        // S3: progress resets the stall clock.
        SweepStall.reset();
        SweepStall.tick(0, new Sink()); // the last case's pending `ended`
        k = new Sink();
        SweepStall.enter(SweepStall.INSTALL, 1, 3, s(0));
        check("S3", tick(k, 300).size() == 1, "no first stall at 300 s");
        SweepStall.progress(s(360));
        check("S3", tick(k, 600).isEmpty(), "progress at 360 s did not move the next stall");
        List<String> at660 = tick(k, 660);
        check("S3", at660.size() == 1 && at660.get(0).equals(req("stall", "install", 1, 3, 300)),
                "at 660 s sent " + at660 + ", want a stall 300 s after the progress");
        tick(k, 1500);
        check("S3", k.abandons == 0 && !SweepStall.abandoned(), "abandoned at 1500 s, 1140 s after the progress");
        tick(k, 1860);
        check("S3", k.abandons == 1, "not abandoned at 1860 s, HARD_MS after the progress");
        ok("S3", "progress resets the stall clock");

        // S4: a step that ends after a reported stall gets one `ended` at the next tick, before anything else.
        SweepStall.reset();
        k = new Sink();
        SweepStall.enter(SweepStall.FETCH, 2, 5, s(0));
        tick(k, 300);
        SweepStall.enter(SweepStall.INSTALL, s(1000));
        List<String> at1010 = tick(k, 1010);
        check("S4", at1010.size() == 1 && at1010.get(0).equals(req("ended", "fetch", 2, 5, 1000)),
                "after the step changed sent " + at1010 + ", want one ended for fetch after 1000s");
        check("S4", tick(k, 1020).isEmpty(), "the ended line was sent twice");
        SweepStall.enter(SweepStall.RESTORE, s(1030)); // install was never reported stalled
        check("S4", tick(k, 1040).isEmpty(), "a step change with no stall sent an ended line");
        // the pending ended goes first, even when a stall is due at the same tick
        SweepStall.reset();
        k = new Sink();
        SweepStall.enter(SweepStall.FETCH, 1, 2, s(0));
        tick(k, 300);
        SweepStall.enter(SweepStall.RESTORE, s(400));
        List<String> both = tick(k, 700);
        check("S4", both.size() == 2 && both.get(0).startsWith("AUTO-SWEEP-STEP\nended\nfetch\n")
                && both.get(1).startsWith("AUTO-SWEEP-STEP\nstall\nrestore\n"), "sent " + both + ", want ended then stall");
        // a reset (the next pass) and a close (the sweep is over) also end a stalled step
        SweepStall.reset();
        k = new Sink();
        tick(k, 700);
        check("S4", k.sent.size() == 1 && k.sent.get(0).startsWith("AUTO-SWEEP-STEP\nended\nrestore\n"),
                "a reset after a stalled step sent " + k.sent + ", want its ended");
        k = new Sink();
        SweepStall.enter(SweepStall.REPORT, 4, 4, s(0));
        tick(k, 300);
        SweepStall.close(SweepStall.pass(), s(320));
        List<String> closed = tick(k, 330);
        check("S4", closed.size() == 1 && closed.get(0).equals(req("ended", "report", 4, 4, 320)) && SweepStall.step() == null,
                "a close after a stalled step sent " + closed + ", want ended for report after 320s and no step");
        SweepStall.enter(SweepStall.LIST, 0, 0, s(400));
        SweepStall.close(SweepStall.pass() - 1, s(410));
        check("S4", SweepStall.LIST.equals(SweepStall.step()), "a close for an earlier pass ended the current pass's step");
        ok("S4", "a stalled step's end is one ended line at the next tick");

        // S5: abandoned once at 25 minutes, true until reset; the stall lines go on.
        SweepStall.reset();
        k = new Sink();
        SweepStall.enter(SweepStall.RESTORE, 1, 9, s(0));
        for (long t = 0; t < 1500; t += 30) tick(k, t);
        check("S5", k.abandons == 0 && !SweepStall.abandoned(), "abandoned before HARD_MS");
        List<String> at1500 = tick(k, 1500);
        check("S5", at1500.contains(req("abandoned", "restore", 1, 9, 1500)) && k.abandons == 1 && SweepStall.abandoned(),
                "at 1500 s sent " + at1500 + " with " + k.abandons + " abandon(s), want one abandoned and one abandon");
        for (long t = 1530; t <= 2100; t += 30) tick(k, t);
        int nAband = 0;
        for (String r : k.sent) if (r.startsWith("AUTO-SWEEP-STEP\nabandoned\n")) nAband++;
        check("S5", nAband == 1 && k.abandons == 1, "abandoned " + nAband + " time(s), abandon() " + k.abandons + ", want once");
        check("S5", k.sent.contains(req("stall", "restore", 1, 9, 2100)), "no stall at 35 minutes after the abandon");
        check("S5", SweepStall.abandoned(), "abandoned() did not stay true");
        SweepStall.reset();
        check("S5", !SweepStall.abandoned(), "reset() did not end the abandon");
        k = new Sink();
        tick(k, 3000);
        int idle = 0;
        for (String r : k.sent) if (!r.startsWith("AUTO-SWEEP-STEP\nended\n")) idle++;
        check("S5", idle == 0 && k.abandons == 0, "after reset a tick sent " + k.sent);
        ok("S5", "abandoned once at 25 minutes, true until reset");

        // S6: request() bounds and tokens.
        check("S6", req("stall", "list", 0, 0, 0).equals(SweepStall.request("stall", "list", 0, 0, 0)), "0/0/0 refused");
        check("S6", req("joined", "busy-wait", 9999, 9999, 86400).equals(SweepStall.request("joined", "busy-wait", 9999, 9999, 86400)),
                "9999/9999/86400 refused");
        Object[][] badReqs = {
            { "stall", "fetch", -1, 4, 5L }, { "stall", "fetch", 5, 4, 5L }, { "stall", "fetch", 1, 10000, 5L },
            { "stall", "fetch", 1, 4, -1L }, { "stall", "fetch", 1, 4, 86401L }, { "hung", "fetch", 1, 4, 5L },
            { "stall", "download", 1, 4, 5L }, { null, "fetch", 1, 4, 5L }, { "stall", null, 1, 4, 5L },
            { "stall", "com.example.app", 1, 4, 5L },
        };
        for (Object[] b : badReqs) {
            String r = SweepStall.request((String) b[0], (String) b[1], (Integer) b[2], (Integer) b[3], (Long) b[4]);
            check("S6", r == null, "request" + java.util.Arrays.toString(b) + " was not refused");
        }
        ok("S6", "request() refuses bad bounds and unknown tokens");

        // S7: idle sends nothing; an unknown token changes nothing.
        SweepStall.reset();
        k = new Sink();
        tick(k, 0);
        k = new Sink();
        tick(k, 5000);
        check("S7", k.sent.isEmpty() && k.abandons == 0, "an idle tick sent " + k.sent);
        SweepStall.enter("com.example.app", 1, 2, s(5000));
        check("S7", SweepStall.step() == null, "an unknown token set the step");
        SweepStall.enter(SweepStall.FETCH, 1, 2, s(5000));
        SweepStall.enter("nope", 2, 2, s(5100));
        check("S7", SweepStall.FETCH.equals(SweepStall.step()) && SweepStall.i() == 1, "an unknown token changed the step");
        ok("S7", "an idle tick sends nothing; an unknown token changes nothing");

        System.out.println(bad == 0 ? "cases: all pass" : "cases: " + bad + " failed");
        System.exit(bad == 0 ? 0 : 1);
    }
}
