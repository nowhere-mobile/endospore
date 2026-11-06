package com.nowhere.chooser;

/**
 * Cases for SwitchCoverHold (NWP-20261118-13; the sign-in's hold on the screen, NWP-20261119-04). Times are passed in; nothing sleeps. args[0] is InstallWait.HARD_MS,
 * read from the source by test-switch-cover-hold-java.sh.
 */
public final class SwitchCoverHoldCases {
    private static int n = 0, failed = 0;

    private static void check(String id, boolean got, boolean want) {
        n++;
        if (got == want) {
            System.out.println("  PASS  " + id);
        } else {
            failed++;
            System.out.println("  FAIL  " + id + ": got " + got + ", want " + want);
        }
    }

    public static void main(String[] args) {
        final long installHard = Long.parseLong(args[0]);
        final long at = 1_000_000L;
        final long cap = SwitchCoverHold.HARD_CAP_MS;

        // While the sign-in worker runs, the cover holds well past 15 s, up to the hard cap.
        check("C1 worker running: covered at +16 s", SwitchCoverHold.inWindow(at + 16_000, at, true), true);
        check("C2 worker running: covered at +2 min", SwitchCoverHold.inWindow(at + 120_000, at, true), true);
        check("C3 worker running: covered at +10 min", SwitchCoverHold.inWindow(at + 600_000, at, true), true);
        check("C4a worker running: covered 1 ms before the hard cap", SwitchCoverHold.inWindow(at + cap - 1, at, true), true);
        check("C4b worker running: not covered at the hard cap", SwitchCoverHold.inWindow(at + cap, at, true), false);
        check("C4c worker running: not covered a minute past the hard cap", SwitchCoverHold.inWindow(at + cap + 60_000, at, true), false);

        // With no worker (the cold-lock resume, or after the re-stamp), the old 15 s rule.
        check("C5a no worker: covered at +14 s", SwitchCoverHold.inWindow(at + 14_000, at, false), true);
        check("C5b no worker: covered at +14.999 s", SwitchCoverHold.inWindow(at + 14_999, at, false), true);
        check("C6a no worker: not covered at +15 s", SwitchCoverHold.inWindow(at + 15_000, at, false), false);
        check("C6b no worker: not covered at +16 s", SwitchCoverHold.inWindow(at + 16_000, at, false), false);
        final long rs = at + 150_000; // the switch lambda re-stamps switchingInAt after a 2.5 min set-up
        check("C7a after the re-stamp: covered at +14 s from it", SwitchCoverHold.inWindow(rs + 14_000, rs, false), true);
        check("C7b after the re-stamp: not covered at +16 s from it", SwitchCoverHold.inWindow(rs + 16_000, rs, false), false);

        // The watcher gives up on the same rule.
        check("W1a worker running: the watcher waits at +16 s", SwitchCoverHold.watcherGivesUp(at + 16_000, at, at, true), false);
        check("W1b worker running: the watcher waits at +2 min", SwitchCoverHold.watcherGivesUp(at + 120_000, at + 5_000, at, true), false);
        check("W1c worker running: the watcher waits at +10 min", SwitchCoverHold.watcherGivesUp(at + 600_000, at, at, true), false);
        check("W2 worker running: the watcher gives up at the hard cap", SwitchCoverHold.watcherGivesUp(at + cap, at + 5_000, at, true), true);
        final long ws = at + 3_000; // a relaunch started the watcher 3 s after the arm
        check("W3a no worker: the watcher waits 14 s from its own start", SwitchCoverHold.watcherGivesUp(ws + 14_000, ws, at, false), false);
        check("W3b no worker: the watcher gives up 15 s from its own start", SwitchCoverHold.watcherGivesUp(ws + 15_000, ws, at, false), true);
        final long ws2 = at + 2_000;
        check("W4a re-stamp after the watcher started: waits 14 s from the re-stamp", SwitchCoverHold.watcherGivesUp(rs + 14_000, ws2, rs, false), false);
        check("W4b re-stamp after the watcher started: gives up 16 s from the re-stamp", SwitchCoverHold.watcherGivesUp(rs + 16_000, ws2, rs, false), true);

        // A second sign-in is refused while one runs.
        check("R1a a second sign-in is refused while loginInProgress", SwitchCoverHold.refuseSecondLogin(true), true);
        check("R1b a sign-in starts when none runs", SwitchCoverHold.refuseSecondLogin(false), false);

        // NWP-20261119-04: a sign-in owns the screen from its tap to its switch.
        check("S1a signInOwnsScreen: no sign-in", SwitchCoverHold.signInOwnsScreen(false, false), false);
        check("S1b signInOwnsScreen: loginInProgress alone", SwitchCoverHold.signInOwnsScreen(true, false), true);
        check("S1c signInOwnsScreen: switchingIn alone", SwitchCoverHold.signInOwnsScreen(false, true), true);
        check("S1d signInOwnsScreen: both", SwitchCoverHold.signInOwnsScreen(true, true), true);
        // The GET-COLDLOCK reveal stands aside for a logoff, a resume or a sign-in; it runs only on a gate at rest.
        check("A1 revealStandsAside: all false -> the reveal runs", SwitchCoverHold.revealStandsAside(false, false, false, false), false);
        check("A2 revealStandsAside: signingOut alone", SwitchCoverHold.revealStandsAside(true, false, false, false), true);
        check("A3 revealStandsAside: resumeBusy alone", SwitchCoverHold.revealStandsAside(false, true, false, false), true);
        check("A4 revealStandsAside: loginInProgress alone (a call during the restore)", SwitchCoverHold.revealStandsAside(false, false, true, false), true);
        check("A5 revealStandsAside: switchingIn alone", SwitchCoverHold.revealStandsAside(false, false, false, true), true);

        // The constants.
        check("K1a SWITCH_COVER_MS is 15 s", SwitchCoverHold.SWITCH_COVER_MS == 15_000L, true);
        check("K1b HARD_CAP_MS is longer than InstallWait.HARD_MS (" + installHard + ")", cap > installHard, true);

        if (failed == 0) {
            System.out.println("ALL " + n + " PASS");
        } else {
            System.out.println(failed + " of " + n + " FAILED");
            System.exit(1);
        }
    }
}
