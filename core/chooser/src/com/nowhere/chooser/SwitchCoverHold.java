package com.nowhere.chooser;

/**
 * How long the switch-in cover holds (NWP-20261118-13; backlog row "A sign-in whose set-up after the restore
 * outlasts the 15 s switch-in cover drops back to an empty sign-in gate, as if it had failed, and then opens the
 * session by itself"). roamLogin arms the cover before its provisioning steps, and those steps can run for
 * minutes. The cover used to time out on a 15 s clock while the sign-in worker still ran, so the gate dropped to
 * an empty sign-in form and then switched into the session by itself. Now the cover holds while the worker runs,
 * up to {@link #HARD_CAP_MS}. With no worker (the cold-lock resume, or a sign-in after the switch re-stamps the
 * arm) the rule is the old one, {@link #SWITCH_COVER_MS}. Pure (java.lang only) so a javac suite can pin the rule.
 */
final class SwitchCoverHold {
    private SwitchCoverHold() {}

    /** The cover window with no worker running: the old rule, and ChooserActivity.SWITCH_COVER_MS. */
    static final long SWITCH_COVER_MS = 15000L;

    /** The only clock on a worker that never ends: 11 min, longer than InstallWait.HARD_MS (10 min). */
    static final long HARD_CAP_MS = 660_000L;

    /**
     * The cover holds. While the sign-in worker runs: up to HARD_CAP_MS from switchingInAt. With no worker:
     * now - switchingInAt < SWITCH_COVER_MS.
     */
    static boolean inWindow(long now, long switchingInAt, boolean workerRunning) {
        long age = now - switchingInAt;
        if (workerRunning) return age < HARD_CAP_MS;
        return age < SWITCH_COVER_MS;
    }

    /**
     * watchSwitchIn stops waiting. While the worker runs: at HARD_CAP_MS from switchingInAt. With no worker:
     * SWITCH_COVER_MS from the later of the watcher's own start and switchingInAt, so a re-stamp after the
     * watcher started counts from the re-stamp.
     */
    static boolean watcherGivesUp(long now, long watchStart, long switchingInAt, boolean workerRunning) {
        if (workerRunning) return now - switchingInAt >= HARD_CAP_MS;
        return now - Math.max(watchStart, switchingInAt) >= SWITCH_COVER_MS;
    }

    /** A second sign-in is refused while one runs. */
    static boolean refuseSecondLogin(boolean loginInProgress) {
        return loginInProgress;
    }

    /**
     * A sign-in owns the screen from its tap (loginInProgress) to its switch (switchingIn), NWP-20261119-04. While
     * it does, a resume of the gate (for example when a call screen goes away) must not hand the screen back to the
     * gate at rest: the screen hold (FLAG_KEEP_SCREEN_ON) and Unlock stay as the sign-in set them, and the sign-in's
     * own end restores both.
     */
    static boolean signInOwnsScreen(boolean loginInProgress, boolean switchingIn) {
        return loginInProgress || switchingIn;
    }

    /**
     * onResume's GET-COLDLOCK reveal stands aside. The reveal and its idle-gate reset belong to a gate at rest or a
     * cold-lock return. A logoff reap (signingOut), a resume (resumeBusy) or a sign-in (signInOwnsScreen) owns the
     * screen, and a resume from a call must not restore the plain gate under it (NWP-20261119-04).
     */
    static boolean revealStandsAside(boolean signingOut, boolean resumeBusy, boolean loginInProgress, boolean switchingIn) {
        return signingOut || resumeBusy || signInOwnsScreen(loginInProgress, switchingIn);
    }
}
