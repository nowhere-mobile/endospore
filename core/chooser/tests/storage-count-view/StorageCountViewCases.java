package com.nowhere.chooser;

/**
 * NWP-20261120-09: StorageCountView's cases -- the GET-STORAGE-BREAKDOWN-CACHED header parse, the age line and the
 * next-step rule of "What's using space" (h48 #6). Each label is unique: test-storage-count-view-java.sh --mutate names
 * the case each mutant must fail.
 */
public final class StorageCountViewCases {
    private static int n, failed;

    private static void eq(String label, Object got, Object want) {
        n++;
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + label + ": got [" + got + "] want [" + want + "]");
        }
    }

    private static final String[] STEP = {"LEGACY", "NO_SESSION", "WAIT", "RENDER", "DONE", "FAILED"};
    private static final String[] KIND = {"NONE", "PENDING", "OK", "UNKNOWN"};

    private static String kind(String header) { return KIND[StorageCountView.parse(header).kind]; }

    private static String step(String header, long shown) {
        return STEP[StorageCountView.next(StorageCountView.parse(header), shown)];
    }

    public static void main(String[] args) {
        final long T = 1700000000L;
        final String AGAIN = " · counting again…";

        // parse: each wire shape.
        eq("parse NONE", kind("NONE"), "NONE");
        StorageCountView.Cached c = StorageCountView.parse("PENDING 1 none");
        eq("parse PENDING 1 none kind", KIND[c.kind], "PENDING");
        eq("parse PENDING 1 none running", c.running, true);
        eq("parse PENDING 1 none lastErr", c.lastErr, "none");
        c = StorageCountView.parse("PENDING 0 ERR-WORKER-BUSY");
        eq("parse PENDING 0 ERR-WORKER-BUSY kind", KIND[c.kind], "PENDING");
        eq("parse PENDING 0 ERR-WORKER-BUSY running", c.running, false);
        eq("parse PENDING 0 ERR-WORKER-BUSY lastErr", c.lastErr, "ERR-WORKER-BUSY");
        c = StorageCountView.parse("PENDING 0 none");
        eq("parse PENDING 0 none kind", KIND[c.kind], "PENDING");
        eq("parse PENDING 0 none running", c.running, false);
        eq("parse PENDING 0 none lastErr", c.lastErr, "none");
        c = StorageCountView.parse("OK 2 1700000000 1 none");
        eq("parse OK kind", KIND[c.kind], "OK");
        eq("parse OK nbytes", c.nbytes, 2L);
        eq("parse OK countedAt", c.countedAtSec, T);
        eq("parse OK running", c.running, true);
        eq("parse OK lastErr", c.lastErr, "none");
        c = StorageCountView.parse("OK 2 1700000000 0 ERR-TIMEOUT");
        eq("parse OK not running", c.running, false);
        eq("parse OK lastErr token", c.lastErr, "ERR-TIMEOUT");
        eq("parse OK bad nbytes", kind("OK x 1700000000 1 none"), "UNKNOWN");
        eq("parse OK bad countedAt", kind("OK 2 17000x 0 none"), "UNKNOWN");
        eq("parse OK countedAt zero", kind("OK 2 0 0 none"), "UNKNOWN");
        eq("parse OK bad running", kind("OK 2 1700000000 2 none"), "UNKNOWN");
        eq("parse OK short", kind("OK 2"), "UNKNOWN");
        eq("parse ERR unknown verb", kind("ERR unknown verb"), "UNKNOWN");
        eq("parse empty", kind(""), "UNKNOWN");
        eq("parse null", kind(null), "UNKNOWN");
        eq("parse PENDING bad running", kind("PENDING 2 none"), "UNKNOWN");

        // ageLine: whole minutes, rounded down, at any age; the suffix while a fresh count runs.
        eq("age 0", StorageCountView.ageLine(T, T, false), "Counted less than a minute ago");
        eq("age 59", StorageCountView.ageLine(T + 59, T, false), "Counted less than a minute ago");
        eq("age 60", StorageCountView.ageLine(T + 60, T, false), "Counted 1 min ago");
        eq("age 719", StorageCountView.ageLine(T + 719, T, false), "Counted 11 min ago");
        eq("age 7200", StorageCountView.ageLine(T + 7200, T, false), "Counted 120 min ago");
        eq("age 0 running", StorageCountView.ageLine(T, T, true), "Counted less than a minute ago" + AGAIN);
        eq("age 59 running", StorageCountView.ageLine(T + 59, T, true), "Counted less than a minute ago" + AGAIN);
        eq("age 60 running", StorageCountView.ageLine(T + 60, T, true), "Counted 1 min ago" + AGAIN);
        eq("age 719 running", StorageCountView.ageLine(T + 719, T, true), "Counted 11 min ago" + AGAIN);
        eq("age 720 running (the decision's example)", StorageCountView.ageLine(T + 720, T, true),
                "Counted 12 min ago · counting again…");
        eq("age 7200 running", StorageCountView.ageLine(T + 7200, T, true), "Counted 120 min ago" + AGAIN);
        eq("age backwards clock", StorageCountView.ageLine(T - 30, T, false), "Counted less than a minute ago");
        eq("age backwards clock running", StorageCountView.ageLine(T - 30, T, true),
                "Counted less than a minute ago" + AGAIN);

        // next: one case per row of the step table.
        eq("next UNKNOWN is LEGACY", step("ERR unknown verb", 0), "LEGACY");
        eq("next empty read is LEGACY", step("", 0), "LEGACY");
        eq("next null Cached is LEGACY", STEP[StorageCountView.next(null, 0)], "LEGACY");
        eq("next NONE is NO_SESSION", step("NONE", 0), "NO_SESSION");
        eq("next PENDING running is WAIT", step("PENDING 1 none", 0), "WAIT");
        eq("next PENDING idle none is LEGACY", step("PENDING 0 none", 0), "LEGACY");
        eq("next PENDING idle ERR-WORKER-BUSY is FAILED", step("PENDING 0 ERR-WORKER-BUSY", 0), "FAILED");
        eq("next PENDING idle NONE token is FAILED", step("PENDING 0 NONE", 0), "FAILED");
        eq("next OK nothing shown running is RENDER", step("OK 2 1700000000 1 none", 0), "RENDER");
        eq("next OK nothing shown idle is RENDER", step("OK 2 1700000000 0 none", 0), "RENDER");
        eq("next OK not newer running is WAIT", step("OK 2 1700000000 1 none", T), "WAIT");
        eq("next OK not newer idle is DONE", step("OK 2 1700000000 0 none", T), "DONE");
        eq("next OK newer running is RENDER", step("OK 2 1700000060 1 none", T), "RENDER");
        eq("next OK newer idle is RENDER", step("OK 2 1700000060 0 none", T), "RENDER");
        eq("next OK not newer after a failed fresh count is DONE", step("OK 2 1700000000 0 ERR-TIMEOUT", T), "DONE");

        if (failed > 0) {
            System.out.println(failed + " of " + n + " cases FAILED");
            System.exit(1);
        }
        System.out.println("ok " + n + " cases");
    }
}
