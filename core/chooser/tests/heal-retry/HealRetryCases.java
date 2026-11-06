package com.nowhere.chooser;

/** NWP-20261128-05: the install heal's retry policy, HealRetry.delayMs, under javac alone (test-heal-retry-java.sh). */
public final class HealRetryCases {
    static int bad = 0;
    static int caseBad;

    interface Case { void run(); }

    // run: one case id in its own try/catch; prints exactly one ok line on a pass.
    static void run(String id, String what, Case c) {
        caseBad = 0;
        try { c.run(); } catch (Throwable t) { System.out.println("FAIL " + id + " threw " + t); caseBad++; }
        if (caseBad == 0) System.out.println("ok " + id + " " + what);
        bad += caseBad;
    }
    static void eq(String id, String what, long want, long got) {
        if (want == got) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        caseBad++;
    }
    static void delay(String id, String reply, int attempt, long want) {
        eq(id, "delayMs(" + (reply == null ? "null" : "\"" + reply + "\"") + ", " + attempt + ")", want,
                HealRetry.delayMs(reply, attempt));
    }

    public static void main(String[] a) {
        run("R1", "OK <pkg>, OK NOSRC and OK LOCAL stop", () -> {
            delay("R1", "OK com.example.app", 1, -1);
            delay("R1", "OK NOSRC", 1, -1);
            delay("R1", "OK LOCAL", 1, -1);
        });
        run("R2", "NONE (signed out) stops", () -> delay("R2", "NONE", 1, -1));
        run("R3", "ERR-PKG stops", () -> delay("R3", "ERR-PKG", 1, -1));
        run("R4", "no reply (timeout, no daemon) retries after 60 s", () -> {
            delay("R4", "", 1, 60_000L);
            delay("R4", null, 1, 60_000L);
            delay("R4", "  ", 1, 60_000L);
        });
        run("R5", "ERR-WORKER-BUSY, ERR-TIMEOUT and ERR-NOTREADY retry after 60 s", () -> {
            delay("R5", "ERR-WORKER-BUSY", 1, 60_000L);
            delay("R5", "ERR-TIMEOUT", 1, 60_000L);
            delay("R5", "ERR-NOTREADY", 1, 60_000L);
            delay("R5", "ERR-NOTREADY hold kept", 1, 60_000L);
        });
        run("R6", "a reply the policy does not name stops", () -> {
            delay("R6", "ERR-SOMETHING", 1, -1);
            delay("R6", "ERR-NOTREADYX", 1, -1);
            delay("R6", "BLANK", 1, -1);
            delay("R6", "garbage", 1, -1);
        });
        run("R7", "the wait doubles: 60, 120, 240, 480, 960, 1920 s", () -> {
            long[] want = {60_000L, 120_000L, 240_000L, 480_000L, 960_000L, 1_920_000L};
            long sum = 0;
            for (int i = 0; i < want.length; i++) {
                delay("R7", "", i + 1, want[i]);
                sum += HealRetry.delayMs("", i + 1);
            }
            eq("R7", "the six waits in all", 3_780_000L, sum);
        });
        run("R8", "the bound: MAX_TRIES is 7, and attempt 7 or more (or below 1) stops", () -> {
            eq("R8", "MAX_TRIES", 7, HealRetry.MAX_TRIES);
            delay("R8", "", 7, -1);
            delay("R8", "", 8, -1);
            delay("R8", "ERR-WORKER-BUSY", 7, -1);
            delay("R8", "ERR-WORKER-BUSY", 8, -1);
            delay("R8", "", 0, -1);
        });
        run("R9", "a heal whose restore never lands sends exactly 7 tries", () -> {
            int sent = 0;
            for (int attempt = 1; attempt <= 100; attempt++) {
                sent++;
                if (HealRetry.delayMs("ERR-WORKER-BUSY", attempt) < 0) break;
            }
            eq("R9", "tries sent", 7, sent);
        });
        if (bad > 0) System.exit(1);
    }
}
