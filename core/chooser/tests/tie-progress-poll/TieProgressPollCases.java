package com.nowhere.chooser;

/** TieProgressPoll: when the Tie screen's progress poll reads, waits or ends (NWP-20261129-32). Run by
 *  core/vendor-common/bin/test-tie-progress-poll-java.sh. */
public final class TieProgressPollCases {
    private static int fails = 0;

    private static void eq(String what, Object want, Object got) {
        if (!want.equals(got)) { fails++; System.out.println("  FAIL  " + what + ": want " + want + ", got " + got); }
    }

    private static void settled(String reply, boolean want) {
        eq("settled [" + reply + "]", want, TieProgressPoll.settled(reply));
    }

    public static void main(String[] a) {
        eq("POLL_MS is 5 s", 5000L, TieProgressPoll.POLL_MS);

        // step: all 16 combinations. STOP wins over WAIT, and only an attached, live, unsettled poll reads.
        final boolean[] tf = { true, false };
        int seen = 0;
        for (boolean attached : tf) for (boolean finishing : tf) for (boolean paused : tf) for (boolean settled : tf) {
            TieProgressPoll.Step want = !attached || finishing || settled ? TieProgressPoll.Step.STOP
                    : paused ? TieProgressPoll.Step.WAIT : TieProgressPoll.Step.READ;
            eq("step attached=" + attached + " finishing=" + finishing + " paused=" + paused + " settled=" + settled,
                    want, TieProgressPoll.step(attached, finishing, paused, settled));
            seen++;
        }
        eq("step table has 16 rows", 16, seen);

        // settled: nothing is still moving.
        settled("OK NONE\n", true);
        settled("OK\nMEDIA done 0 0\nAPPS done 0 0\n", true);
        settled("OK\nMEDIA done 0 0\n", true);
        settled("OK\nMEDIA done 0 0\nPHOTOS running 0 0\n", true);

        // settled: one row not done keeps the poll going, in either order.
        for (String state : new String[] { "running", "credit", "wifi", "net", "battery", "waiting" }) {
            settled("OK\nMEDIA " + state + " 5 10\nAPPS done 0 0\n", false);
            settled("OK\nMEDIA done 0 0\nAPPS " + state + " 5 10\n", false);
        }

        // settled: a failed or partial read keeps the poll going.
        settled("OK\n", false);
        settled("", false);
        settled(null, false);
        settled("ERR-NOSESSION", false);
        settled("OK\nMEDIA done 0\n", false);
        settled("OK\nPHOTOS done 0 0\n", false);

        if (fails > 0) { System.out.println("FAILED: " + fails); System.exit(1); }
        System.out.println("TieProgressPollCases: ok");
    }
}
