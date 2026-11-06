package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.util.function.LongSupplier;

/**
 * Reads the login daemon's answer to LOGOUT (NWP-20261106-01, Q116 in docs/product-decisions.md).
 *
 * <p>LOGOUT queues behind the daemon's session lock while a long holder (an on-demand download, the Auto sweep, a
 * store install) has it. Q116 has the daemon send a {@code WAIT } progress line BEFORE it takes the lock, and the
 * real answer after, so the sign-out screen never reads a wait as an unreachable daemon. The daemon half is the next
 * slice; this reader ships first because an older reader takes any first line that is not OK as unacknowledged and
 * reboots the phone.
 *
 * <p>A line is a progress line only if it starts with exactly {@link #WAIT_PREFIX}; the first other line is the
 * answer, returned as read (a non-WAIT line is returned even past the cap, since dropping a real OK would reboot over
 * a seal the daemon already started). The socket's per-read timeout is {@link #READ_MS}, set before every read by
 * {@link #byDeadline}: 90 s of silence is still an unreachable daemon. {@link #MAX_WAIT_MS} keeps the 2026-09-27
 * reboot backstop for a daemon that waits for ever (FETCH-APP's connection deadline, 320 s, is the longest a single
 * verb sets); the first LOGOUT send uses it, and {@link LogoutRetry}'s resend passes a smaller cap through the
 * four-argument form and an absolute deadline through {@link #byDeadline}.
 *
 * <p>{@link #LOCK_LANDING} is the answer for a sign-out refused while a key-bound cold lock lands (Q067).
 */
final class LogoutAck {
    static final String WAIT_PREFIX = "WAIT ";
    static final long MAX_WAIT_MS = 600_000L;
    /** The per-read socket timeout: 90 s of silence is an unreachable daemon. */
    static final int READ_MS = 90_000;

    /**
     * LOGOUT's answer while a key-bound cold lock holds the session (Q067, DECIDED 2026-10-20 in
     * docs/product-decisions.md): the daemon refuses the sign-out until the lock lands or aborts. Not an ack, and not
     * a bare {@code BUSY} (a pending restart), which still reboots. This reader ships before the daemon sends it, as
     * the WAIT reader did.
     */
    static final String LOCK_LANDING = "BUSY COLDLOCK";

    /**
     * What the sign-out screen says while LOGOUT answers WAIT (Q116, dn-1106 #3, decided 2026-10-21 in
     * docs/product-decisions.md). It promises the normal ending; a save that then fails still ends on the existing
     * failed-sign-out screens (the decision's inference).
     */
    static final String WAIT_LINE =
            "Finishing an app download first. Your session is saved and closed as soon as it's done.";

    private LogoutAck() {}

    /** The daemon's answer, or null on EOF, any IOException (a socket timeout included) or a wait past the cap. */
    static String answer(BufferedReader br, LongSupplier nowMs) {
        return answer(br, nowMs, () -> {});
    }

    /**
     * As the two-argument form; {@code onFirstWait} runs once, at the first WAIT line inside the cap, never again
     * and never after the cap, so the screen can show {@link #WAIT_LINE} only while a wait is real.
     */
    static String answer(BufferedReader br, LongSupplier nowMs, Runnable onFirstWait) {
        return answer(br, nowMs, onFirstWait, MAX_WAIT_MS);
    }

    /**
     * As the three-argument form, with {@code capMs} in place of {@link #MAX_WAIT_MS} (NWP-20261116-11): the first
     * LOGOUT send passes MAX_WAIT_MS, and {@link LogoutRetry}'s one resend passes what is left of its total bound, so
     * no WAIT line can stretch the resend past it.
     */
    static String answer(BufferedReader br, LongSupplier nowMs, Runnable onFirstWait, long capMs) {
        long start = nowMs.getAsLong();
        boolean told = false;
        try {
            String line;
            while ((line = br.readLine()) != null) {
                if (!line.startsWith(WAIT_PREFIX)) return line;
                if (nowMs.getAsLong() - start >= capMs) return null;
                if (!told) { told = true; onFirstWait.run(); }
            }
            return null;
        } catch (IOException e) {
            return null;
        }
    }

    /** Sets a socket's per-read timeout (the socket's {@code setSoTimeout}). */
    interface ReadTimeout {
        void set(int ms) throws IOException;
    }

    /**
     * {@code in}, with every read ending by {@code deadlineMs} on {@code nowMs}'s clock (NWP-20261116-11, RF-001):
     * before each read it sets the per-read timeout to {@link #READ_MS} or the time left, whichever is less, and at
     * or past the deadline it throws instead of reading. {@link LogoutRetry#NO_DEADLINE} leaves {@link #READ_MS} on
     * every read, as before.
     */
    static InputStream byDeadline(InputStream in, LongSupplier nowMs, long deadlineMs, ReadTimeout timeout) {
        return new InputStream() {
            private void bound() throws IOException {
                long left = deadlineMs - nowMs.getAsLong();
                if (left <= 0) throw new InterruptedIOException("LOGOUT deadline passed");
                timeout.set((int) Math.min(READ_MS, left));
            }

            @Override public int read() throws IOException {
                bound();
                return in.read();
            }

            @Override public int read(byte[] b, int off, int len) throws IOException {
                bound();
                return in.read(b, off, len);
            }

            @Override public void close() throws IOException {
                in.close();
            }
        };
    }

    static boolean acked(String answer) {
        return answer != null && answer.startsWith("OK");
    }

    /** True only for {@link #LOCK_LANDING} exactly, after the line end is trimmed. */
    static boolean lockLanding(String answer) {
        return answer != null && LOCK_LANDING.equals(answer.replaceFirst("[\r\n]+$", ""));
    }
}
