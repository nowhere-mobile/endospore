package com.nowhere.chooser;

/**
 * NWP-20261028-13: which gate.log verb a gate-alarm event or daemon reply means. Pure Java (no android.*) so the
 * javac suite proves it; the chooser only sends what this returns, and the daemon's closed gateLogVerbs set
 * stays the enforcement -- an unknown verb is recorded as trace-unknown.
 */
final class GateAlarmVerbs {
    private GateAlarmVerbs() {}

    /** Every verb the methods below can return; the suite checks each is in gate_log.go's gateLogVerbs. */
    static final String[] VERBS = {
        "ui-silence-empty", "ui-silence-ok", "ui-silence-refused",
        "consume", "consume-past", "armed", "armed-inexact", "armed-err",
    };

    /**
     * What SILENCE-GATE-ALARM's reply says about the session's clock. Only a literal OK means roamd watched the
     * clock die; ERR-LIVE, NONE, ERR-STALE, ERR-NOREPLY and the rest mean it may still be ringing.
     */
    static String silence(String reply) {
        if (reply == null || reply.trim().isEmpty()) return "ui-silence-empty";
        String first = reply.split("\n", 2)[0].trim();
        return first.equals("OK") ? "ui-silence-ok" : "ui-silence-refused";
    }

    /**
     * What GET-GATE-ALARM's reply says. null = nothing pending ("0" or blank): no line, so an ordinary onResume
     * adds nothing to the 40-line log.
     */
    static String consume(String reply, long nowMs) {
        if (reply == null || reply.trim().isEmpty()) return null;
        long when;
        try { when = Long.parseLong(reply.trim()); } catch (NumberFormatException e) { return "armed-err"; }
        if (when == 0) return null;
        return when > nowMs ? "consume" : "consume-past";
    }

    /** Seconds from now to whenMs, negative when past, clamped to int: the daemon's gateAlarmInSeconds meaning. */
    static int inSeconds(long whenMs, long nowMs) {
        long d;
        try { d = Math.subtractExact(whenMs, nowMs); }
        catch (ArithmeticException e) { d = whenMs > nowMs ? Long.MAX_VALUE : Long.MIN_VALUE; }
        long s = d / 1000;
        if (s > Integer.MAX_VALUE) return Integer.MAX_VALUE;
        if (s < Integer.MIN_VALUE) return Integer.MIN_VALUE;
        return (int) s;
    }

    /** Which AlarmManager call took: the exact one, else the inexact fallback, else neither. */
    static String arm(boolean exactOk, boolean inexactOk) {
        if (exactOk) return "armed";
        return inexactOk ? "armed-inexact" : "armed-err";
    }
}
