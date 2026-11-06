package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;

/** Cases for LogoutAck (NWP-20261106-01, Q116). Exits 1 on any failure. */
public class LogoutAckCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    private static BufferedReader br(String s) { return new BufferedReader(new StringReader(s)); }

    /** A reader that serves {@code first}, then throws {@code err}. */
    private static BufferedReader throwing(String first, IOException err) {
        return new BufferedReader(new Reader() {
            private int pos = 0;
            @Override public int read(char[] buf, int off, int len) throws IOException {
                if (pos >= first.length()) throw err;
                int n = Math.min(len, first.length() - pos);
                first.getChars(pos, pos + n, buf, off);
                pos += n;
                return n;
            }
            @Override public void close() {}
        });
    }

    /** A clock that moves {@code step} ms on every read. */
    private static java.util.function.LongSupplier stepping(long step) {
        long[] t = {0};
        return () -> { long v = t[0]; t[0] += step; return v; };
    }

    public static void main(String[] args) {
        long[] t = {0};
        java.util.function.LongSupplier still = () -> t[0];

        String a = LogoutAck.answer(br("OK\n"), still);
        check("OK is the answer", "OK".equals(a) && LogoutAck.acked(a));
        a = LogoutAck.answer(br("WAIT 20\nOK\n"), still);
        check("one WAIT then OK is acked", "OK".equals(a) && LogoutAck.acked(a));
        a = LogoutAck.answer(br("WAIT 1\nWAIT 2\nWAIT 3\nOK sealing\n"), still);
        check("three WAITs then OK is acked", "OK sealing".equals(a) && LogoutAck.acked(a));
        a = LogoutAck.answer(br("WAIT 20\n"), still);
        check("WAIT then EOF is null", a == null && !LogoutAck.acked(a));
        a = LogoutAck.answer(br("WAITING 3\nOK\n"), still);
        check("WAITING is the answer, not acked", "WAITING 3".equals(a) && !LogoutAck.acked(a));
        a = LogoutAck.answer(br("WAIT\nOK\n"), still);
        check("WAIT without the space is the answer", "WAIT".equals(a) && !LogoutAck.acked(a));

        a = LogoutAck.answer(br("WAIT 1\nWAIT 2\nWAIT 3\nWAIT 4\nOK\n"), stepping(200_000));
        check("WAIT lines past 600 s end in null", a == null);
        t[0] = 0;
        java.util.function.LongSupplier seq = new java.util.function.LongSupplier() {
            private int n = 0;
            public long getAsLong() { return n++ == 0 ? 0 : t[0]; }
        };
        t[0] = LogoutAck.MAX_WAIT_MS - 1;
        check("a WAIT at the cap minus 1 ms is skipped", "OK".equals(LogoutAck.answer(br("WAIT 1\nOK\n"), seq)));
        seq = new java.util.function.LongSupplier() {
            private int n = 0;
            public long getAsLong() { return n++ == 0 ? 0 : t[0]; }
        };
        t[0] = LogoutAck.MAX_WAIT_MS;
        check("a WAIT at the cap ends in null", LogoutAck.answer(br("WAIT 1\nOK\n"), seq) == null);
        a = LogoutAck.answer(br("OK\n"), stepping(700_000));
        check("a real OK past the cap is still returned", "OK".equals(a));

        check("a socket timeout is null",
                LogoutAck.answer(throwing("", new java.net.SocketTimeoutException()), still) == null);
        check("an IOException after a WAIT is null",
                LogoutAck.answer(throwing("WAIT 1\n", new IOException("reset")), still) == null);

        check("empty input is null", LogoutAck.answer(br(""), still) == null);
        a = LogoutAck.answer(br("BUSY\n"), still);
        check("BUSY is the answer, not acked", "BUSY".equals(a) && !LogoutAck.acked(a));
        check("acked of empty/null/WAIT/OK", !LogoutAck.acked("") && !LogoutAck.acked(null)
                && !LogoutAck.acked("WAIT 5") && LogoutAck.acked("OK"));
        check("constants", "WAIT ".equals(LogoutAck.WAIT_PREFIX) && LogoutAck.MAX_WAIT_MS == 600_000L);

        // NWP-20261107-08: the wait line (dn-1106 #3). onFirstWait runs once, at the first WAIT inside the cap.
        int[] runs = {0};
        Runnable count = () -> runs[0]++;
        check("WAIT_LINE is dn-1106 #3's line", ("Finishing an app download first. Your session is saved and closed "
                + "as soon as it's done.").equals(LogoutAck.WAIT_LINE));
        t[0] = 0; runs[0] = 0;
        a = LogoutAck.answer(br("WAIT 1\nWAIT 2\nWAIT 3\nOK\n"), still, count);
        check("three WAITs then OK runs onFirstWait once", "OK".equals(a) && runs[0] == 1);
        runs[0] = 0;
        a = LogoutAck.answer(br("OK\n"), still, count);
        check("OK first never runs onFirstWait", "OK".equals(a) && runs[0] == 0);
        runs[0] = 0;
        a = LogoutAck.answer(br("WAIT 1\nWAIT 2\nWAIT 3\nWAIT 4\nOK\n"), stepping(200_000), count);
        check("WAITs past the cap: null, ran once", a == null && runs[0] == 1);
        runs[0] = 0;
        a = LogoutAck.answer(br("WAIT 20\n"), still, count);
        check("WAIT then EOF: null, ran once", a == null && runs[0] == 1);
        runs[0] = 0;
        java.util.function.LongSupplier atCap = new java.util.function.LongSupplier() {
            private int n = 0;
            public long getAsLong() { return n++ == 0 ? 0 : LogoutAck.MAX_WAIT_MS; }
        };
        a = LogoutAck.answer(br("WAIT 1\nOK\n"), atCap, count);
        check("a WAIT at the cap never runs onFirstWait", a == null && runs[0] == 0);
        runs[0] = 0;
        a = LogoutAck.answer(br("WAITING 3\n"), still, count);
        check("a non-WAIT line never runs onFirstWait", "WAITING 3".equals(a) && runs[0] == 0);
        check("the two-argument form is the three-argument form with a no-op",
                "OK".equals(LogoutAck.answer(br("WAIT 1\nOK\n"), still))
                && "OK".equals(LogoutAck.answer(br("WAIT 1\nOK\n"), still, () -> {})) && runs[0] == 0);

        // NWP-20261111-08 (Q067): LOGOUT refused while a key-bound cold lock lands. Exact token, line end trimmed; not
        // an ack, and a bare BUSY (a pending restart) is not it.
        check("LOCK_LANDING is BUSY COLDLOCK", "BUSY COLDLOCK".equals(LogoutAck.LOCK_LANDING));
        check("lockLanding of BUSY COLDLOCK", LogoutAck.lockLanding("BUSY COLDLOCK"));
        check("lockLanding of BUSY COLDLOCK with a CR", LogoutAck.lockLanding("BUSY COLDLOCK\r"));
        check("lockLanding of BUSY COLDLOCK with a CRLF", LogoutAck.lockLanding("BUSY COLDLOCK\r\n"));
        check("lockLanding of BUSY is false", !LogoutAck.lockLanding("BUSY"));
        check("lockLanding of OK is false", !LogoutAck.lockLanding("OK"));
        check("lockLanding of BUSY COLDLOCKX is false", !LogoutAck.lockLanding("BUSY COLDLOCKX"));
        check("lockLanding of BUSY COLDLOCK with a leading space is false", !LogoutAck.lockLanding(" BUSY COLDLOCK"));
        check("lockLanding of empty is false", !LogoutAck.lockLanding(""));
        check("lockLanding of null is false", !LogoutAck.lockLanding(null));
        check("acked of LOCK_LANDING is false", !LogoutAck.acked(LogoutAck.LOCK_LANDING));
        t[0] = 0;
        a = LogoutAck.answer(br("WAIT 1\nWAIT 2\nBUSY COLDLOCK\n"), still);
        check("WAITs then BUSY COLDLOCK is the answer", LogoutAck.LOCK_LANDING.equals(a) && LogoutAck.lockLanding(a)
                && !LogoutAck.acked(a));
        runs[0] = 0;
        a = LogoutAck.answer(br("WAIT 1\nWAIT 2\nBUSY COLDLOCK\n"), still, count);
        check("WAITs then BUSY COLDLOCK, three-argument form: ran once", LogoutAck.LOCK_LANDING.equals(a)
                && runs[0] == 1);
        a = LogoutAck.answer(br("BUSY COLDLOCK\r\n"), still);
        check("BUSY COLDLOCK CRLF read is lockLanding", LogoutAck.lockLanding(a) && !LogoutAck.acked(a));
        check("a BUSY read is not lockLanding", !LogoutAck.lockLanding(LogoutAck.answer(br("BUSY\n"), still)));

        if (failures > 0) System.exit(1);
        System.out.println("  cases ok");
    }
}
