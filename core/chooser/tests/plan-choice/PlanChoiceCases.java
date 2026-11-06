package com.nowhere.chooser;

/** NWP-20261031-11: the cases for PlanChoice (made-up sizes and epochs only). */
public final class PlanChoiceCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + want + " got " + got);
        }
    }

    private static Object guard(java.util.concurrent.Callable<Object> c) {
        try { return c.call(); } catch (Throwable t) { return "threw " + t; }
    }

    private static final long DAY = 86400;
    private static final long NOW = 1_800_000_000L;
    private static final long EP = NOW / DAY; // the epoch index "now" falls in

    private static boolean ask(String line) {
        return (Boolean) guard(() -> PlanChoice.shouldAsk(line, NOW));
    }

    public static void main(String[] args) {
        eq("live plan", true, ask("OK credit=30 through=" + (EP + 20) + " epochsec=86400 sub=0 plangb=10"));
        eq("missing epochsec, otherwise live", false, ask("OK credit=30 through=" + (EP + 20) + " plangb=10"));
        eq("missing epochsec, huge through", false, ask("OK through=3000 plangb=10"));
        eq("malformed epochsec, otherwise live", false,
                ask("OK through=" + (EP + 20) + " epochsec=garbage plangb=10"));
        eq("expired term", false, ask("OK credit=30 through=" + (EP - 5) + " epochsec=86400 plangb=10"));
        eq("plangb absent", false, ask("OK credit=30 through=" + (EP + 20) + " epochsec=86400"));
        eq("plangb 0", false, ask("OK credit=30 through=" + (EP + 20) + " epochsec=86400 plangb=0"));
        eq("NONE", false, ask("NONE"));
        eq("garbage", false, ask("garbage plangb=10 through=99999999999"));
        eq("empty", false, ask(""));
        eq("null", false, ask(null));
        eq("missing through", false, ask("OK credit=30 epochsec=86400 plangb=10"));
        eq("non-numeric plangb", false, ask("OK through=" + (EP + 20) + " epochsec=86400 plangb=ten"));
        eq("zero epochsec", false, ask("OK through=" + (EP + 20) + " epochsec=0 plangb=10"));

        eq("last paid epoch", true, ask("OK through=" + EP + " epochsec=86400 plangb=10"));
        eq("start of the last paid epoch", true, (Boolean) guard(() -> PlanChoice.shouldAsk(
                "OK through=" + EP + " epochsec=86400 plangb=10", EP * DAY)));
        eq("first second after the term", false, (Boolean) guard(() -> PlanChoice.shouldAsk(
                "OK through=" + EP + " epochsec=86400 plangb=10", (EP + 1) * DAY)));
        eq("epoch after the last", false, ask("OK through=" + (EP - 1) + " epochsec=86400 plangb=10"));

        eq("plain CLAIM", "CLAIM\nabc\n", guard(() -> PlanChoice.claimRequest("abc", false, false)));
        eq("plain CLAIM ignores keep", "CLAIM\nabc\n", guard(() -> PlanChoice.claimRequest("abc", false, true)));
        eq("CLAIM2 convert", "CLAIM2\nabc\nconvert\n", guard(() -> PlanChoice.claimRequest("abc", true, false)));
        eq("CLAIM2 keep", "CLAIM2\nabc\nkeep\n", guard(() -> PlanChoice.claimRequest("abc", true, true)));

        // h51 #5 (2026-11-01, docs/product-decisions.md): the two lines and their grey lines, verbatim.
        eq("CONVERT label", "Put all my time on the bigger plan (recommended)", PlanChoice.CONVERT);
        eq("CONVERT_NOTE", "Whichever is bigger, this code or my current plan, the other's time is added to it at its value.",
                PlanChoice.CONVERT_NOTE);
        eq("KEEP label", "Keep each plan at its own size", PlanChoice.KEEP);
        eq("KEEP_NOTE", "The bigger plan runs first and the smaller one starts when it ends.", PlanChoice.KEEP_NOTE);

        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("plan-choice: all cases ok");
    }
}
