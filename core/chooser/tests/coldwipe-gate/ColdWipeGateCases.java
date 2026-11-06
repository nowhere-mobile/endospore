package com.nowhere.chooser;

/** NWP-20261023-06: the cases for ColdWipeGate (made-up uids and names only). */
public final class ColdWipeGateCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + show(want) + " got " + show(got));
        }
    }

    private static String show(Object o) { return o == null ? "null" : "\"" + o + "\""; }

    private interface Call { Object run(); }

    /** An exception from the method under test is a failed case, never a pass. */
    private static Object guard(Call c) {
        try { return c.run(); } catch (Throwable t) { return "threw " + t; }
    }

    private static void uid(String reply, String want) {
        eq("markerUid(" + show(reply) + ")", want, guard(() -> ColdWipeGate.markerUid(reply)));
    }

    private static void names(String reply, int uid, boolean want) {
        eq("markerNames(" + show(reply) + ", " + uid + ")", want, guard(() -> ColdWipeGate.markerNames(reply, uid)));
    }

    private static void claim(String reply, boolean want) {
        eq("claimed(" + show(reply) + ")", want, guard(() -> ColdWipeGate.claimed(reply)));
    }

    private static void unans(String reply, boolean want) {
        eq("unanswered(" + show(reply) + ")", want, guard(() -> ColdWipeGate.unanswered(reply)));
    }

    private static void delay(int tries, long want) {
        eq("retryDelayMs(" + tries + ")", Long.valueOf(want), guard(() -> Long.valueOf(ColdWipeGate.retryDelayMs(tries))));
    }

    private static void none(String what, boolean unans, boolean exists, boolean unlocked, boolean current,
                             boolean flow, boolean want) {
        eq("removeOnNone " + what, Boolean.valueOf(want),
                guard(() -> Boolean.valueOf(ColdWipeGate.removeOnNone(unans, exists, unlocked, current, flow))));
    }

    /** A fake removal step: records the calls; removeUser answers {@code accept}, or throws when {@code thrower}. */
    private static final class Fake implements ColdWipeGate.NoneRemoval {
        final boolean accept, thrower;
        final StringBuilder calls = new StringBuilder();
        Fake(boolean accept, boolean thrower) { this.accept = accept; this.thrower = thrower; }
        @Override public boolean removeUser(int uid) {
            calls.append("remove ").append(uid).append(';');
            if (thrower) throw new SecurityException("refused");
            return accept;
        }
        @Override public void cleanStorage(int uid) { calls.append("clean ").append(uid).append(';'); }
    }

    /** The gate instance's consumer: the removal runs only when removeOnNone says yes; storage only after it. */
    private static void consume(String what, boolean unans, boolean exists, boolean unlocked, boolean current,
                                boolean flow, boolean accept, boolean thrower, int wantResult, String wantCalls) {
        final Fake f = new Fake(accept, thrower);
        eq("onNone " + what, Integer.valueOf(wantResult),
                guard(() -> Integer.valueOf(ColdWipeGate.onNone(12, unans, exists, unlocked, current, flow, f))));
        eq("onNone " + what + " (calls)", wantCalls, f.calls.toString());
    }

    public static void main(String[] args) {
        uid("COLDLOCK 12 Ann Lee", "12");
        uid("COLDLOCK 12", "12");
        uid("COLDLOCK  12 x", "12");
        uid("COLDLOCK ", "");
        uid("COLDLOCK12 x", null);
        uid("coldlock 12 x", null);
        uid("NONE", null);
        uid("", null);
        uid(null, null);

        names("COLDLOCK 12 Ann Lee", 12, true);
        names("COLDLOCK 12", 12, true);
        names("COLDLOCK  12 x", 12, true);
        names("COLDLOCK 120 x", 12, false);
        names("COLDLOCK 1 x", 12, false);
        names("COLDLOCK ", 12, false);
        names("COLDLOCK12 x", 12, false);
        names("coldlock 12 x", 12, false);
        names("NONE", 12, false);
        names("", 12, false);
        names(null, 12, false);

        claim("OK", true);
        for (String r : new String[] {"GONE", "", null, "OK GONE", "ok", "OK "}) claim(r, false);

        unans(null, true);
        unans("", true);
        unans("  ", true);
        for (String r : new String[] {"NONE", "GONE", "OK", "COLDLOCK 12 x"}) unans(r, false);

        delay(0, ColdWipeGate.FAST_RETRY_MS);
        delay(11, ColdWipeGate.FAST_RETRY_MS);
        delay(12, ColdWipeGate.SLOW_RETRY_MS);
        delay(1000, ColdWipeGate.SLOW_RETRY_MS);
        eq("0 < FAST_RETRY_MS < SLOW_RETRY_MS", Boolean.TRUE,
                Boolean.valueOf(0 < ColdWipeGate.FAST_RETRY_MS && ColdWipeGate.FAST_RETRY_MS < ColdWipeGate.SLOW_RETRY_MS));

        // NWP-20261123-20: a try that reads NONE removes the alarm's user only when every guard holds.
        none("every guard holds (NONE, locked, not current, no flow, after an unanswered try)",
                true, true, false, false, false, true);
        none("no unanswered try before this one", false, true, false, false, false, false);
        none("the user is gone", true, false, false, false, false, false);
        none("the user is unlocked", true, true, true, false, false, false);
        none("the user is current", true, true, false, true, false, false);
        none("a sign-in, resume or sign-out runs", true, true, false, false, true, false);
        none("NONE with the uid resumed and live (the owner's session)", true, true, true, true, false, false);
        none("a resume in flight (resumeBusy; the user still locked, not current)", true, true, false, false, true, false);
        for (int m = 0; m < 32; m++) {
            final boolean a = (m & 1) != 0, b = (m & 2) != 0, c = (m & 4) != 0, d = (m & 8) != 0, e = (m & 16) != 0;
            none("exhaustive " + a + "," + b + "," + c + "," + d + "," + e, a, b, c, d, e, a && b && !c && !d && !e);
        }

        // NWP-20261123-20: the instance's removal runs only when removeOnNone says yes.
        final int kept = ColdWipeGate.NONE_KEPT, removed = ColdWipeGate.NONE_REMOVED, refused = ColdWipeGate.NONE_REFUSED;
        eq("NONE_KEPT, NONE_REMOVED, NONE_REFUSED differ", Boolean.TRUE,
                Boolean.valueOf(kept != removed && removed != refused && kept != refused));
        consume("every guard holds, removal accepted", true, true, false, false, false, true, false, removed,
                "remove 12;clean 12;");
        consume("every guard holds, removal refused: storage NOT cleaned", true, true, false, false, false, false, false,
                refused, "remove 12;");
        consume("every guard holds, removal throws: storage NOT cleaned", true, true, false, false, false, true, true,
                refused, "remove 12;");
        consume("no unanswered try before this one", false, true, false, false, false, true, false, kept, "");
        consume("the user is gone", true, false, false, false, false, true, false, kept, "");
        consume("the user is unlocked", true, true, true, false, false, true, false, kept, "");
        consume("the user is current", true, true, false, true, false, true, false, kept, "");
        consume("NONE with the uid resumed and live (the owner's session)", true, true, true, true, false, true, false,
                kept, "");
        consume("a resume in flight (the gate's resumeBusy; the user still locked, not current)", true, true, false,
                false, true, true, false, kept, "");
        for (int m = 0; m < 32; m++) {
            final boolean a = (m & 1) != 0, b = (m & 2) != 0, c = (m & 4) != 0, d = (m & 8) != 0, e = (m & 16) != 0;
            final boolean yes = a && b && !c && !d && !e;
            consume("exhaustive " + a + "," + b + "," + c + "," + d + "," + e, a, b, c, d, e, true, false,
                    yes ? removed : kept, yes ? "remove 12;clean 12;" : "");
        }

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ColdWipeGate: all cases pass");
    }
}
