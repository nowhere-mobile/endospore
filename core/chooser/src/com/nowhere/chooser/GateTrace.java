package com.nowhere.chooser;

/**
 * NWP-20260914-02: put ONE gate-alarm event into the daemon's gate.log, which a GATE-filed issue report can
 * carry.
 *
 * <p>WHY THIS CLASS EXISTS. On 2026-09-13 a tester reported the gate alarm flashing up and vanishing, then
 * not appearing at all, and NOTHING could be learned from any of the three tickets he filed. Everything this
 * activity does is logged through {@code android.util.Log} — i.e. logcat — and a locked {@code user} build
 * does not give us logcat: every ticket's avc section says so in as many words, {@code "NO source could be
 * read -- /system/bin/logcat (permission denied)"}. So the gate could not report on the gate.
 *
 * <p>⚠ THE CHOOSER CANNOT WRITE THE FILE ITSELF, and this is not a style choice. {@code nowhere_chooser} has
 * no write on {@code /data/nowhere} — the repo already records the consequence of pretending otherwise
 * (backlog, {@code NWP-20260904-10}: <i>"The chooser's three reboot issuers are deliberately NOT wired:
 * nowhere_chooser cannot write /data/nowhere, and dead code claiming otherwise would be worse than the
 * gap."</i>). So the daemon is the only writer and this sends it a verb.
 *
 * <p>⚠ WHAT MAY BE SENT IS A CLOSED SET, ENFORCED ON THE DAEMON SIDE. A verb outside that set is recorded as
 * {@code trace-unknown} — never as its own text — so no string from here can ever reach a file that is
 * rendered on screen at the gate. Nothing here is a filter to be gotten right; the guarantee lives in
 * {@code gate_log.go}. Callers pass a token and at most one integer, and that is all the wire can express.
 */
final class GateTrace {
    private GateTrace() {}

    /** Fire-and-forget one event. Never blocks the caller, never throws, never affects control flow. */
    static void ev(String verb) { send(verb, null, 0); }

    /** Fire-and-forget one event carrying an integer under a closed key ({@code in}, {@code ms}, {@code fields}). */
    static void ev(String verb, String key, int val) { send(verb, key, val); }

    private static void send(final String verb, final String key, final int val) {
        // ⚠ ALWAYS OFF THE MAIN THREAD, AND ALWAYS AFTER THE USER-VISIBLE WORK. The alarm rings during a cold
        // lock, when a seal can hold the daemon's session lock for minutes. GATE-TRACE is on the daemon's
        // lock-free allowlist precisely so it cannot queue behind that — but a socket is still a socket, and
        // a diagnostic that can delay the ringing of an alarm would be recreating the very complaint this
        // whole feature exists to fix.
        try {
            new Thread(() -> {
                try {
                    String line = "GATE-TRACE\n" + verb + (key == null ? "" : " " + key + "=" + val) + "\n";
                    DaemonSocket.roundTrip(line, 1500);
                } catch (Throwable ignore) {
                    // Deliberately silent: the reply is not actionable and there is nowhere useful to put a
                    // failure. This is the ONE place in this feature where silence is correct — the event is
                    // already lost, and logging to logcat (which we cannot read on this build) would only
                    // create the appearance of a diagnostic.
                }
            }, "nowhere-gate-trace").start();
        } catch (Throwable ignore) {
            // Thread creation failed (shutdown). Nothing to do; the alarm matters more than its trace.
        }
    }
}
