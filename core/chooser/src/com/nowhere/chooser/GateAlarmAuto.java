package com.nowhere.chooser;

/**
 * NWP-20261116-12: when an unattended gate alarm stops itself. Pure Java (no android.*) so the javac suite
 * (test-gate-alarm-auto-java.sh) proves it.
 *
 * Decided twice: dn-1023 #12 (2026-10-24), "the gate's alarm stops itself after 10 minutes of ringing by snoozing,
 * and is dismissed after three unattended snoozes"; and #64 (dn-1110 #2, 2026-10-22), "unanswered for 10 minutes it
 * falls silent as a Snooze, up to three times, and then it is dismissed".
 *
 * Inferences, not stated by Chester: the snooze is GateAlarmActivity's own (SNOOZE_MS), and "unattended" means
 * three automatic snoozes in a row with no tap. A tap (Snooze, Dismiss) or a volume press is attended and starts
 * the count over: the user's Snooze re-arms through the two-argument ChooserActivity.scheduleGateAlarmAt, which
 * carries 0, and a volume press cancels the timer, so nothing re-arms with the old count.
 *
 * The count rides the armed alarm's PendingIntent (EXTRA) and never touches disk: it is a number from 0 to 3 that
 * names no user, no time and no profile, and a power-off loses it with the alarm.
 */
final class GateAlarmAuto {
    private GateAlarmAuto() {}

    /** How long a gate alarm rings with nobody acting on it before it snoozes or dismisses itself. */
    static final long RING_MS = 10 * 60 * 1000L;
    /** Automatic snoozes in a row before the next unattended ring is dismissed. */
    static final int MAX_AUTO_SNOOZES = 3;
    /** The Intent extra (int) that carries the automatic snoozes so far, alarm -> receiver -> activity. */
    static final String EXTRA = "com.nowhere.chooser.extra.AUTO_SNOOZES";

    /** The count clamped to [0, MAX_AUTO_SNOOZES]: a bad extra can neither ring forever nor go negative. */
    static int sane(int n) {
        return n < 0 ? 0 : Math.min(n, MAX_AUTO_SNOOZES);
    }

    /** true = an unattended ring after soFar automatic snoozes snoozes again; false = it is dismissed. */
    static boolean snoozes(int soFar) {
        return sane(soFar) < MAX_AUTO_SNOOZES;
    }

    /** The count the re-armed alarm carries after one more automatic snooze. */
    static int next(int soFar) {
        return sane(soFar) + 1;
    }
}
