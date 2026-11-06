package com.nowhere.chooser;

import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;
import java.util.function.Supplier;

/**
 * NWP-20261021-02: the idle cold lock's whole PRE-COMMIT decision, lifted out of IdleLogoffReceiver.onReceive so a
 * javac suite can execute it (java.* only, no Android SDK). The receiver gathers the inputs, calls {@link #decide},
 * then logs, traces, re-arms or falls into the commit exactly as the verdict says.
 *
 * The idle cold lock is the at-rest security bound for an unattended phone (docs/lock-model.md), so every guard
 * here fails toward LOCKING: a failed call check proceeds, a failed playback check proceeds, and any answer from the
 * daemon's GET-SWEEP but LIVE (none, an error, an older daemon) proceeds.
 *
 * The rule, in this order and no other:
 *   1. not live, or not locked -> NONE (nothing is probed).
 *   2. screen on -> DEFER SCREENON_DEFER_MS. The late-grace claim is NOT spent.
 *   3. a late delivery AND the once-per-arm claim succeeds -> DEFER LATE_REGRACE_MS. The claim is evaluated only
 *      when the delivery is late.
 *   4. in a call -> DEFER CALL_DEFER_MS. A null inCall is a failed check: go on.
 *   5. NWP-20261120-02: the audio hold is on and audio plays in a signed-in user -> DEFER AUDIO_DEFER_MS until
 *      the audio cap has passed since the hold began; then go on, and LOCK AUDIO_CAP unless step 6 returns. Audio
 *      stopped after a fire this hold deferred -> DEFER standbyMs: the standby countdown starts again. A null
 *      audioPlaying is a failed check, and FALSE without a held fire is nothing playing: go on.
 *   6. the installs hold is on and the daemon's sweep answer is LIVE -> DEFER INSTALLS_DEFER_MS until the cap
 *      has passed since the hold began, then LOCK anyway. Any other answer -> LOCK.
 *   7. otherwise LOCK.
 *
 * Both holds count from ONE start: the first fire in this idle cycle that either hold deferred. With the real caps
 * (installs 60 min, audio 2 h) no wait passes 2 hours from that start while audio plays; after playback stops, at
 * most one more standby period follows. This answers the 2026-11-01 decision's "how the two caps combine".
 *
 * {@link #afterReply} is the other half: what the worker does once the daemon has answered (or not).
 */
final class IdleLockGate {
    private IdleLockGate() {}

    // NWP-20260909-01: a delivery this far past its deadline was THROTTLED -- an on-time
    // setExactAndAllowWhileIdle lands sub-second -- so something RELEASED it rather than the deadline arriving.
    static final long LATE_FIRE_MS = 2000;
    // ...and how long to step aside for, ONCE, so the screen broadcast that came with that release can land.
    // Short on purpose: it is the cost this adds to the at-rest bound in the common case, and the bound is
    // already Doze-bound by minutes (a delivery at least 2m56s past its deadline was measured on frankel
    // 2026-09-09, and a second one fired somewhere inside a 7m31s window), so seconds here are noise.
    static final long LATE_REGRACE_MS = 3000;
    /** #181: retry delay while the screen is on. */
    static final long SCREENON_DEFER_MS = 60 * 1000L;
    /** #145: retry delay while a call is in progress. */
    static final long CALL_DEFER_MS = 2 * 60 * 1000L;
    /** NWP-20261005-02: retry delay while the session's Auto apps are still installing. */
    static final long INSTALLS_DEFER_MS = 5 * 60 * 1000L;
    /** NWP-20261120-02: retry delay while audio is playing in a signed-in user. */
    static final long AUDIO_DEFER_MS = 60 * 1000L;
    /** android.os.UserHandle.PER_USER_RANGE: uid / this is the user id. */
    static final int PER_USER_RANGE = 100000;

    enum Kind { NONE, DEFER, LOCK }

    /** Which path decided, so the receiver can reproduce today's logcat line for it. */
    enum Reason {
        NOT_LIVE_OR_UNLOCKED, SCREEN_ON, LATE_FIRE, IN_CALL, AUDIO_HELD, AUDIO_STOPPED, AUDIO_CAP, INSTALLS_HELD,
        INSTALLS_CAP, LOCK
    }

    static final class Verdict {
        final Kind kind;
        final Reason reason;
        /** The re-arm delay; 0 unless DEFER. */
        final long delayMs;
        /** The idleTrace token for this path, or null when the path emits none. */
        final String trace;
        /** The value to write back to the start of either hold; the input value on every path but the installs
         *  LIVE arm and the audio playing arm. */
        final long heldSinceMs;
        /** now - held-since on the installs and audio arms (the minutes in the log line); 0 elsewhere. */
        final long heldMs;
        /** The value to write back to sAudioHolding: the input on NONE, SCREEN_ON, LATE_FIRE and IN_CALL, true on
         *  AUDIO_HELD, false elsewhere. */
        final boolean audioHolding;

        private Verdict(Kind kind, Reason reason, long delayMs, String trace, long heldSinceMs, long heldMs,
                boolean audioHolding) {
            this.kind = kind;
            this.reason = reason;
            this.delayMs = delayMs;
            this.trace = trace;
            this.heldSinceMs = heldSinceMs;
            this.heldMs = heldMs;
            this.audioHolding = audioHolding;
        }
    }

    /** One player from getActivePlaybackConfigurations counts when it is STARTED, has a media-like usage and is not
     *  user 0's: a negative uid is the anonymized copy a caller without MODIFY_AUDIO_ROUTING gets; a user-0 uid (the
     *  gate's own alarm or ringtone) never counts. */
    static boolean countsAsAudio(boolean started, boolean mediaUsage, int clientUid) {
        return started && mediaUsage && (clientUid < 0 || clientUid / PER_USER_RANGE != 0);
    }

    /**
     * @param claimLateGrace the once-per-arm claim; called only for a screen-off, late delivery
     * @param inCall         TRUE in a call, FALSE not, null when the call check itself failed
     * @param sweepReply     the daemon's GET-SWEEP answer; called only when holdForInstalls
     * @param heldSinceMs    when either hold began in this idle cycle (0 = not begun)
     * @param nowMs          the clock; read only AFTER the sweep reply is in, because the round trip can take
     *                       seconds and a reading from before it could carry a hold across the cap
     * @param capMs          how long the installs hold may last
     * @param holdForAudio   the audio hold is on for this profile
     * @param audioPlaying   TRUE when audio plays in a signed-in user, FALSE not, null when the check itself failed
     * @param audioHolding   the previous fire deferred for audio
     * @param audioCapMs     how long the audio hold may last
     * @param standbyMs      the standby time, the delay once audio has stopped
     */
    static Verdict decide(boolean live, boolean locked, boolean screenOn, long lateByMs,
            BooleanSupplier claimLateGrace, Boolean inCall, boolean holdForInstalls,
            Supplier<String> sweepReply, long heldSinceMs, LongSupplier nowMs, long capMs,
            boolean holdForAudio, Boolean audioPlaying, boolean audioHolding, long audioCapMs, long standbyMs) {
        if (!live || !locked) {
            return new Verdict(Kind.NONE, Reason.NOT_LIVE_OR_UNLOCKED, 0, null, heldSinceMs, 0, audioHolding);
        }
        if (screenOn) {
            return new Verdict(Kind.DEFER, Reason.SCREEN_ON, SCREENON_DEFER_MS, "defer screenon", heldSinceMs, 0,
                    audioHolding);
        }
        if (lateByMs > LATE_FIRE_MS && claimLateGrace.getAsBoolean()) {
            return new Verdict(Kind.DEFER, Reason.LATE_FIRE, LATE_REGRACE_MS,
                    "defer latefire s=" + (lateByMs / 1000L), heldSinceMs, 0, audioHolding);
        }
        if (Boolean.TRUE.equals(inCall)) {
            return new Verdict(Kind.DEFER, Reason.IN_CALL, CALL_DEFER_MS, "defer call", heldSinceMs, 0, audioHolding);
        }
        long audioStart = heldSinceMs, audioHeld = 0;
        boolean audioCapPassed = false;
        if (holdForAudio) {
            if (Boolean.TRUE.equals(audioPlaying)) {
                long at = nowMs.getAsLong();
                audioStart = heldSinceMs != 0L ? heldSinceMs : at;
                audioHeld = at - audioStart;
                if (audioHeld < audioCapMs) {
                    return new Verdict(Kind.DEFER, Reason.AUDIO_HELD, AUDIO_DEFER_MS,
                            "defer audio held=" + (audioHeld / 60000L), audioStart, audioHeld, true);
                }
                audioCapPassed = true;
            } else if (Boolean.FALSE.equals(audioPlaying) && audioHolding) {
                return new Verdict(Kind.DEFER, Reason.AUDIO_STOPPED, standbyMs, "audio stopped", heldSinceMs, 0,
                        false);
            }
        }
        if (holdForInstalls) {
            String r = sweepReply.get();
            if (r != null && r.startsWith("LIVE")) {
                long now = nowMs.getAsLong();
                long hs = heldSinceMs == 0L ? now : heldSinceMs;
                long held = now - hs;
                if (held < capMs) {
                    return new Verdict(Kind.DEFER, Reason.INSTALLS_HELD, INSTALLS_DEFER_MS,
                            "defer installs held=" + (held / 60000L), hs, held, false);
                }
                return new Verdict(Kind.LOCK, Reason.INSTALLS_CAP, 0, "installs cap reached", hs, held, false);
            }
        }
        if (audioCapPassed) {
            return new Verdict(Kind.LOCK, Reason.AUDIO_CAP, 0, "audio cap reached", audioStart, audioHeld, false);
        }
        return new Verdict(Kind.LOCK, Reason.LOCK, 0, null, heldSinceMs, 0, false);
    }

    /** What the worker's finally block does with the daemon's COLD-LOCK-IDLE answer. */
    static final class AfterReply {
        /** Re-arm the idle alarm: no lock positively started. */
        final boolean rearm;
        /** Release the cold wakelock: the daemon positively found no session. */
        final boolean releaseWake;

        private AfterReply(boolean rearm, boolean releaseWake) {
            this.rearm = rearm;
            this.releaseWake = releaseWake;
        }
    }

    /**
     * NWP-20260922-07 / NWP-20260914-01: the two questions a COLD-LOCK-IDLE reply answers, kept apart on purpose.
     * The daemon's handleColdLock answers exactly three first lines: "OK NOSESSION" (nothing to lock), "OK LOGOFF"
     * (a logoff is in flight) and "OK LOCKING" (the teardown started).
     *
     * <ul>
     * <li>rearm = not "OK LOCKING". Broad on purpose: re-arming a lock that did happen is harmless (doColdLock's
     *     cancelIdleWatcher clears it), while NOT re-arming one that did not leaves a live, CE-unlocked session
     *     with no idle bound and no 12 h wipe (NWP-20260922-07). A missed lock token therefore only re-arms.</li>
     * <li>releaseWake = "OK NOSESSION" exactly. Affirmative on purpose: the cold wakelock is not reference-counted,
     *     so a stray release frees the one the reap watcher's stop needs (NWP-20260914-01). An "ERR-NOSESSION", an
     *     unknown or a garbled reply keeps the lock; COLD_WAKE_MS bounds it.</li>
     * </ul>
     *
     * @param reply the daemon's first line, or null when there was none (connect or read failure, read timeout,
     *              the watchdog's close)
     */
    static AfterReply afterReply(String reply) {
        String t = reply == null ? "" : reply.trim();
        boolean locking = "OK LOCKING".equals(t);
        boolean nothingToLock = "OK NOSESSION".equals(t);
        return new AfterReply(!locking, nothingToLock);
    }
}
