package com.nowhere.chooser;

/** NWP-20261126-04: one Auto sweep walk per chooser process. Field-seen on husky 0.5.52 (ticket NW-91ed3c80d0c7): a
 *  sign-in logged `auto sweep started (1 running)` then `(2 running)`, each of its 2 apps was processed twice (the
 *  second sweep waited on MAT_LOCK for the first one's install, then found it `already`), and the periodic-save hold
 *  lasted 396 s against 284 s for one sweep. Each sweep start runs on its own thread, and sweepAuto reads its
 *  pendingAutoApps list once, at its start, so two starts walked the same list.
 *
 *  Three starters reach UnarchiveService's sweep arm within one sign-in: the switch-landing kick
 *  (ChooserActivity.kickAutoMaterialise, from the login and the resume paths), the gate's network re-kick
 *  (AutoSweepNet.rekick) and "Install pending apps now" (ProfileActivity, EXTRA_BY_HAND). So a start that finds a
 *  sweep running JOINS it: enter() returns false and records the start's flags, and when the running pass ends,
 *  exit() hands them back for ONE more pass, which reads a fresh list. An app the first pass installed is not in it.
 *  Two or more joins during one pass collapse into one rerun that carries every joiner's bits.
 *
 *  exit() keeps the join marked running when it returns a rerun: the thread that ran the pass runs the rerun, and a
 *  start in between must join it rather than walk beside it. So every pass MUST end in exit(), on a throw too, or
 *  every later start in this process joins a sweep that never runs again (UnarchiveService.sweepAutoJoined calls it
 *  in a finally). The state is static and in RAM only: a restarted chooser starts idle. java.lang only, so
 *  test-sweep-join-java.sh compiles it with its cases alone. */
final class SweepJoin {
    /** The joiner was "Install pending apps now": the rerun runs on any network (Q042). */
    static final int BY_HAND = 1;
    /** The joiner was a switch-landing start: the rerun may show the landing line. */
    static final int LANDING = 2;

    private static final Object LOCK = new Object();
    private static boolean running;  // a sweep owns the walk
    private static boolean rerun;    // a start joined during the current pass
    private static int pendingFlags; // the OR of every joiner's flags

    private SweepJoin() {}

    /** True when no sweep was running: the caller now owns the walk and must end every pass with exit(). False when
     *  one is running: the start is recorded (flags ORed in) and the running sweep makes one more pass for it. */
    static boolean enter(int flags) {
        synchronized (LOCK) {
            if (!running) {
                running = true;
                return true;
            }
            rerun = true;
            pendingFlags |= flags;
            return false;
        }
    }

    /** Called when a pass ends, normally or by a throw. A start joined during it: the flags of every joiner (>= 0,
     *  0 for a plain start), and the sweep stays running for that rerun. None did: -1, and the sweep is not running. */
    static int exit() {
        synchronized (LOCK) {
            if (rerun) {
                int f = pendingFlags;
                rerun = false;
                pendingFlags = 0;
                return f;
            }
            running = false;
            return -1;
        }
    }

    /** For the cases only: back to idle. */
    static void reset() {
        synchronized (LOCK) {
            running = false;
            rerun = false;
            pendingFlags = 0;
        }
    }
}
