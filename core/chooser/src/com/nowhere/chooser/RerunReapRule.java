package com.nowhere.chooser;

/** NWP-20261128-04, backlog row "A deleted profile's user stays running, with its CE unlocked, when the login daemon
 *  dies between the delete's SWITCH and its REAP ...": the gate's half of RERUN-REAP (core/agent/rerun_reap.go).
 *
 *  Every sign-out and delete queues SWITCH and REAP together. When the daemon dies after the gate acks SWITCH, the
 *  restarted daemon has lost the queue, and nothing removes the user. The reap watcher keeps a record of the switched
 *  uid. When no REAP or LOCK of that uid comes within RERUN_AFTER_MS, the gate asks the daemon to re-run the
 *  teardown, and removes the user itself when that also fails (docs/product-decisions.md 2026-10-25 h45 #2, a
 *  delete; 2026-10-30 h48 #3, a sign-out; 2026-11-02 h53 #4, a sign-out's re-run is the removal alone). No reboot.
 *
 *  A COLD switch never re-runs: LOCK follows it, after the alarm relay and the media sweep, and RERUN-REAP would
 *  answer ERR-PARKED. An UNKNOWN switch (its GET-COLDLOCK probe got no answer) is never removed before the daemon
 *  answers OK: only that answer rules out a .coldlock marker, and removing a cold-locked user destroys a resumable
 *  session.
 *
 *  Pure: java.lang only, so test-rerun-reap-rule-java.sh compiles it with its cases alone. */
final class RerunReapRule {
    private RerunReapRule() {}

    // The kind of a switch, from the GET-COLDLOCK probe the SWITCH branch sends.
    static final int COLD = 0;    // the probe answered a line that starts with COLDLOCK
    static final int WARM = 1;    // the probe answered, and the answer does not start with COLDLOCK
    static final int UNKNOWN = 2; // the probe got no answer ("") or threw

    // Decisions.
    static final int WAIT = 10;       // do nothing on this pass
    static final int RERUN = 11;      // send RERUN-REAP now
    static final int DONE = 12;       // the daemon took the re-run (OK) or the user is gone (GONE)
    static final int RETRY = 13;      // ask again RETRY_MS later
    static final int REMOVE = 14;     // the gate removes the user itself (doRemove)
    static final int STAND_DOWN = 15; // forget the record; never remove

    // The watcher's stages for a record.
    static final int ST_SWITCHED = 1; // waiting for REAP or LOCK after the switch
    static final int ST_ASK = 2;      // sending RERUN-REAP, one try per due time
    static final int ST_OK_WAIT = 3;  // the daemon answered OK; waiting for its REAP

    /** The third failed try is the last. */
    static final int MAX_TRIES = 3;

    /** It sits above the daemon's longest live fallback: reapSwitchWait 8 s and reapRemoveWait 12 s, each doubled
     *  once by requeueForPending, so 2 x 8 s + 2 x 12 s = 40 s from the queueing. A live daemon's own fallback always
     *  acts first, and the gate acts only when that daemon is gone. */
    static final long RERUN_AFTER_MS = 45_000L;

    /** The gap between two tries. */
    static final long RETRY_MS = RERUN_AFTER_MS / 3;

    /** The kind of a switch from the GET-COLDLOCK answer. "" (no answer) or null is UNKNOWN, never WARM. */
    static int kindOf(String probe) {
        String p = probe == null ? "" : probe.trim();
        if (p.isEmpty()) return UNKNOWN;
        return p.startsWith("COLDLOCK") ? COLD : WARM;
    }

    /** WAIT or RERUN for a switch that no REAP or LOCK has followed yet. */
    static int afterSwitch(int kind, long switchedAt, long now) {
        if (kind == COLD) return WAIT;
        return now - switchedAt >= RERUN_AFTER_MS ? RERUN : WAIT;
    }

    /** The decision on a RERUN-REAP reply. tries counts the tries made, this one included (1-based). */
    static int onReply(String reply, int tries, int kind) {
        String r = reply == null ? "" : reply.trim();
        switch (r) {
            case "OK":
            case "GONE":
                return DONE;
            case "ERR-LIVE":
            case "ERR-PARKED":
                return STAND_DOWN;
            case "BUSY":
            case "":
                return tries < MAX_TRIES ? RETRY : failed(kind);
            default:
                return failed(kind);
        }
    }

    /** A failed re-run removes only a WARM switch's user. */
    private static int failed(int kind) {
        return kind == WARM ? REMOVE : STAND_DOWN;
    }

    /** WAIT, or REMOVE once RERUN_AFTER_MS has passed since the daemon's OK with no REAP for that uid. The same for
     *  WARM and UNKNOWN: the OK said that no session and no cold lock holds the user. */
    static int afterOk(long okAt, long now) {
        return now - okAt >= RERUN_AFTER_MS ? REMOVE : WAIT;
    }

    /** The class token a log line carries. It never echoes the raw reply. */
    static String replyClass(String reply) {
        String r = reply == null ? "" : reply.trim();
        switch (r) {
            case "OK":
            case "GONE":
            case "BUSY":
            case "ERR-LIVE":
            case "ERR-PARKED":
            case "ERR":
                return r;
            case "":
                return "no-answer";
            default:
                return "unknown";
        }
    }
}
