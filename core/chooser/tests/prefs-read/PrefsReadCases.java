package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** NWP-20261118-11: cases for PrefsRead, run by core/vendor-common/bin/test-prefs-read-java.sh on a fake clock. The
 *  sleeper adds its ms to the clock and records them; the reader records each read cap and, on a failed read, adds
 *  the cap to the clock (a read that runs to its timeout). No case sleeps for real. Exits 1 on a failed case. */
final class PrefsReadCases {
    private static int failed = 0;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failed++;
    }

    /** One run of PrefsRead.read: answers[i] is the reply of read i (null = a failed read), the last one repeats. */
    private static final class Run {
        final long[] now = {0};
        final List<Integer> caps = new ArrayList<>();
        final List<Long> sleeps = new ArrayList<>();
        final List<Long> starts = new ArrayList<>();
        List<String> result;

        Run(List<List<String>> answers, boolean failTakesCap) { this(answers, failTakesCap ? -1 : 0); }

        /** failMs: how long a failed read takes; -1 = it runs to its cap. */
        Run(List<List<String>> answers, long failMs) {
            result = PrefsRead.read(cap -> {
                caps.add(cap);
                starts.add(now[0]);
                if (caps.size() > 1000) throw new IllegalStateException("unbounded: over 1000 reads");
                List<String> a = answers.get(Math.min(caps.size(), answers.size()) - 1);
                if (a == null) now[0] += failMs < 0 ? cap : failMs;
                return a;
            }, () -> now[0], ms -> { sleeps.add(ms); now[0] += ms; });
        }

        long sleepSum() { long s = 0; for (long v : sleeps) s += v; return s; }
        long laterCapSum() { long s = 0; for (int i = 1; i < caps.size(); i++) s += caps.get(i); return s; }
    }

    public static void main(String[] args) {
        List<String> prefs = Arrays.asList("idle=0", "tz=");

        // C1: a reader that answers on the first try is asked once, with the 30 s cap, and never sleeps.
        Run c1 = new Run(Collections.singletonList(prefs), true);
        check(c1.caps.size() == 1, "C1 an answer on the first try is asked once (asked " + c1.caps.size() + ")");
        check(c1.caps.size() >= 1 && c1.caps.get(0) == 30_000, "C1 the first read cap is 30 s (" + c1.caps + ")");
        check(c1.sleeps.isEmpty(), "C1 no wait after an answer (" + c1.sleeps + ")");
        check(prefs.equals(c1.result), "C1 returns the reply (" + c1.result + ")");

        // C2: fails twice at once (no socket), then answers: the third answer comes back, after three reads.
        Run c2 = new Run(Arrays.asList(null, null, Collections.singletonList("idle=0")), false);
        check(Collections.singletonList("idle=0").equals(c2.result), "C2 fails twice then answers: returns the third answer (" + c2.result + ")");
        check(c2.caps.size() == 3, "C2 three reads (asked " + c2.caps.size() + ")");
        check(c2.caps.size() >= 1 && c2.caps.get(0) == 30_000, "C2 the first read cap is 30 s (" + c2.caps + ")");
        boolean c2later = c2.caps.size() > 1;
        for (int i = 1; i < c2.caps.size(); i++) c2later &= c2.caps.get(i) >= 1_000 && c2.caps.get(i) <= 10_000;
        check(c2later, "C2 each later read cap is within [1 s, 10 s] (" + c2.caps + ")");

        // C3: always fails, every read running to its cap. Bounded, within the budget, and null.
        Run c3 = new Run(Collections.singletonList(null), true);
        check(c3.result == null, "C3 a reader that always fails gives null (" + c3.result + ")");
        check(c3.caps.size() >= 2 && c3.caps.size() <= 12, "C3 a bounded number of reads, at least one retry (asked " + c3.caps.size() + ")");
        check(c3.caps.size() >= 1 && c3.caps.get(0) == 30_000, "C3 the first read cap is 30 s (" + c3.caps + ")");
        boolean c3later = true;
        for (int i = 1; i < c3.caps.size(); i++) c3later &= c3.caps.get(i) >= 1_000 && c3.caps.get(i) < 30_000;
        check(c3later, "C3 every later read cap is at least 1 s and under 30 s (" + c3.caps + ")");
        // The last read's 1 s floor may pass the budget by at most one MIN_READ_MS.
        long c3spent = c3.sleepSum() + c3.laterCapSum();
        check(c3spent <= 10_000 + 1_000, "C3 the waits plus the later read caps stay within the 10 s budget (+ one 1 s floor): " + c3spent + " ms");

        // C3b: always fails at once (a read that takes 0 ms, e.g. no socket): retries 1 s apart, the waits within 10 s.
        Run c3b = new Run(Collections.singletonList(null), false);
        check(c3b.result == null, "C3b an instant failure every time gives null");
        check(c3b.caps.size() >= 2 && c3b.caps.size() <= 12, "C3b a bounded number of reads (asked " + c3b.caps.size() + ")");
        check(c3b.sleepSum() <= 10_000 && c3b.sleepSum() >= 9_000, "C3b the waits add up to the 10 s budget, no more (" + c3b.sleepSum() + " ms)");
        boolean c3bWait = true;
        for (long s : c3b.sleeps) c3bWait &= s >= 1 && s <= 1_000;
        check(c3bWait, "C3b each wait is at most 1 s (" + c3b.sleeps + ")");
        boolean c3bLater = true;
        for (int i = 1; i < c3b.caps.size(); i++) c3bLater &= c3b.caps.get(i) >= 1_000 && c3b.caps.get(i) < 30_000;
        check(c3bLater, "C3b every later read cap is at least 1 s and under 30 s (" + c3b.caps + ")");

        // C3c: each failed read takes 300 ms, so the budget does not end on a whole wait: the last wait is cut to what
        // is left, and the last read starts no later than 10 s after the first read ended.
        Run c3c = new Run(Collections.singletonList(null), 300L);
        check(c3c.result == null, "C3c a 300 ms failure every time gives null");
        long firstEnd = c3c.caps.isEmpty() ? 0 : 300L;
        long lastStart = c3c.starts.isEmpty() ? 0 : c3c.starts.get(c3c.starts.size() - 1);
        check(c3c.caps.size() >= 2 && lastStart - firstEnd <= 10_000,
                "C3c the last read starts within the 10 s budget after the first read ended (" + (lastStart - firstEnd) + " ms)");
        check(c3c.sleepSum() < 10_000, "C3c the last wait is cut to what is left (waits " + c3c.sleeps + ")");

        // C4: an empty list is a reply (no saved prefs), not a failed read: returned as is, after one read.
        Run c4 = new Run(Collections.singletonList(Collections.<String>emptyList()), true);
        check(c4.result != null && c4.result.isEmpty(), "C4 an empty list is returned as an empty list, not null (" + c4.result + ")");
        check(c4.caps.size() == 1, "C4 an empty list is not retried (asked " + c4.caps.size() + ")");

        System.out.println(failed == 0 ? "all PrefsRead cases pass" : failed + " PrefsRead case(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
