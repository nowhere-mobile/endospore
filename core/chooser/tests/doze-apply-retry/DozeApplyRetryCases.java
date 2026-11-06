package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/** NWP-20261116-14: the cases for DozeApplyRetry (dn-1023 #3), on a fake clock with recorded sleeps. Compiled with
 *  DozeApplyRetry.java as is by core/vendor-common/bin/test-doze-apply-retry-java.sh. Prints "ok <case>" or
 *  "FAIL <case>: ..." per case and exits 1 when any case failed. An attempt counter stops a run that never ends. */
public final class DozeApplyRetryCases {
    private static final int RUNAWAY = 10_000;
    private static int failed;

    /** One run on a fake clock: the attempt answers from a script (the last answer repeats) and costs costMs. */
    private static final class Run {
        final long[] now = { 0 };
        final List<Long> sleeps = new ArrayList<>();
        final List<Long> sleepEnds = new ArrayList<>(); // the clock when each sleep ended
        long firstEnd = -1;
        int attempts;
        boolean result;

        Run(boolean[] answers, long[] costMs) {
            result = DozeApplyRetry.run(() -> {
                if (++attempts > RUNAWAY) throw new AssertionError("runaway: more than " + RUNAWAY + " attempts");
                int i = Math.min(attempts - 1, answers.length - 1);
                now[0] += costMs[Math.min(attempts - 1, costMs.length - 1)];
                if (firstEnd < 0) firstEnd = now[0];
                return answers[i];
            }, () -> now[0], ms -> { sleeps.add(ms); now[0] += ms; sleepEnds.add(now[0]); });
        }

        long totalSleep() { long t = 0; for (long s : sleeps) t += s; return t; }
    }

    private static void check(String name, boolean cond, String why) {
        if (!cond) { failed++; System.out.println("FAIL " + name + ": " + why); }
    }

    private static void run(String name, Runnable body) {
        int before = failed;
        try { body.run(); } catch (Throwable t) { failed++; System.out.println("FAIL " + name + ": threw " + t); return; }
        if (failed == before) System.out.println("ok " + name);
    }

    public static void main(String[] args) {
        run("the bound is 10 s and the back-off 1 s", () -> {
            check("bound", DozeApplyRetry.BUDGET_MS == 10_000, "BUDGET_MS=" + DozeApplyRetry.BUDGET_MS);
            check("backoff", DozeApplyRetry.BACKOFF_MS == 1_000, "BACKOFF_MS=" + DozeApplyRetry.BACKOFF_MS);
        });
        run("holds on the first try: no sleep", () -> {
            Run r = new Run(new boolean[] { true }, new long[] { 0 });
            check("first", r.result, "returned false");
            check("first", r.attempts == 1, "attempts=" + r.attempts);
            check("first", r.sleeps.isEmpty(), "sleeps=" + r.sleeps);
        });
        run("holds on the fourth try: three sleeps of BACKOFF_MS", () -> {
            Run r = new Run(new boolean[] { false, false, false, true }, new long[] { 0 });
            long b = DozeApplyRetry.BACKOFF_MS;
            check("fourth", r.result, "returned false");
            check("fourth", r.attempts == 4, "attempts=" + r.attempts);
            check("fourth", r.sleeps.equals(List.of(b, b, b)), "sleeps=" + r.sleeps);
        });
        run("never holds: stops once BUDGET_MS has passed, returns false", () -> {
            Run r = new Run(new boolean[] { false }, new long[] { 0 });
            check("never", !r.result, "returned true");
            check("never", r.totalSleep() <= DozeApplyRetry.BUDGET_MS, "slept " + r.totalSleep());
            check("never", r.now[0] - r.firstEnd >= DozeApplyRetry.BUDGET_MS,
                    "stopped " + (r.now[0] - r.firstEnd) + " ms after the first attempt, before the budget ran out");
            long expect = DozeApplyRetry.BUDGET_MS / DozeApplyRetry.BACKOFF_MS;
            check("never", r.sleeps.size() == expect && r.attempts == expect + 1,
                    "sleeps=" + r.sleeps.size() + " attempts=" + r.attempts);
        });
        run("a slow attempt that eats the budget is not retried", () -> {
            Run r = new Run(new boolean[] { false }, new long[] { 0, DozeApplyRetry.BUDGET_MS });
            check("slow", !r.result, "returned true");
            check("slow", r.attempts == 2, "attempts=" + r.attempts);
            check("slow", r.sleeps.size() == 1, "sleeps=" + r.sleeps);
        });
        run("a slow first attempt still gets its retries (the budget runs from its end)", () -> {
            Run r = new Run(new boolean[] { false, true }, new long[] { 30_000, 0 });
            check("slowfirst", r.result, "returned false");
            check("slowfirst", r.attempts == 2, "attempts=" + r.attempts);
        });
        run("the last sleep is cut to what is left", () -> {
            Run r = new Run(new boolean[] { false }, new long[] { 300 });
            int k = r.sleeps.size();
            check("cut", k >= 2, "sleeps=" + r.sleeps);
            for (int i = 0; i < k - 1; i++) {
                check("cut", r.sleeps.get(i) == DozeApplyRetry.BACKOFF_MS, "sleep " + i + " = " + r.sleeps.get(i));
            }
            check("cut", k >= 1 && r.sleeps.get(k - 1) < DozeApplyRetry.BACKOFF_MS, "last sleep " + r.sleeps);
            check("cut", k >= 1 && r.sleepEnds.get(k - 1) - r.firstEnd == DozeApplyRetry.BUDGET_MS,
                    "the last sleep ended " + (k >= 1 ? r.sleepEnds.get(k - 1) - r.firstEnd : -1)
                            + " ms after the first attempt, not at the budget");
            check("cut", !r.result, "returned true");
        });
        run("the first read keeps 30 s", () ->
                check("read0", DozeApplyRetry.readTimeoutMs(0, -1, 0) == 30_000, "got " + DozeApplyRetry.readTimeoutMs(0, -1, 0)));
        run("a later read waits for the budget left", () ->
                check("read1", DozeApplyRetry.readTimeoutMs(1, 5_000, 8_000) == 7_000,
                        "got " + DozeApplyRetry.readTimeoutMs(1, 5_000, 8_000)));
        run("a later read waits at least 1 s", () -> {
            check("floor", DozeApplyRetry.readTimeoutMs(2, 0, 9_800) == 1_000, "got " + DozeApplyRetry.readTimeoutMs(2, 0, 9_800));
            check("floor", DozeApplyRetry.readTimeoutMs(2, 0, 20_000) == 1_000, "got " + DozeApplyRetry.readTimeoutMs(2, 0, 20_000));
        });
        // NWP-20261117-06: the session's capture asks GET-DOZE-ARM first; only an exact UNARMED keeps the record.
        run("mayCapture refuses an UNARMED session", () ->
                check("unarmed", !DozeApplyRetry.mayCapture("UNARMED"), "UNARMED may capture"));
        run("mayCapture lets an ARMED session capture", () ->
                check("armed", DozeApplyRetry.mayCapture("ARMED"), "ARMED may not capture"));
        run("mayCapture captures with no session (NONE)", () ->
                check("none", DozeApplyRetry.mayCapture("NONE"), "NONE may not capture"));
        run("mayCapture captures on an empty reply (no answer)", () ->
                check("empty", DozeApplyRetry.mayCapture(""), "an empty reply may not capture"));
        run("mayCapture captures on no reply (null)", () ->
                check("null", DozeApplyRetry.mayCapture(null), "null may not capture"));
        System.out.println(failed == 0 ? "all cases pass" : failed + " check(s) failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
