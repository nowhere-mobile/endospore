package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;

/** NWP-20261118-05: SweepBusy and SweepOutcome.BUSY, compiled with those two files ALONE and executed by
 *  core/vendor-common/bin/test-sweep-busy-java.sh. Nothing sleeps: every wait is a number added to a fake clock. */
public final class SweepBusyCases {
    static int bad = 0;
    static void check(String id, boolean cond, String what) {
        if (cond) return;
        System.out.println("FAIL " + id + " " + what);
        bad++;
    }
    static String show(String s) { return s == null ? "null" : "\"" + s.replace("\n", "\\n") + "\""; }

    /** What one simulated sweep did. */
    static final class Run {
        final List<String> sent = new ArrayList<>(); // one AUTO-SWEEP-APP token per app, in order
        int[] calls;                                 // MATERIALIZE-APP calls per app
        int retries;                                 // RETRY steps over the whole sweep
        long clock;                                  // the fake clock: the sum of every wait
        boolean stopped;                             // the sweep ended on STOP
        int left;                                    // apps left for the next sweep on STOP
        int maxTotal;                                // the largest done + pending the queue showed
    }

    /** The end token materializeLocked records for a MATERIALIZE-APP reply. */
    static String endOf(String reply) {
        if (SweepBusy.isBusy(reply)) return SweepOutcome.BUSY;
        if (reply != null && reply.startsWith("OK")) return SweepOutcome.INSTALLED;
        return SweepOutcome.FETCH_FAILED;
    }

    /** sweepAuto's materialise loop, step for step: app i takes its next scripted reply (the last one repeats), the
     *  end goes through SweepBusy.step, RETRY waits waitMs and takes the SAME index, NEXT and STOP send one token,
     *  and STOP leaves the rest. The queue mirrors qEnqueue / qDrop / qFinish: the busy arm drops the app, any other
     *  end finishes it, and an empty queue resets the done count. */
    static Run simulate(List<List<String>> replies) {
        int n = replies.size();
        Run r = new Run();
        r.calls = new int[n];
        int[] pos = new int[n];
        LinkedHashSet<Integer> pending = new LinkedHashSet<>();
        int done = 0;
        for (int k = 0; k < n; k++) pending.add(k); // qEnqueue(work)
        int busyTries = 0;
        long busyWaited = 0;
        int guard = 0;
        for (int i = 0; i < n; i++) {
            if (++guard > 1000) { check("B3", false, "the sweep did not end after 1000 passes"); break; }
            List<String> s = replies.get(i);
            String reply = s.get(Math.min(pos[i]++, s.size() - 1));
            r.calls[i]++;
            pending.add(i); // materializeLocked's qEnqueue(group)
            String end = endOf(reply);
            if (SweepOutcome.BUSY.equals(end)) pending.remove(i); // the busy arm's qDrop(group)
            else if (pending.remove(i)) done++;                  // materializeAndInstall's qFinish(pkg)
            if (pending.isEmpty()) done = 0;
            r.maxTotal = Math.max(r.maxTotal, done + pending.size());
            SweepBusy.Step step = SweepBusy.step(end, busyTries, busyWaited);
            if (step == SweepBusy.Step.RETRY) {
                long w = SweepBusy.waitMs(busyTries);
                busyTries++;
                busyWaited += w;
                r.clock += w;
                r.retries++;
                i--;
                continue;
            }
            r.sent.add(end);
            busyTries = 0;
            busyWaited = 0;
            if (step == SweepBusy.Step.STOP) {
                for (int k = i + 1; k < n; k++) pending.remove(k); // qDrop(SignOutGate.rest(work, i + 1))
                r.stopped = true;
                r.left = n - i;
                break;
            }
        }
        return r;
    }

    static List<String> script(String... replies) { return Arrays.asList(replies); }

    public static void main(String[] a) {
        // B1 isBusy's table.
        for (String y : new String[] { "ERR-WORKER-BUSY", "ERR-WORKER-BUSY\n", "  ERR-WORKER-BUSY  ", "ERR-WORKER-BUSY extra",
                "\tERR-WORKER-BUSY\tx" })
            check("B1", SweepBusy.isBusy(y), "isBusy(" + show(y) + ") is false, want true");
        for (String no : new String[] { null, "", "   ", "\n", "ERR-NOTREADY", "ERR-WORKER-BUSYX", "ERR-WORKER", "OK com.x",
                "OK", "NONE", "LOCAL", "err-worker-busy", "ERR-ARG", "xERR-WORKER-BUSY" })
            check("B1", !SweepBusy.isBusy(no), "isBusy(" + show(no) + ") is true, want false");

        // B2 the schedule grows, every wait is positive, and its total never passes the bound.
        check("B2", SweepBusy.waitMs(1) > SweepBusy.waitMs(0), "waitMs(1) " + SweepBusy.waitMs(1)
                + " does not grow past waitMs(0) " + SweepBusy.waitMs(0));
        for (int k = 0; k <= 20; k++) {
            check("B2", SweepBusy.waitMs(k) > 0, "waitMs(" + k + ") = " + SweepBusy.waitMs(k) + ", want > 0");
            check("B2", SweepBusy.waitMs(k + 1) >= SweepBusy.waitMs(k), "waitMs(" + (k + 1) + ") < waitMs(" + k + ")");
        }
        check("B2", SweepBusy.BOUND_MS > 0 && SweepBusy.BOUND_MS < 600_000L,
                "BOUND_MS " + SweepBusy.BOUND_MS + " is not below the daemon's 10 min autoSweepLease");
        {
            int k = 0;
            long w = 0;
            while (SweepBusy.step(SweepOutcome.BUSY, k, w) == SweepBusy.Step.RETRY && k < 100) { w += SweepBusy.waitMs(k); k++; }
            check("B2", k > 0, "step(busy, 0, 0) is not RETRY: a busy app is never retried");
            check("B2", k < 100, "step(busy, ...) is RETRY 100 times: the wait has no bound");
            check("B2", w <= SweepBusy.BOUND_MS, "the RETRY run waits " + w + " ms, past BOUND_MS " + SweepBusy.BOUND_MS);
            check("B2", SweepBusy.step(SweepOutcome.BUSY, k, w) == SweepBusy.Step.STOP,
                    "the end of the RETRY run is " + SweepBusy.step(SweepOutcome.BUSY, k, w) + ", want STOP");
        }
        for (int k = 0; k <= 20; k++) {
            long wk = SweepBusy.waitMs(k);
            for (long w : new long[] { SweepBusy.BOUND_MS - wk + 1, SweepBusy.BOUND_MS, SweepBusy.BOUND_MS + 1, 10 * SweepBusy.BOUND_MS })
                check("B2", SweepBusy.step(SweepOutcome.BUSY, k, w) == SweepBusy.Step.STOP,
                        "step(busy, " + k + ", " + w + ") is " + SweepBusy.step(SweepOutcome.BUSY, k, w) + ": past the bound, want STOP");
            check("B2", SweepBusy.step(SweepOutcome.BUSY, k, SweepBusy.BOUND_MS - wk) == SweepBusy.Step.RETRY,
                    "step(busy, " + k + ", BOUND_MS - waitMs) is not RETRY: a wait that ends at the bound is allowed");
        }
        for (String t : new String[] { SweepOutcome.INSTALLED, SweepOutcome.ALREADY, SweepOutcome.RESTORE_ONLY,
                SweepOutcome.FETCH_FAILED, SweepOutcome.INSTALL_FAILED, SweepOutcome.STOPPED, SweepOutcome.ERROR, null })
            check("B2", SweepBusy.step(t, 0, 0) == SweepBusy.Step.NEXT, "step(" + show(t) + ", 0, 0) is not NEXT");

        // B3 a scripted sweep.
        {
            Run r = simulate(Arrays.asList(script("ERR-WORKER-BUSY", "ERR-WORKER-BUSY", "OK app1"), script("OK app2")));
            check("B3", r.calls[0] == 3 && r.calls[1] == 1, "[busy, busy, OK] + [OK]: calls " + Arrays.toString(r.calls)
                    + ", want [3, 1] (the SAME app retried twice)");
            check("B3", r.retries == 2, "[busy, busy, OK] + [OK]: " + r.retries + " retries, want 2");
            check("B3", r.sent.equals(script("installed", "installed")), "[busy, busy, OK] + [OK]: sent " + r.sent
                    + ", want [installed, installed] (no fetch-failed, no busy)");
            check("B3", !r.stopped, "[busy, busy, OK] + [OK]: the sweep stopped");
            check("B3", r.clock == SweepBusy.waitMs(0) + SweepBusy.waitMs(1), "[busy, busy, OK]: waited " + r.clock
                    + " ms, want waitMs(0) + waitMs(1)");
            check("B3", r.maxTotal == 2, "[busy, busy, OK] + [OK]: the queue total reached " + r.maxTotal
                    + ", want 2 (a retry must not count the app done)");
        }
        {
            Run r = simulate(Arrays.asList(script("ERR-WORKER-BUSY"), script("OK app2"), script("OK app3")));
            check("B3", r.stopped, "[busy forever] x 3 apps: the sweep did not STOP");
            check("B3", r.clock <= SweepBusy.BOUND_MS, "[busy forever]: waited " + r.clock + " ms, past BOUND_MS");
            check("B3", r.sent.equals(script("busy")), "[busy forever]: sent " + r.sent + ", want exactly [busy]");
            check("B3", r.calls[1] == 0 && r.calls[2] == 0, "[busy forever]: apps 2 and 3 were called "
                    + Arrays.toString(r.calls) + ", want never");
            check("B3", r.left == 3, "[busy forever]: " + r.left + " app(s) left, want 3");
        }
        {
            Run r = simulate(Arrays.asList(script("NONE"), script("OK app2")));
            check("B3", r.calls[0] == 1 && r.retries == 0, "[fetch-failed]: calls " + Arrays.toString(r.calls) + ", "
                    + r.retries + " retries, want one call and no retry");
            check("B3", r.sent.equals(script("fetch-failed", "installed")), "[fetch-failed] + [OK]: sent " + r.sent
                    + ", want [fetch-failed, installed]");
        }
        {
            Run r = simulate(Arrays.asList(script("ERR-NOTREADY")));
            check("B3", r.retries == 0 && r.sent.equals(script("fetch-failed")), "[ERR-NOTREADY]: " + r.retries
                    + " retries, sent " + r.sent + ", want no retry and [fetch-failed]");
        }

        // B4 the wire accepts the token.
        check("B4", "AUTO-SWEEP-APP\n1\n3\nbusy\n5\n".equals(SweepOutcome.request(1, 3, "busy", 5)),
                "request(1, 3, busy, 5) = " + show(SweepOutcome.request(1, 3, "busy", 5)));
        check("B4", Arrays.asList(SweepOutcome.TOKENS).contains("busy"), "TOKENS does not hold \"busy\"");
        check("B4", "busy".equals(SweepOutcome.BUSY), "SweepOutcome.BUSY is " + show(SweepOutcome.BUSY));

        if (bad > 0) System.exit(1);
        System.out.println("ok B1-B4 isBusy, the bounded schedule, the scripted sweep and the busy token");
    }
}
