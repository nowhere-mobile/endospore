package com.nowhere.chooser;

import com.nowhere.chooser.SigninFailure.Verdict;

/** NWP-20261023-08: the cases for SigninFailure (made-up replies only). */
public final class SigninFailureCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + show(want) + " got " + show(got));
        }
    }

    private static void check(String what, boolean ok) {
        if (!ok) { failed++; System.out.println("FAIL " + what); }
    }

    private static String show(Object o) { return o == null ? "null" : "\"" + o + "\""; }

    private static final String[] REPLIES = {
        "NOSTORE", "BLANK NET", "BLANK NET (anything)", "", null, "ERR-UNRECORDED", "ERR-CREATEUSER", "ERR-WORKER-BUSY", "ERR-TIMEOUT", "BLANK", "ERR-SOMETHING"
    };
    private static final boolean[] BOOLS = {false, true};

    /** The table, written out on its own -- not a call to of(). */
    private static Verdict expected(String reply, boolean progress, boolean create) {
        if ("NOSTORE".equals(reply)) return Verdict.STORE_HINT;
        if ("BLANK NET".equals(reply) || "BLANK NET (anything)".equals(reply)) return Verdict.STORE_UNREACHABLE;
        if (reply == null || reply.isEmpty() || "ERR-TIMEOUT".equals(reply)) return Verdict.TIMED_OUT;
        if ("ERR-WORKER-BUSY".equals(reply)) return Verdict.WORKER_BUSY;
        if ("ERR-UNRECORDED".equals(reply) || "ERR-CREATEUSER".equals(reply)) return Verdict.PHONE_FAULT;
        if (progress) return create ? Verdict.CREATE_FAILED : Verdict.OFFER_ROLLBACK;
        return Verdict.BLANK;
    }

    private static boolean isCredentialIndependent(String r) {
        return "NOSTORE".equals(r) || (r != null && r.startsWith("BLANK NET")) || r == null || r.isEmpty()
                || "ERR-UNRECORDED".equals(r) || "ERR-CREATEUSER".equals(r) || "ERR-WORKER-BUSY".equals(r) || "ERR-TIMEOUT".equals(r);
    }

    public static void main(String[] args) {
        final String blind = "Couldn't sign in — check your name, passphrase, and Wi-Fi";

        for (String r : REPLIES) for (boolean p : BOOLS) for (boolean c : BOOLS) {
            String id = "of(" + show(r) + ", progress=" + p + ", create=" + c + ")";
            Verdict got = SigninFailure.of(r, p, c);
            // (a) the table
            eq(id, expected(r, p, c), got);
            // (b) no network or phone fault reaches the rollback
            if (isCredentialIndependent(r)) check(id + " must never be OFFER_ROLLBACK", got != Verdict.OFFER_ROLLBACK);
            // (c) the rollback is a sign-in's, after progress, from a reply nothing earlier takes
            boolean rollback = !c && p && ("BLANK".equals(r) || "ERR-SOMETHING".equals(r));
            check(id + " OFFER_ROLLBACK iff " + rollback, (got == Verdict.OFFER_ROLLBACK) == rollback);
            // (d) BLANK NET is never the blind line
            if (r != null && r.startsWith("BLANK NET")) check(id + " must not be BLANK", got != Verdict.BLANK);
        }
        eq("a create with progress and a plain BLANK", Verdict.CREATE_FAILED, SigninFailure.of("BLANK", true, true));

        // (e) message(): today's strings, spelled out
        eq("STORE_UNREACHABLE", "Couldn't reach your storage — check your connection and try again.",
                SigninFailure.message(Verdict.STORE_UNREACHABLE, "BLANK NET", false));
        eq("TIMED_OUT create", "Couldn't finish setting up — check your connection and try again.",
                SigninFailure.message(Verdict.TIMED_OUT, "", true));
        eq("TIMED_OUT sign-in", "Signing in took too long — check your connection and try again.",
                SigninFailure.message(Verdict.TIMED_OUT, "", false));
        eq("CREATE_FAILED", "Couldn't finish setting up — check your connection and try again.",
                SigninFailure.message(Verdict.CREATE_FAILED, "BLANK", true));
        eq("PHONE_FAULT sign-in ERR-UNRECORDED",
                "The phone couldn't start your session (a storage error on the phone, not your passphrase). Nothing was changed — try again.",
                SigninFailure.message(Verdict.PHONE_FAULT, "ERR-UNRECORDED", false));
        eq("PHONE_FAULT sign-in ERR-CREATEUSER",
                "The phone couldn't start your session (a problem on the phone, not your passphrase). Nothing was changed — try again.",
                SigninFailure.message(Verdict.PHONE_FAULT, "ERR-CREATEUSER", false));
        for (String r : new String[] {"ERR-UNRECORDED", "ERR-CREATEUSER"}) {
            String create = SigninFailure.message(Verdict.PHONE_FAULT, r, true);
            eq("PHONE_FAULT create " + r,
                    "The phone couldn't open your new profile (a problem on the phone, not your passphrase). Tap Create again: if it says the profile already exists, sign in instead.",
                    create);
            check("create " + r + " says not your passphrase", create != null && create.contains("not your passphrase"));
            check("create " + r + " never says check your name", create != null && !create.contains("check your name"));
            check("create " + r + " never says Nothing was changed", create != null && !create.contains("Nothing was changed"));
        }
        String cu = SigninFailure.message(Verdict.PHONE_FAULT, "ERR-CREATEUSER", false);
        check("sign-in ERR-CREATEUSER says not your passphrase", cu != null && cu.contains("not your passphrase"));
        check("sign-in ERR-CREATEUSER never says check your name", cu != null && !cu.contains("check your name"));
        // NWP-20261023-02: a busy lane and a daemon timeout
        final String busyIn = "The phone is still finishing your last sign-in. Wait a minute, then try again.";
        final String busyCreate = "Your profile was created, but the phone is still finishing an earlier sign-in. Wait a minute, then sign in.";
        eq("WORKER_BUSY sign-in", busyIn, SigninFailure.message(Verdict.WORKER_BUSY, "ERR-WORKER-BUSY", false));
        eq("WORKER_BUSY create", busyCreate, SigninFailure.message(Verdict.WORKER_BUSY, "ERR-WORKER-BUSY", true));
        for (boolean c : BOOLS) {
            String m = SigninFailure.message(Verdict.WORKER_BUSY, "ERR-WORKER-BUSY", c);
            check("busy create=" + c + " says still finishing", m != null && m.contains("still finishing"));
            check("busy create=" + c + " never blames the credential",
                    m != null && !m.contains("check your name") && !m.contains("passphrase"));
            for (boolean p : BOOLS) {
                eq("ERR-WORKER-BUSY p=" + p + " c=" + c, Verdict.WORKER_BUSY, SigninFailure.of("ERR-WORKER-BUSY", p, c));
                eq("ERR-TIMEOUT p=" + p + " c=" + c, Verdict.TIMED_OUT, SigninFailure.of("ERR-TIMEOUT", p, c));
            }
        }
        eq("TIMED_OUT sign-in for ERR-TIMEOUT", "Signing in took too long — check your connection and try again.",
                SigninFailure.message(Verdict.TIMED_OUT, "ERR-TIMEOUT", false));
        eq("TIMED_OUT create for ERR-TIMEOUT", "Couldn't finish setting up — check your connection and try again.",
                SigninFailure.message(Verdict.TIMED_OUT, "ERR-TIMEOUT", true));
        for (Verdict v : new Verdict[] {Verdict.STORE_HINT, Verdict.OFFER_ROLLBACK, Verdict.BLANK})
            eq("message(" + v + ") is null", null, SigninFailure.message(v, "BLANK", false));
        for (Verdict v : Verdict.values()) for (String r : REPLIES) for (boolean c : BOOLS) {
            String m = SigninFailure.message(v, r, c);
            if (m != null) check("message(" + v + ", " + show(r) + ", " + c + ") is never the blind line", !blind.equals(m));
        }

        // shownCode (NWP-20261106-11, Q065): the daemon's vocabulary (core/agent/signin_fail.go), written out here on purpose
        final java.util.Set<String> vocab = new java.util.HashSet<>(java.util.Arrays.asList(
                "nostore", "unreachable", "slow", "busy", "phone-storage", "phone", "load"));
        eq("shownCode(STORE_HINT)", "nostore", SigninFailure.shownCode(Verdict.STORE_HINT, "NOSTORE"));
        eq("shownCode(STORE_UNREACHABLE)", "unreachable", SigninFailure.shownCode(Verdict.STORE_UNREACHABLE, "BLANK NET"));
        eq("shownCode(TIMED_OUT, empty)", "slow", SigninFailure.shownCode(Verdict.TIMED_OUT, ""));
        eq("shownCode(TIMED_OUT, ERR-TIMEOUT)", "slow", SigninFailure.shownCode(Verdict.TIMED_OUT, "ERR-TIMEOUT"));
        eq("shownCode(WORKER_BUSY)", "busy", SigninFailure.shownCode(Verdict.WORKER_BUSY, "ERR-WORKER-BUSY"));
        eq("shownCode(PHONE_FAULT, ERR-UNRECORDED)", "phone-storage", SigninFailure.shownCode(Verdict.PHONE_FAULT, "ERR-UNRECORDED"));
        eq("shownCode(PHONE_FAULT, ERR-CREATEUSER)", "phone", SigninFailure.shownCode(Verdict.PHONE_FAULT, "ERR-CREATEUSER"));
        eq("shownCode(PHONE_FAULT, null)", "phone", SigninFailure.shownCode(Verdict.PHONE_FAULT, null));
        eq("shownCode(OFFER_ROLLBACK)", "load", SigninFailure.shownCode(Verdict.OFFER_ROLLBACK, "BLANK"));
        eq("shownCode(BLANK) is null", null, SigninFailure.shownCode(Verdict.BLANK, "BLANK"));
        eq("shownCode(CREATE_FAILED) is null", null, SigninFailure.shownCode(Verdict.CREATE_FAILED, "BLANK"));
        for (Verdict v : Verdict.values()) for (String r : REPLIES) {
            String c = SigninFailure.shownCode(v, r);
            if (c != null) check("shownCode(" + v + ", " + show(r) + ") = " + show(c) + " is in the daemon's vocabulary", vocab.contains(c));
            if (v == Verdict.BLANK || v == Verdict.CREATE_FAILED) eq("shownCode(" + v + ", " + show(r) + ")", null, c);
            if (v == Verdict.PHONE_FAULT)
                eq("shownCode(PHONE_FAULT, " + show(r) + ")",
                        r != null && r.startsWith("ERR-UNRECORDED") ? "phone-storage" : "phone", c);
        }
        // a sign-in's blind outcome, end to end over of(), is never recorded
        for (String r : REPLIES) for (boolean p : BOOLS)
            if (SigninFailure.of(r, p, false) == Verdict.BLANK)
                eq("blind sign-in " + show(r) + " records nothing", null, SigninFailure.shownCode(SigninFailure.of(r, p, false), r));

        if (failed > 0) { System.out.println(failed + " check(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
