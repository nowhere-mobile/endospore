package com.nowhere.chooser;

import java.util.Arrays;

/**
 * NWP-20261207-12: MediaLanding's cases, with MediaStatus and LandingLine.Sweep, run by
 * core/chooser/test-media-landing-java.sh. Each case prints PASS or FAIL with its id; any FAIL exits 1.
 */
public final class MediaLandingCases {
    static int fails = 0;

    static void ok(String id, boolean cond, String what) {
        if (cond) System.out.println("PASS " + id + ": " + what);
        else { fails++; System.out.println("FAIL " + id + ": " + what); }
    }

    static final long MIB50 = 50L * 1024 * 1024;

    public static void main(String[] a) {
        // C8 first: Sweep is process-static, so it is read before any begin.
        ok("C8 open before any begin", !LandingLine.Sweep.open(), "no sweep begun is not open");
        long s1 = LandingLine.Sweep.begin(new String[]{"a"});
        ok("C8 open after begin", LandingLine.Sweep.open(), "a begun sweep is open");
        LandingLine.Sweep.pause(s1);
        ok("C8 open when paused", LandingLine.Sweep.open(), "a paused sweep is open");
        LandingLine.Sweep.end(s1);
        ok("C8 closed after end", !LandingLine.Sweep.open(), "an ended sweep is not open");
        long s2 = LandingLine.Sweep.begin(new String[]{"a"});
        ok("C8 open after a new begin", LandingLine.Sweep.open(), "a new sweep is open");
        LandingLine.Sweep.stop(s2);
        ok("C8 closed after stop", !LandingLine.Sweep.open(), "a stopped sweep is not open");

        // C1-C5: large().
        ok("C1 201 files", MediaLanding.large(new long[]{0, 1, 201}), "201 files is large");
        ok("C2 200 files", !MediaLanding.large(new long[]{0, 1, 200}), "200 files and 1 byte is not large");
        ok("C3 50 MiB + 1", MediaLanding.large(new long[]{0, MIB50 + 1, 1}), "50 MiB + 1 byte is large");
        ok("C3 done is not total", !MediaLanding.large(new long[]{MIB50 + 1, 1, 1}), "large reads the total bytes, not the done bytes");
        ok("C4 exactly 50 MiB", !MediaLanding.large(new long[]{0, MIB50, 1}), "exactly 50 MiB is not large");
        ok("C4 50 MB of 1000", !MediaLanding.large(new long[]{0, 50_000_001L, 1}), "50 MB of 1000 + 1 is not large (the unit is MiB)");
        ok("C5 null", !MediaLanding.large(null), "null is not large");
        ok("C5 two fields", !MediaLanding.large(new long[]{0, MIB50 + 1}), "a 2-element array is not large");

        // C6: show() once per sign-in serial.
        ok("C6 new serial", MediaLanding.show(true, "7", "8"), "a new serial shows");
        ok("C6 same serial", !MediaLanding.show(true, "7", "7"), "the same serial does not show again");
        ok("C6 null serial", !MediaLanding.show(true, "7", null), "a null serial shows nothing");
        ok("C6 cold-lock resume", !MediaLanding.show(true, "7", "7"), "a cold-lock resume (same serial) does not show");
        ok("C6 not large", !MediaLanding.show(false, null, "7"), "a small set does not show");
        ok("C6 no stamp", MediaLanding.show(true, null, "7"), "no stamp yet shows");

        // C7: the words.
        ok("C7 words", !MediaLanding.IN_CARD.isEmpty() && !MediaLanding.ALONE.isEmpty()
                && !MediaLanding.IN_CARD.equals(MediaLanding.ALONE), "IN_CARD and ALONE are non-empty and differ");
        ok("C7 no digit", !MediaLanding.IN_CARD.matches(".*[0-9].*") && !MediaLanding.ALONE.matches(".*[0-9].*"),
                "the words carry no number");
        ok("C7 button", !LandingLine.GOT_IT.isEmpty(), "the button word is LandingLine.GOT_IT");

        // C9: the process-static record.
        ok("C9 null", !MediaLanding.shownFor(null), "shownFor(null) is false");
        ok("C9 before mark", !MediaLanding.shownFor("5"), "nothing is recorded before mark");
        MediaLanding.mark("5");
        ok("C9 after mark", MediaLanding.shownFor("5"), "mark(5) records 5");
        ok("C9 another serial", !MediaLanding.shownFor("6"), "mark(5) does not record 6");

        // C10: a daemon reply, end to end through MediaStatus.
        ok("C10 idle", MediaStatus.restoring(MediaStatus.route(Arrays.asList("IDLE"))[3]) == null, "no RESTORING line reads as none");
        ok("C10 201 files", MediaLanding.large(MediaStatus.restoring(MediaStatus.route(
                Arrays.asList("LOADING 1 2 3 a b", "RESTORING 10 999 201"))[3])), "RESTORING 10 999 201 is large");
        ok("C10 200 files", !MediaLanding.large(MediaStatus.restoring(MediaStatus.route(
                Arrays.asList("RESTORING 10 999 200"))[3])), "RESTORING 10 999 200 is not large");

        // C11: the constants.
        ok("C11 constants", MediaLanding.FILES_OVER == 200 && MediaLanding.BYTES_OVER == 52428800L
                && MediaLanding.WAIT_MS == 30000 && MediaLanding.STEP_MS == 2000,
                "FILES_OVER 200, BYTES_OVER 52428800, WAIT_MS 30000, STEP_MS 2000");

        // C12: firstRestoring's deadline, on a simulated clock. Asks from index slowFrom on take askMs, the others no
        // time; replies[i] answers the i-th ask.
        long[] big = {0, 1, 201};
        Sim t1 = new Sim(0, 0, null, null, big);
        long[] got = MediaLanding.firstRestoring(t1, t1);
        ok("C12 timely reply", got == big && t1.asks == 3, "a RESTORING reply at the third ask (4 s) is read");
        Sim t2 = new Sim(0, 0);
        ok("C12 expired sleep", MediaLanding.firstRestoring(t2, t2) == null && t2.asks == 15 && t2.lastAskAt == 28000,
                "15 empty replies: the sleep that ends at 30 s ends the wait, no 16th ask at 30 s");
        ok("C12 no ask after the deadline", t2.maxAskAt < MediaLanding.WAIT_MS, "no ask starts at or after 30 s");
        long[][] late = new long[15][];
        late[14] = big;
        Sim t3 = new Sim(3000, 14, late);
        ok("C12 reply crosses the deadline", MediaLanding.firstRestoring(t3, t3) == null && t3.asks == 15
                && t3.lastAskAt == 28000, "a RESTORING reply asked at 28 s that arrives at 31 s is discarded");
        ok("C12 ask bounded", t3.capOverLeft == 0 && t3.maxCap <= MediaLanding.ASK_MS,
                "every ask's cap is at most ASK_MS and at most the time left");
        Sim t5 = new Sim(1500, 0);
        ok("C12 sleep bounded", MediaLanding.firstRestoring(t5, t5) == null && t5.sleepOverLeft == 0
                && t5.maxSleep <= MediaLanding.STEP_MS && t5.now == MediaLanding.WAIT_MS,
                "asks of 1.5 s: every sleep is at most STEP_MS and at most the time left, and the wait ends at 30 s");
        Sim t4 = new Sim(0, 0);
        t4.interrupt = true;
        ok("C12 interrupted", MediaLanding.firstRestoring(t4, t4) == null && t4.asks == 1, "an interrupt ends the wait");

        System.exit(fails == 0 ? 0 : 1);
    }

    /** A simulated clock and daemon: an ask from index slowFrom on takes askMs; it returns the next reply (null past
     *  the list). */
    static final class Sim implements MediaLanding.Ask, MediaLanding.Clock {
        final long askMs;
        final int slowFrom;
        final long[][] replies;
        long now, lastAskAt = -1, maxAskAt = -1, maxCap, maxSleep;
        int asks, capOverLeft, sleepOverLeft;
        boolean interrupt;

        Sim(long askMs, int slowFrom, long[]... replies) {
            this.askMs = askMs;
            this.slowFrom = slowFrom;
            this.replies = replies;
        }

        @Override public long[] restoring(long capMs) {
            lastAskAt = now;
            maxAskAt = Math.max(maxAskAt, now);
            maxCap = Math.max(maxCap, capMs);
            if (capMs > MediaLanding.WAIT_MS - now) capOverLeft++;
            long[] r = asks < replies.length ? replies[asks] : null;
            if (asks >= slowFrom) now += askMs;
            asks++;
            return r;
        }

        @Override public long now() { return now; }

        @Override public void sleep(long ms) throws InterruptedException {
            if (interrupt) throw new InterruptedException();
            maxSleep = Math.max(maxSleep, ms);
            if (ms > MediaLanding.WAIT_MS - now) sleepOverLeft++;
            now += ms;
        }
    }
}
