package com.nowhere.chooser;

import com.nowhere.chooser.GateLockClear.Action;

/** NWP-20261118-04 (h48 #1): the cases for GateLockClear. Compiled with GateLockClear.java alone by
 *  core/vendor-common/bin/test-gate-lock-clear-java.sh. Prints "ok <case>" or "FAIL <case>: ..." per case and exits 1
 *  when any case failed. */
public final class GateLockClearCases {
    private static int failed;

    /** The suite's own copies of the two texts, byte for byte. */
    private static final String WANT_CLEARED = "A screen lock had been set on this phone's gate, so it was removed: a lock there stops every restart before the gate.";
    private static final String WANT_REPORTED = "A screen lock is set on this phone's gate. It will be removed after it is next entered; until then every restart stops at it.";

    private static void check(String name, boolean cond, String why) {
        if (!cond) { failed++; System.out.println("FAIL " + name + ": " + why); }
    }

    private static void run(String name, Runnable body) {
        int before = failed;
        try { body.run(); } catch (Throwable t) { failed++; System.out.println("FAIL " + name + ": threw " + t); }
        if (failed == before) System.out.println("ok " + name);
    }

    private static void decides(String name, boolean secure, boolean stored, boolean active, Action want) {
        run(name, () -> {
            Action got = GateLockClear.decide(secure, stored, active);
            check(name, got == want, "decide(" + secure + ", " + stored + ", " + active + ") = " + got + ", want " + want);
        });
    }

    /** The fake token: 32 bytes 0x00..0x1f, and its hex. */
    private static byte[] token() {
        byte[] b = new byte[32];
        for (int i = 0; i < 32; i++) b[i] = (byte) i;
        return b;
    }
    private static final String HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

    /** A fake platform for GateLockClear.run: it counts the calls. */
    private static final class Fake implements GateLockClear.Port {
        final boolean secure;
        final byte[] stored;
        boolean secureThrows, active, clearResult, clearThrows;
        RuntimeException activeThrow;
        int activeCalls, setTokens, clears, markers;
        byte[] clearedWith;
        final java.util.List<String> logs = new java.util.ArrayList<>();

        Fake(boolean secure, byte[] stored) { this.secure = secure; this.stored = stored; }
        Fake activeThrows(RuntimeException e) { activeThrow = e; return this; }

        @Override public boolean secure() {
            if (secureThrows) throw new SecurityException("no keyguard");
            return secure;
        }
        @Override public byte[] storedToken() { return stored; }
        @Override public boolean active() {
            activeCalls++;
            if (activeThrow != null) throw activeThrow;
            return active;
        }
        @Override public void setToken() { setTokens++; }
        @Override public boolean clear(byte[] token) {
            clears++;
            clearedWith = token.clone();
            if (clearThrows) throw new SecurityException("refused");
            return clearResult;
        }
        @Override public void writeMarker() { markers++; }
        @Override public void log(String line) { logs.add(line); }
    }

    public static void main(String[] args) {
        // C1-C8: the whole table.
        decides("C1 secure, stored, active: CLEAR", true, true, true, Action.CLEAR);
        decides("C2 secure, stored, inactive: REPORT (never replace the kept token)", true, true, false, Action.REPORT);
        decides("C3 secure, no bytes, active: SET_TOKEN_REPORT (cannot clear)", true, false, true, Action.SET_TOKEN_REPORT);
        decides("C4 secure, no bytes, inactive: SET_TOKEN_REPORT", true, false, false, Action.SET_TOKEN_REPORT);
        decides("C5 no lock, stored, active: NONE", false, true, true, Action.NONE);
        decides("C6 no lock, stored, inactive: SET_TOKEN", false, true, false, Action.SET_TOKEN);
        decides("C7 no lock, no bytes, active: SET_TOKEN", false, false, true, Action.SET_TOKEN);
        decides("C8 no lock, no bytes, inactive: SET_TOKEN", false, false, false, Action.SET_TOKEN);

        run("C9 afterClear: true keeps CLEAR, false becomes REPORT", () -> {
            check("C9", GateLockClear.afterClear(true) == Action.CLEAR, "afterClear(true) = " + GateLockClear.afterClear(true));
            check("C9", GateLockClear.afterClear(false) == Action.REPORT, "afterClear(false) = " + GateLockClear.afterClear(false));
        });

        run("C10 the marker is written only after a CLEAR", () -> {
            for (Action a : Action.values()) {
                check("C10", GateLockClear.writesMarker(a) == (a == Action.CLEAR), "writesMarker(" + a + ") = " + GateLockClear.writesMarker(a));
            }
        });

        run("C11 the cleared notice shows once, after a successful CLEAR", () -> {
            Action last = GateLockClear.afterClear(true);
            boolean marker = GateLockClear.writesMarker(last);
            check("C11", marker, "a successful CLEAR writes no marker");
            String first = GateLockClear.noticeLine(marker, last);
            check("C11", WANT_CLEARED.equals(first), "the first menu shows " + first);
            marker = marker && GateLockClear.keepsMarker(first);
            check("C11", !marker, "the marker is kept after the cleared notice was shown");
            String second = GateLockClear.noticeLine(marker, last);
            check("C11", second == null, "the second menu shows " + second);
            String third = GateLockClear.noticeLine(marker, GateLockClear.decide(false, true, true));
            check("C11", third == null, "a later run (NONE) shows " + third);
        });

        run("C12 a failed CLEAR never shows the cleared notice", () -> {
            Action last = GateLockClear.afterClear(false);
            boolean marker = GateLockClear.writesMarker(last);
            check("C12", !marker, "a failed CLEAR wrote the marker");
            String line = GateLockClear.noticeLine(marker, last);
            check("C12", WANT_REPORTED.equals(line), "a failed CLEAR shows " + line);
        });

        run("C13 the report line shows only under REPORT or SET_TOKEN_REPORT", () -> {
            for (Action a : Action.values()) {
                boolean want = a == Action.REPORT || a == Action.SET_TOKEN_REPORT;
                String line = GateLockClear.noticeLine(false, a);
                check("C13", want ? WANT_REPORTED.equals(line) : line == null, "noticeLine(false, " + a + ") = " + line);
            }
            check("C13", GateLockClear.noticeLine(false, null) == null, "no finished run shows a line");
            check("C13", WANT_CLEARED.equals(GateLockClear.noticeLine(true, null)), "the marker alone does not show the notice");
        });

        run("C14 only the cleared notice drops the marker", () -> {
            check("C14", GateLockClear.keepsMarker(WANT_REPORTED), "the report line drops the marker");
            check("C14", GateLockClear.keepsMarker(null), "no line drops the marker");
            check("C14", !GateLockClear.keepsMarker(WANT_CLEARED), "the cleared notice keeps the marker");
        });

        run("C15 the two texts byte for byte", () -> {
            check("C15", WANT_CLEARED.equals(GateLockClear.CLEARED), "CLEARED is [" + GateLockClear.CLEARED + "]");
            check("C15", WANT_REPORTED.equals(GateLockClear.REPORTED), "REPORTED is [" + GateLockClear.REPORTED + "]");
        });

        // R1-R9: GateLockClear.run against a fake platform. R1 and R2 are RF-001: isResetPasswordTokenActive throws
        // IllegalStateException when no token exists (its documented contract), and a run that stopped there set no
        // token and reported nothing.
        run("R1 secure, no kept token, the query throws: a token is set, SET_TOKEN_REPORT, the query is not made", () -> {
            Fake f = new Fake(true, null).activeThrows(new IllegalStateException("no token"));
            Action a = GateLockClear.run(f);
            check("R1", a == Action.SET_TOKEN_REPORT, "run = " + a);
            check("R1", f.setTokens == 1, "setToken calls = " + f.setTokens);
            check("R1", f.activeCalls == 0, "isResetPasswordTokenActive was asked " + f.activeCalls + " time(s)");
            check("R1", WANT_REPORTED.equals(GateLockClear.noticeLine(false, a)), "Owner settings shows " + GateLockClear.noticeLine(false, a));
        });
        run("R2 no lock, no kept token, the query throws: a token is set, SET_TOKEN", () -> {
            Fake f = new Fake(false, null).activeThrows(new IllegalStateException("no token"));
            Action a = GateLockClear.run(f);
            check("R2", a == Action.SET_TOKEN, "run = " + a);
            check("R2", f.setTokens == 1, "setToken calls = " + f.setTokens);
        });
        run("R3 secure, a kept token the platform does not hold (the query throws IllegalStateException): a new token", () -> {
            Fake f = new Fake(true, token()).activeThrows(new IllegalStateException("no token"));
            Action a = GateLockClear.run(f);
            check("R3", a == Action.SET_TOKEN_REPORT, "run = " + a);
            check("R3", f.setTokens == 1, "setToken calls = " + f.setTokens);
            check("R3", f.clears == 0, "clear calls = " + f.clears);
        });
        run("R4 a kept token, the query fails another way: the run ends, nothing is set or cleared", () -> {
            Fake f = new Fake(true, token()).activeThrows(new SecurityException("denied"));
            Action a = GateLockClear.run(f);
            check("R4", a == null, "run = " + a);
            check("R4", f.setTokens == 0 && f.clears == 0 && f.markers == 0, "set " + f.setTokens + ", clear " + f.clears + ", marker " + f.markers);
        });
        run("R5 isDeviceSecure throws: the run ends, nothing else is asked", () -> {
            Fake f = new Fake(true, token());
            f.secureThrows = true;
            Action a = GateLockClear.run(f);
            check("R5", a == null, "run = " + a);
            check("R5", f.activeCalls == 0 && f.setTokens == 0 && f.clears == 0, "asked " + f.activeCalls + ", set " + f.setTokens + ", clear " + f.clears);
        });
        run("R6 secure, kept, active: the kept bytes clear, the marker is written, the bytes are zeroed", () -> {
            byte[] t = token();
            Fake f = new Fake(true, t);
            f.active = true;
            f.clearResult = true;
            Action a = GateLockClear.run(f);
            check("R6", a == Action.CLEAR, "run = " + a);
            check("R6", f.clears == 1 && f.clearedWith != null && java.util.Arrays.equals(f.clearedWith, token()), "clear calls " + f.clears + " with the kept bytes");
            check("R6", f.markers == 1, "marker writes = " + f.markers);
            check("R6", f.setTokens == 0, "setToken calls = " + f.setTokens);
            check("R6", java.util.Arrays.equals(t, new byte[32]), "the kept bytes were not zeroed");
        });
        run("R7 a CLEAR that returns false or throws: REPORT, no marker, no retry", () -> {
            Fake f = new Fake(true, token());
            f.active = true;
            f.clearResult = false;
            Action a = GateLockClear.run(f);
            check("R7", a == Action.REPORT && f.markers == 0 && f.clears == 1, "false: run " + a + ", marker " + f.markers + ", clear " + f.clears);
            Fake g = new Fake(true, token());
            g.active = true;
            g.clearThrows = true;
            a = GateLockClear.run(g);
            check("R7", a == Action.REPORT && g.markers == 0 && g.clears == 1, "threw: run " + a + ", marker " + g.markers + ", clear " + g.clears);
        });
        run("R8 secure, kept, inactive: REPORT, the kept token is not replaced", () -> {
            Fake f = new Fake(true, token());
            Action a = GateLockClear.run(f);
            check("R8", a == Action.REPORT, "run = " + a);
            check("R8", f.setTokens == 0 && f.clears == 0, "set " + f.setTokens + ", clear " + f.clears);
        });
        run("R9 no log line holds the token", () -> {
            for (boolean secure : new boolean[] {true, false}) {
                for (boolean active : new boolean[] {true, false}) {
                    Fake f = new Fake(secure, token());
                    f.active = active;
                    f.clearResult = true;
                    GateLockClear.run(f);
                    for (String l : f.logs) check("R9", !l.contains(HEX) && !l.contains(HEX.toUpperCase()), "a log line holds the token: " + l);
                    check("R9", !f.logs.isEmpty(), "the run logged nothing");
                }
            }
        });

        System.out.println(failed == 0 ? "all cases pass" : failed + " check(s) failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
