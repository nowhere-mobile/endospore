package com.nowhere.chooser;

import java.util.function.LongConsumer;
import java.util.function.LongSupplier;

/**
 * Sends the sign-out screen's LOGOUT, and sends it once more if the first never reached the login daemon
 * (NWP-20261116-11; h46 #4 in docs/product-decisions.md, 2026-10-28).
 *
 * <p>Without it, a daemon that init is restarting when the user taps Sign out makes the bounded connect return null,
 * and the screen reboots at once. The reboot loses every profile's pending RAM-only telephony records, although a
 * LOGOUT a few seconds later would have been served.
 *
 * <p>"Never delivered" means the bounded connect returned no socket, or the LOGOUT write failed. Only then does
 * {@link #run} poll every {@link #POLL_MS} for up to {@link #RESTART_WAIT_MS} from that first failure, and send
 * LOGOUT once more as soon as a send is delivered. The retry recovers only a daemon unreachable at connect. A
 * DELIVERED LOGOUT is never resent, whatever its answer (OK, BUSY, a stream end, a read timeout): a plain OK to a
 * second LOGOUT cannot tell "already sealing" from "a restarted daemon lost the logoff". The session does not count
 * the records a reboot costs: that count verb stays gate-only. The caller logs {@link #UNKNOWN_COST} instead.
 *
 * <p>The bound: {@link #TOTAL_MS} is one absolute deadline, {@code failAt + TOTAL_MS} on the run's clock, where
 * {@code failAt} is the time the first send came back undelivered. The resend gets it as {@code deadlineMs} and ends by
 * it: a connect that ends past it writes nothing, and {@link LogoutAck#byDeadline} cuts every blocked read of the
 * answer at it, so neither the connect, nor WAIT lines just inside the 90 s per-read timeout, nor a silent last read
 * can stretch the retry past it (RF-001). The resend's WAIT-line cap is {@link #TOTAL_MS} minus the time already
 * spent, the same instant. The first send gets {@link #NO_DEADLINE} and {@link LogoutAck#MAX_WAIT_MS}: its bounds
 * stay what they were.
 */
final class LogoutRetry {
    static final long RESTART_WAIT_MS = 30_000L; // the wait for init to restart the daemon
    static final long POLL_MS = 2_000L;
    static final long RESEND_READ_MS = 90_000L;
    static final long TOTAL_MS = RESTART_WAIT_MS + RESEND_READ_MS; // the one total bound of the retry
    static final long NO_DEADLINE = Long.MAX_VALUE; // the first send: no deadline beyond its own bounds
    static final String UNKNOWN_COST = "an unknown number of pending telephony record(s) may be lost";

    /** One send's outcome. */
    static final class Result {
        /** The connect returned a socket AND the LOGOUT write succeeded. */
        final boolean delivered;
        /** LogoutAck.answer's value; null when undelivered, on a stream end or on a read timeout. */
        final String reply;

        Result(boolean delivered, String reply) {
            this.delivered = delivered;
            this.reply = reply;
        }
    }

    /**
     * One LOGOUT send: connect, write, then read the answer for at most {@code capMs} of WAIT lines. It ends by
     * {@code deadlineMs} (on the run's clock): past it after the connect, it writes nothing (undelivered); every read
     * of the answer goes through {@link LogoutAck#byDeadline}.
     */
    interface Sender {
        Result send(long capMs, long deadlineMs);
    }

    private LogoutRetry() {}

    /**
     * The first send with {@link LogoutAck#MAX_WAIT_MS} and {@link #NO_DEADLINE}, as before; a delivered first send is
     * returned as it is. An undelivered one is retried: sleep {@link #POLL_MS}, send with the deadline
     * {@code failAt + TOTAL_MS}, until a send is delivered (returned as it is, never resent) or
     * {@link #RESTART_WAIT_MS} has passed since the first failure (the last undelivered result returned).
     */
    static Result run(Sender s, LongSupplier nowMs, LongConsumer sleepMs) {
        Result first = s.send(LogoutAck.MAX_WAIT_MS, NO_DEADLINE);
        if (first.delivered) return first;
        long failAt = nowMs.getAsLong();
        long deadline = failAt + TOTAL_MS;
        Result last = first;
        while (true) {
            sleepMs.accept(POLL_MS);
            long spent = nowMs.getAsLong() - failAt;
            if (spent > RESTART_WAIT_MS) return last;
            long cap = TOTAL_MS - spent;
            if (cap <= 0) return last;
            Result r = s.send(cap, deadline);
            if (r.delivered) return r;
            last = r;
        }
    }
}
