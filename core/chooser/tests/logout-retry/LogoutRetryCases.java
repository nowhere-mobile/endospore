package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.InterruptedIOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.function.LongSupplier;

/** Cases for LogoutRetry and LogoutAck's capped answer (NWP-20261116-11, h46 #4). Exits 1 on any failure. */
public class LogoutRetryCases {
    private static int failures = 0;
    private static final int SEND_CEILING = 100;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    /** The fake clock: the sleeper moves it and records each sleep. */
    static final class Clock {
        long t = 0;
        final List<Long> sleeps = new ArrayList<>();
        long now() { return t; }
        void sleep(long ms) { sleeps.add(ms); t += ms; }
    }

    /** What one fake send does: its result, given the call's 1-based index and cap. */
    interface Step {
        LogoutRetry.Result at(int n, long capMs);
    }

    /** The first send's end time: the first failure, from which the resend's deadline counts. */
    static long failAt(Fake f) { return f.at.get(0) + f.costMs; }

    /** A fake Sender: records each call's cap and clock, and moves the clock by {@code costMs} per undelivered send. */
    static final class Fake implements LogoutRetry.Sender {
        final Clock c;
        final Step step;
        final long costMs;
        final List<Long> caps = new ArrayList<>();
        final List<Long> deadlines = new ArrayList<>();
        final List<Long> at = new ArrayList<>();
        Fake(Clock c, long costMs, Step step) { this.c = c; this.costMs = costMs; this.step = step; }
        @Override public LogoutRetry.Result send(long capMs, long deadlineMs) {
            caps.add(capMs);
            deadlines.add(deadlineMs);
            at.add(c.t);
            if (caps.size() > SEND_CEILING) {
                check("send ceiling: more than " + SEND_CEILING + " sends", false);
                return delivered("OK");
            }
            LogoutRetry.Result r = step.at(caps.size(), capMs);
            if (!r.delivered) c.t += costMs;
            return r;
        }
    }

    static LogoutRetry.Result delivered(String reply) { return new LogoutRetry.Result(true, reply); }
    static LogoutRetry.Result undelivered() { return new LogoutRetry.Result(false, null); }

    static LogoutRetry.Result run(Fake f) {
        return LogoutRetry.run(f, f.c::now, f.c::sleep);
    }

    /** A reader that serves {@code n} WAIT lines, then EOF, and counts the lines it served. */
    static final class WaitReader extends Reader {
        final int n;
        int served = 0;
        private String cur = "";
        private int pos = 0;
        WaitReader(int n) { this.n = n; }
        @Override public int read(char[] buf, int off, int len) {
            if (pos >= cur.length()) {
                if (served >= n) return -1;
                served++;
                cur = "WAIT " + served + "\n";
                pos = 0;
            }
            int k = Math.min(len, cur.length() - pos);
            cur.getChars(pos, pos + k, buf, off);
            pos += k;
            return k;
        }
        @Override public void close() {}
    }

    /** A clock that moves {@code step} ms on every read. */
    static LongSupplier stepping(long step) {
        long[] t = {0};
        return () -> { long v = t[0]; t[0] += step; return v; };
    }

    /** Every resend's cap lies in [RESEND_READ_MS, TOTAL_MS], never 0 and never MAX_WAIT_MS. */
    static void resendCaps(String what, Fake f) {
        for (int i = 1; i < f.caps.size(); i++) {
            long cap = f.caps.get(i);
            check(what + ": resend " + i + " cap " + cap + " in [RESEND_READ_MS, TOTAL_MS]",
                    cap >= LogoutRetry.RESEND_READ_MS && cap <= LogoutRetry.TOTAL_MS);
        }
    }

    /** The first send has no deadline; every resend's is the first failure + TOTAL_MS, and its cap ends there. */
    static void deadlines(String what, Fake f) {
        check(what + ": the first send's deadline is NO_DEADLINE", f.deadlines.get(0) == LogoutRetry.NO_DEADLINE);
        long d = failAt(f) + LogoutRetry.TOTAL_MS;
        for (int i = 1; i < f.deadlines.size(); i++) {
            check(what + ": resend " + i + " deadline " + f.deadlines.get(i) + " is the first failure + TOTAL_MS (" + d
                    + ")", f.deadlines.get(i) == d);
            check(what + ": resend " + i + " cap ends at its deadline", f.at.get(i) + f.caps.get(i) == d);
        }
    }

    /**
     * A daemon socket on the shared clock: a line arrives every {@code gapMs} after the connect (WAIT lines, then
     * {@code answer} as line {@code answerAt} when it is not null). A read blocks until the next line; when that is
     * further away than the per-read timeout last set, the clock moves by the timeout and the read times out, as
     * LocalSocket's does. A timeout of 0 waits for ever, as setSoTimeout(0) does; a negative one throws.
     */
    static final class SlowSocket extends InputStream {
        final Clock c;
        final long gapMs;
        final String answer;
        final int answerAt;
        final List<Integer> timeouts = new ArrayList<>();
        int timeout = 0;
        int served = 0;
        long last;
        private byte[] cur = new byte[0];
        private int pos = 0;
        SlowSocket(Clock c, long gapMs, String answer, int answerAt) {
            this.c = c; this.gapMs = gapMs; this.answer = answer; this.answerAt = answerAt; this.last = c.t;
        }
        void setTimeout(int ms) {
            if (ms < 0) throw new IllegalArgumentException("timeout < 0");
            timeouts.add(ms);
            timeout = ms;
        }
        @Override public int read() throws IOException {
            byte[] b = new byte[1];
            return read(b, 0, 1) < 0 ? -1 : (b[0] & 0xff);
        }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            if (pos >= cur.length) {
                if (served >= 10_000) return -1;
                long arrives = last + gapMs;
                if (timeout > 0 && arrives - c.t > timeout) {
                    c.t += timeout;
                    throw new InterruptedIOException("read timed out");
                }
                c.t = Math.max(c.t, arrives);
                last = arrives;
                served++;
                String line = (answer != null && served == answerAt) ? answer : "WAIT " + served;
                cur = (line + "\n").getBytes(StandardCharsets.UTF_8);
                pos = 0;
            }
            int k = Math.min(len, cur.length - pos);
            System.arraycopy(cur, pos, b, off, k);
            pos += k;
            return k;
        }
    }

    /**
     * ProfileActivity's Sender on the shared clock: each connect costs {@code connectMs}; sends {@code 1..undelivered}
     * get no socket; past the deadline after the connect it writes nothing; then the answer is read through
     * LogoutAck.byDeadline and the four-argument LogoutAck.answer, as doLogoffImpl reads it.
     */
    static final class SocketSender implements LogoutRetry.Sender {
        final Clock c;
        final long connectMs;
        final int undelivered;
        final long gapMs;
        final String answer;
        final int answerAt;
        final List<Long> deadlines = new ArrayList<>();
        SlowSocket sock;
        long failAt = -1;
        int sends = 0;
        SocketSender(Clock c, long connectMs, int undelivered, long gapMs, String answer, int answerAt) {
            this.c = c; this.connectMs = connectMs; this.undelivered = undelivered;
            this.gapMs = gapMs; this.answer = answer; this.answerAt = answerAt;
        }
        @Override public LogoutRetry.Result send(long capMs, long deadlineMs) {
            sends++;
            deadlines.add(deadlineMs);
            if (sends > SEND_CEILING) { check("send ceiling", false); return delivered("OK"); }
            c.t += connectMs;
            if (sends <= undelivered) {
                if (failAt < 0) failAt = c.t;
                return undelivered();
            }
            if (c.t >= deadlineMs) return undelivered();
            sock = new SlowSocket(c, gapMs, answer, answerAt);
            String r = LogoutAck.answer(new BufferedReader(new InputStreamReader(LogoutAck.byDeadline(sock, c::now,
                    deadlineMs, sock::setTimeout), StandardCharsets.UTF_8)), c::now, () -> {}, capMs);
            return delivered(r);
        }
    }

    static LogoutRetry.Result run(SocketSender f) {
        return LogoutRetry.run(f, f.c::now, f.c::sleep);
    }

    /** The resend ended inside the one total bound from the first failure, and no timeout set reached past it. */
    static void inBound(String what, SocketSender f) {
        long spent = f.c.t - f.failAt;
        check(what + ": the retry took " + spent + " ms from the first failure, at most TOTAL_MS ("
                + LogoutRetry.TOTAL_MS + ")", f.failAt >= 0 && spent <= LogoutRetry.TOTAL_MS);
        check(what + ": the resend got the deadline first failure + TOTAL_MS", f.deadlines.size() >= 2
                && f.deadlines.get(f.deadlines.size() - 1) == f.failAt + LogoutRetry.TOTAL_MS);
        check(what + ": every per-read timeout is in [1, READ_MS]", f.sock != null
                && f.sock.timeouts.stream().allMatch(t -> t >= 1 && t <= LogoutAck.READ_MS));
    }

    public static void main(String[] args) {
        // C9: the stated bounds and the decided text.
        check("C9 RESTART_WAIT_MS is 30 s", LogoutRetry.RESTART_WAIT_MS == 30_000L);
        check("C9 POLL_MS is 2 s", LogoutRetry.POLL_MS == 2_000L);
        check("C9 RESEND_READ_MS is 90 s", LogoutRetry.RESEND_READ_MS == 90_000L);
        check("C9 TOTAL_MS is RESTART_WAIT_MS + RESEND_READ_MS",
                LogoutRetry.TOTAL_MS == LogoutRetry.RESTART_WAIT_MS + LogoutRetry.RESEND_READ_MS);
        check("C9 READ_MS is RESEND_READ_MS", LogoutAck.READ_MS == LogoutRetry.RESEND_READ_MS);
        check("C9 NO_DEADLINE is Long.MAX_VALUE", LogoutRetry.NO_DEADLINE == Long.MAX_VALUE);
        check("C9 UNKNOWN_COST is the decided text",
                "an unknown number of pending telephony record(s) may be lost".equals(LogoutRetry.UNKNOWN_COST));

        // C1: delivered OK -- one send, with MAX_WAIT_MS, no sleep.
        Fake f = new Fake(new Clock(), 0, (n, cap) -> delivered("OK"));
        LogoutRetry.Result r = run(f);
        check("C1 one send", f.caps.size() == 1);
        check("C1 the first send's cap is MAX_WAIT_MS", f.caps.get(0) == LogoutAck.MAX_WAIT_MS);
        check("C1 no sleep", f.c.sleeps.isEmpty());
        check("C1 delivered OK returned", r.delivered && "OK".equals(r.reply) && LogoutAck.acked(r.reply));
        check("C1 the first send has no deadline", f.deadlines.get(0) == LogoutRetry.NO_DEADLINE);

        // C2: delivered, the read timed out (null) -- one send, no sleep, never resent.
        f = new Fake(new Clock(), 0, (n, cap) -> n == 1 ? delivered(null) : delivered("OK"));
        r = run(f);
        check("C2 one send", f.caps.size() == 1);
        check("C2 no sleep", f.c.sleeps.isEmpty());
        check("C2 delivered null returned", r.delivered && r.reply == null);

        // C3: delivered BUSY -- one send, no sleep.
        f = new Fake(new Clock(), 0, (n, cap) -> n == 1 ? delivered("BUSY") : delivered("OK"));
        r = run(f);
        check("C3 one send", f.caps.size() == 1);
        check("C3 no sleep", f.c.sleeps.isEmpty());
        check("C3 BUSY returned", r.delivered && "BUSY".equals(r.reply) && !LogoutAck.acked(r.reply));

        // C4: delivered, the stream ended -- the reply LogoutAck.answer gives over an empty stream; one send.
        f = new Fake(new Clock(), 0, (n, cap) -> n == 1
                ? delivered(LogoutAck.answer(new BufferedReader(new StringReader("")), () -> 0L, () -> {}, cap))
                : delivered("OK"));
        r = run(f);
        check("C4 one send", f.caps.size() == 1);
        check("C4 no sleep", f.c.sleeps.isEmpty());
        check("C4 stream end returned as null", r.delivered && r.reply == null);

        // C5: undelivered, undelivered, then delivered OK at the third send.
        f = new Fake(new Clock(), 0, (n, cap) -> n < 3 ? undelivered() : delivered("OK"));
        r = run(f);
        check("C5 three sends", f.caps.size() == 3);
        check("C5 two sleeps of POLL_MS", f.c.sleeps.size() == 2
                && f.c.sleeps.stream().allMatch(ms -> ms == LogoutRetry.POLL_MS));
        check("C5 OK returned", r.delivered && "OK".equals(r.reply));
        check("C5 send 2's cap is TOTAL_MS - 2 s", f.caps.size() > 1 && f.caps.get(1) == LogoutRetry.TOTAL_MS - 2_000L);
        check("C5 send 3's cap is TOTAL_MS - 4 s", f.caps.size() > 2 && f.caps.get(2) == LogoutRetry.TOTAL_MS - 4_000L);
        resendCaps("C5", f);
        deadlines("C5", f);

        // C6: undelivered for ever, zero-cost sends: polls at 2..30 s, then stop.
        f = new Fake(new Clock(), 0, (n, cap) -> undelivered());
        r = run(f);
        check("C6 sixteen sends (1 + 15 polls), got " + f.caps.size(), f.caps.size() == 16);
        check("C6 undelivered returned", !r.delivered && r.reply == null);
        for (int i = 0; i < f.at.size(); i++) {
            check("C6 send " + i + " starts within RESTART_WAIT_MS", f.at.get(i) <= LogoutRetry.RESTART_WAIT_MS);
        }
        check("C6 the last sleep ends past RESTART_WAIT_MS", f.c.t > LogoutRetry.RESTART_WAIT_MS);
        resendCaps("C6", f);
        deadlines("C6", f);

        // C6b: each undelivered send costs 8 s (a failed bounded connect): resends at 2, 12 and 22 s from the
        // first failure (t = 8 s), then stop.
        f = new Fake(new Clock(), 8_000, (n, cap) -> undelivered());
        r = run(f);
        check("C6b four sends, got " + f.caps.size(), f.caps.size() == 4);
        check("C6b resends at 2, 12, 22 s from the first failure", f.at.size() == 4
                && f.at.get(1) == 10_000L && f.at.get(2) == 20_000L && f.at.get(3) == 30_000L);
        check("C6b undelivered returned", !r.delivered);
        resendCaps("C6b", f);
        deadlines("C6b", f);

        // C7: undelivered for 10 s, then delivered; that resend streams WAIT lines (1 s each on its own clock)
        // and is cut at its cap, TOTAL_MS - 10 s, never at MAX_WAIT_MS.
        final WaitReader[] wr = new WaitReader[1];
        final long[] answerCap = {-1};
        f = new Fake(new Clock(), 0, (n, cap) -> {
            if (n < 6) return undelivered();
            wr[0] = new WaitReader(1_000);
            answerCap[0] = cap;
            return delivered(LogoutAck.answer(new BufferedReader(wr[0]), stepping(1_000), () -> {}, cap));
        });
        r = run(f);
        check("C7 six sends", f.caps.size() == 6);
        check("C7 the resend's cap is TOTAL_MS - 10 s", f.caps.size() == 6
                && f.caps.get(5) == LogoutRetry.TOTAL_MS - 10_000L);
        check("C7 the cut resend returns null, delivered", r.delivered && r.reply == null);
        long waited = wr[0] == null ? -1 : wr[0].served * 1_000L;
        check("C7 the WAIT lines are cut at the cap (" + waited + " ms of " + answerCap[0] + ")",
                waited >= answerCap[0] && waited < answerCap[0] + 2_000L);
        check("C7 the WAIT lines are cut before MAX_WAIT_MS", waited < LogoutAck.MAX_WAIT_MS);
        resendCaps("C7", f);
        deadlines("C7", f);

        // C8: undelivered, then delivered with a non-OK answer: not resent again.
        f = new Fake(new Clock(), 0, (n, cap) -> n == 1 ? undelivered() : delivered("BUSY"));
        r = run(f);
        check("C8 two sends", f.caps.size() == 2);
        check("C8 BUSY returned", r.delivered && "BUSY".equals(r.reply));
        resendCaps("C8", f);
        deadlines("C8", f);
        // C8b: undelivered, then delivered with no answer (a read timeout): not resent again.
        f = new Fake(new Clock(), 0, (n, cap) -> n == 1 ? undelivered() : (n == 2 ? delivered(null) : delivered("OK")));
        r = run(f);
        check("C8b two sends", f.caps.size() == 2);
        check("C8b delivered null returned", r.delivered && r.reply == null);

        // C11 (RF-001): one shared clock for the connect, the sleeps and the reads. The first send gets no socket at
        // 0 s; the resend at 2 s streams a WAIT line every 80 s, each inside the 90 s per-read timeout. The retry
        // ends at the deadline, 120 s after the first failure, never at the second WAIT line (162 s).
        SocketSender ss = new SocketSender(new Clock(), 0, 1, 80_000, null, 0);
        r = run(ss);
        check("C11 two sends", ss.sends == 2);
        check("C11 the resend is delivered and cut (null)", r.delivered && r.reply == null);
        check("C11 one WAIT line accepted (" + (ss.sock == null ? -1 : ss.sock.served) + ")",
                ss.sock != null && ss.sock.served == 1);
        check("C11 the last read is cut at the deadline (38 s timeout)", ss.sock != null
                && ss.sock.timeouts.size() == 2 && ss.sock.timeouts.get(1) == 38_000);
        inBound("C11", ss);

        // C11b: each connect costs 8 s (the first failure is at 8 s), the resend's connect ends at 18 s, and a WAIT
        // line every 55 s lands exactly on the deadline (128 s): the next read is refused at the deadline.
        ss = new SocketSender(new Clock(), 8_000, 1, 55_000, null, 0);
        r = run(ss);
        check("C11b the resend is delivered and cut (null)", ss.sends == 2 && r.delivered && r.reply == null);
        check("C11b it ends at the deadline, 128 s (" + ss.c.t + ")", ss.c.t == 128_000L);
        inBound("C11b", ss);

        // C11c: a silent socket after the resend: the read is cut at the deadline, not 90 s past the last WAIT.
        ss = new SocketSender(new Clock(), 8_000, 1, 200_000, null, 0);
        r = run(ss);
        check("C11c the silent resend is cut (null)", ss.sends == 2 && r.delivered && r.reply == null);
        inBound("C11c", ss);

        // C11d: an OK just inside the deadline is returned: WAIT lines at 41 and 80 s, the OK at 119 s.
        ss = new SocketSender(new Clock(), 0, 1, 39_000, "OK", 3);
        r = run(ss);
        check("C11d an OK at 119 s is returned (" + r.reply + " at " + ss.c.t + ")",
                r.delivered && "OK".equals(r.reply) && ss.c.t == 119_000L);
        inBound("C11d", ss);
        // C11e: the same OK two seconds past the deadline (122 s) is cut.
        ss = new SocketSender(new Clock(), 0, 1, 40_000, "OK", 3);
        r = run(ss);
        check("C11e an OK at 122 s is cut (" + r.reply + ")", r.delivered && r.reply == null);
        inBound("C11e", ss);

        // C11f: the first send keeps its bounds: no deadline, a 90 s timeout on every read, WAIT lines every 80 s
        // well past 120 s, and the OK at the eighth line (640 s, a non-WAIT line past MAX_WAIT_MS) is returned.
        ss = new SocketSender(new Clock(), 0, 0, 80_000, "OK", 8);
        r = run(ss);
        check("C11f one send, no deadline", ss.sends == 1 && ss.deadlines.get(0) == LogoutRetry.NO_DEADLINE);
        check("C11f the OK at 640 s is returned (" + r.reply + " at " + ss.c.t + ")",
                r.delivered && "OK".equals(r.reply) && ss.c.t == 640_000L);
        check("C11f every read had the 90 s timeout", ss.sock != null && !ss.sock.timeouts.isEmpty()
                && ss.sock.timeouts.stream().allMatch(t -> t == LogoutAck.READ_MS));

        // C10: LogoutAck's four-argument answer honours its cap; the three-argument form keeps MAX_WAIT_MS.
        WaitReader w = new WaitReader(2_000);
        String a = LogoutAck.answer(new BufferedReader(w), stepping(1_000), () -> {}, 5_000L);
        check("C10 a 5 s cap ends endless WAIT lines at 5 s (" + w.served + " lines)", a == null && w.served == 5);
        w = new WaitReader(2_000);
        a = LogoutAck.answer(new BufferedReader(w), stepping(1_000), () -> {});
        check("C10 the three-argument form ends at MAX_WAIT_MS (" + w.served + " lines)",
                a == null && w.served == LogoutAck.MAX_WAIT_MS / 1_000L);

        if (failures > 0) { System.err.println("  " + failures + " case(s) failed"); System.exit(1); }
        System.out.println("  cases ok");
    }
}
