package com.nowhere.chooser;

/** NWP-20261201-13 (backlog "An Auto sweep cannot be paused or stopped", Chester 2026-11-08: "just for the session"):
 *  the landing card's Pause and Stop. The card raises it on the main thread; UnarchiveService.sweepAuto reads it before
 *  the next chunk or MATERIALIZE-APP, so the app in flight always finishes. PAUSED holds the rest until a resume.
 *  STOPPED holds them for the rest of this process: they stay placeholders with their Auto mode and install on a tap.
 *
 *  A process static, as SignOutGate: the card and the service run in the chooser's one process in the roamed user. It
 *  is never written anywhere and never sealed, so the next sign-in, a new user and a new process, starts at NONE. A
 *  cold lock and its resume restart the chooser and sweep again; the login daemon's RAM hold that survives them is the
 *  next harvest's slice (docs/product-decisions.md 2026-11-09, #5). */
final class SweepHold {
    enum State { NONE, PAUSED, STOPPED }

    /** What a sweep pass does with its card when it ends. CONTINUE leaves the card alone for the next pass. */
    enum Close { END, PAUSE, STOP, CONTINUE }

    private static final Object LOCK = new Object();
    private static State state = State.NONE;
    private static long card;
    /** The card of a pause that has ended and that no sweep pass has taken yet. In SweepHold and not on the Resume's
     *  thread: a Resume that lands after the paused broadcast joins the ending pass (SweepJoin) and its thread returns,
     *  so the pass that continues the card runs on the other thread. */
    private static long resumedCard;

    private SweepHold() {}

    /** From NONE or PAUSED: the sweep holds after the app in flight. {@code sweep} is the card a resume continues. */
    static void pause(long sweep) {
        synchronized (LOCK) {
            if (state == State.STOPPED) return;
            state = State.PAUSED;
            card = sweep;
        }
    }

    /** From NONE or PAUSED: the sweep ends after the app in flight. */
    static void stop() {
        synchronized (LOCK) {
            state = State.STOPPED;
            card = 0;
        }
    }

    static boolean held() {
        synchronized (LOCK) { return state != State.NONE; }
    }

    static State state() {
        synchronized (LOCK) { return state; }
    }

    /** Ends a pause and returns its card id (0 if none), which {@link #takeResumed} gives to the next pass. A stop stays:
     *  only a by-hand start or a new process ends it. */
    static long resume() {
        synchronized (LOCK) {
            if (state != State.PAUSED) return 0;
            long resumed = card;
            state = State.NONE;
            card = 0;
            resumedCard = resumed;
            return resumed;
        }
    }

    /** The card the next sweep pass continues, once (0 if none). */
    static long takeResumed() {
        synchronized (LOCK) {
            long resumed = resumedCard;
            resumedCard = 0;
            return resumed;
        }
    }

    /** A by-hand "Install pending apps now" is the user asking for every app now: it ends a pause or a stop. The pass it
     *  starts continues a paused card, which would otherwise offer a Resume with nothing left to resume. */
    static void clear() {
        synchronized (LOCK) {
            if (state == State.PAUSED) resumedCard = card;
            state = State.NONE;
            card = 0;
        }
    }

    /** How a pass closes {@code sweep}'s card. {@code cut}: Pause or Stop left apps not started; a pass that finished
     *  every app ends its card even if Pause came late. A resume or a by-hand start can end the pause after the pass cut
     *  the sweep and before the pass closes the card. The next pass then continues that card, so it must stay open. */
    static Close close(long sweep, boolean cut) {
        synchronized (LOCK) {
            if (!cut) return Close.END;
            if (state == State.PAUSED) return Close.PAUSE;
            if (state == State.STOPPED) return Close.STOP;
            return sweep != 0 && resumedCard == sweep ? Close.CONTINUE : Close.END;
        }
    }

    /** The state's word, for log lines. */
    static String word() {
        switch (state()) {
            case PAUSED: return "paused";
            case STOPPED: return "stopped";
            default: return "none";
        }
    }
}
