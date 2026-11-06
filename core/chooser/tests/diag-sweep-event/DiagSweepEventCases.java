package com.nowhere.chooser;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261126-12: the cases for DiagSweepEvent, run by core/vendor-common/bin/test-diag-sweep-event-java.sh. */
public final class DiagSweepEventCases {
    // The agent's daySummaryEventRe (core/agent/day_summary.go), byte for byte; the suite's R1 pins the two together.
    static final String AGENT_RE = "^sweep ([0-9]{1,12}) ([0-9]{1,12}) ([0-9]{1,12}) ([0-9]{1,12})$";

    private static int failures = 0;

    private static void check(String id, String what, boolean pass) {
        System.out.println((pass ? "ok " : "FAIL ") + id + " " + what);
        if (!pass) failures++;
    }

    private static boolean agentTakes(String s) {
        return s != null && Pattern.compile(AGENT_RE).matcher(s).matches();
    }

    public static void main(String[] args) {
        String c1 = DiagSweepEvent.arg(3, 2, 1, 4500);
        check("C1", "arg(3, 2, 1, 4500) is exactly \"sweep 3 2 1 4500\"", "sweep 3 2 1 4500".equals(c1));

        String c4 = DiagSweepEvent.arg(1, 1, 0, 1_000_000_000_000L);
        Matcher m = c1 == null ? null : Pattern.compile(AGENT_RE).matcher(c1);
        boolean order = m != null && m.matches() && "2".equals(m.group(2)) && "1".equals(m.group(3));
        check("C2", "the agent's regex takes every line arg makes, and ok comes before fail",
                agentTakes(c1) && agentTakes(DiagSweepEvent.arg(0, 0, 0, 0))
                        && agentTakes(DiagSweepEvent.arg(Integer.MAX_VALUE, Integer.MAX_VALUE, 0, DiagSweepEvent.MAX_MS))
                        && agentTakes(c4) && order);

        check("C3", "a negative apps, ok, fail or ms is null",
                DiagSweepEvent.arg(-1, 0, 0, 0) == null && DiagSweepEvent.arg(0, -1, 0, 0) == null
                        && DiagSweepEvent.arg(0, 0, -1, 0) == null && DiagSweepEvent.arg(0, 0, 0, -1) == null);

        String c4max = DiagSweepEvent.arg(1, 1, 0, Long.MAX_VALUE);
        check("C4", "ms is clamped to 12 digits (999999999999)",
                "sweep 1 1 0 999999999999".equals(c4) && "sweep 1 1 0 999999999999".equals(c4max)
                        && "sweep 1 1 0 999999999999".equals(DiagSweepEvent.arg(1, 1, 0, DiagSweepEvent.MAX_MS)));

        boolean oneLine = true;
        for (String s : new String[] {c1, c4, c4max}) {
            if (s == null || s.indexOf('\n') >= 0 || s.indexOf('\r') >= 0) oneLine = false;
        }
        check("C5", "no line holds a newline or a carriage return", oneLine);

        System.exit(failures == 0 ? 0 : 1);
    }
}
