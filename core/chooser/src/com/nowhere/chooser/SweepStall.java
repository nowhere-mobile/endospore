package com.nowhere.chooser;

/** NWP-20261203-03: the Auto sweep's step watch, for the backlog row "P1: An Auto sweep stalls after its first fetch
 *  and no app installs for the rest of the session ..." (frankel 0.5.55, NW-349dcb68882a / NW-8d4e018a16d7). After one
 *  RESTORE-ODDATA answered OK, login.log held 40 minutes with no `auto sweep app` and no `auto sweep ended` line: the
 *  sweep held MAT_LOCK, every tap and every joined start waited behind it, and nothing named the step it waited in.
 *  The cause is not known; this class names the step and bounds it.
 *
 *  The sweep thread marks each step it enters (UnarchiveService.step) with a token of {@link #STEPS} and the app's
 *  index; each PROG frame and each InstallWait tick is progress. The watch thread (`nowhere-sweep-watch`) calls
 *  {@link #tick} every 30 s, which sends AUTO-SWEEP-STEP to the daemon:
 *    - `stall` once a step has made no progress for {@link #STALL_MS}, and again every {@link #REPEAT_MS} while it lasts;
 *    - `ended` when a step that was reported stalled ends (the next step, or the next pass);
 *    - `abandoned` once, after {@link #HARD_MS} without progress: the sink interrupts the sweep thread and closes its
 *      daemon socket, and {@link #abandoned} is true until the next pass's {@link #reset}, so the sweep's loops stop
 *      and the rest of the work list waits for the next sweep;
 *    - `joined` (sent by UnarchiveService.sweepJoinedNote) when a start joins a running sweep, with its step and age.
 *  Every line is a kind, a step token, two numbers and a duration: never a package, a label or a path. The tokens
 *  mirror core/agent/auto_sweep.go (autoSweepStepKinds, autoSweepStepTokens, parseSweepStep); test-sweep-stall-java.sh
 *  compares them.
 *
 *  `lock` is the wait for MAT_LOCK, and it also covers the time just after the sweep takes the lock, in
 *  materializeAndInstall's fast paths (already whole, restore-only), before materializeLocked names a step.
 *
 *  Pure (java.lang only, no Android): time is a parameter, so the javac suite drives a fake clock. All state is
 *  guarded by the class monitor; {@link #tick} calls the sink's send outside it, because a send is socket I/O, and
 *  its abandon inside it, bound to the pass that went past HARD_MS. */
final class SweepStall {
    private SweepStall() {}

    static final String LIST = "list";
    static final String CARD = "card";
    static final String SEAL_HOLD = "seal-hold";
    static final String TAP = "tap";
    static final String RESTORE_ONLY = "restore-only";
    static final String LOCK = "lock";
    static final String DEP_FETCH = "dep-fetch";
    static final String DEP_INSTALL = "dep-install";
    static final String DEP_RESTORE = "dep-restore";
    static final String FETCH = "fetch";
    static final String VERSION = "version";
    static final String INSTALL = "install";
    static final String RESTORE = "restore";
    static final String REPORT = "report";
    static final String BUSY_WAIT = "busy-wait";
    static final String[] STEPS = { LIST, CARD, SEAL_HOLD, TAP, RESTORE_ONLY, LOCK, DEP_FETCH, DEP_INSTALL,
            DEP_RESTORE, FETCH, VERSION, INSTALL, RESTORE, REPORT, BUSY_WAIT };

    static final String STALL = "stall";
    static final String ENDED = "ended";
    static final String ABANDONED = "abandoned";
    static final String JOINED = "joined";
    static final String[] KINDS = { STALL, ENDED, ABANDONED, JOINED };

    /** No progress for this long: the first `stall` line. */
    static final long STALL_MS = 5L * 60 * 1000;
    /** While the stall lasts, one more `stall` line per period. */
    static final long REPEAT_MS = 10L * 60 * 1000;
    /** No progress for this long: the pass is abandoned. Above UnarchiveService.READ_CAP_MS plus the connect cap
     *  (CONNECT_CAP_MS), so a daemon call that hits its own caps returns first. */
    static final long HARD_MS = 25L * 60 * 1000;
    static final int MAX_N = 9999;
    static final long MAX_SECS = 86_400L;

    /** Where tick's lines go: the daemon (send, outside the monitor), and the pass's abandon (abandon, under the
     *  class monitor and only for the pass that went past HARD_MS: it must not block). */
    interface Sink {
        void send(String req);
        void abandon();
    }

    private static String step; // null: no step
    private static int i, n;
    private static long stepSince, lastProgress, nextStallAt, lastNow;
    private static boolean stalledThisStep, abandoned, abandonSent;
    private static long pass;
    private static String endedStep; // the pending `ended`, or null
    private static int endedI, endedN;
    private static long endedSecs;

    private static boolean known(String[] set, String tok) {
        if (tok == null) return false;
        for (String t : set) if (t.equals(tok)) return true;
        return false;
    }

    /** A stalled current step becomes the pending `ended`, `secs` from its start to `now`. Under the monitor. */
    private static void endStalled(long now) {
        if (step == null || !stalledThisStep) return;
        endedStep = step;
        endedI = i;
        endedN = n;
        endedSecs = Math.max(0, now - stepSince) / 1000;
    }

    /** A new pass: no step, not abandoned. A step the last pass left stalled still gets its `ended`. */
    static synchronized void reset() {
        endStalled(lastNow);
        step = null;
        i = n = 0;
        stalledThisStep = abandoned = abandonSent = false;
        pass++;
    }

    /** The pass number {@link #reset} last set, so the watch can end only the pass it watched. */
    static synchronized long pass() { return pass; }

    /** The sweep is over (the watch saw no sweep thread): a stalled step gets its `ended`, and no step is left. Only
     *  when `forPass` is still the current pass, so a new pass that started meanwhile keeps its step. */
    static synchronized void close(long forPass, long now) {
        if (forPass != pass) return;
        lastNow = now;
        endStalled(now);
        step = null;
    }

    /** The sweep enters `token` for app `ai` of `an`. An unknown token changes nothing. */
    static synchronized void enter(String token, int ai, int an, long now) {
        if (!known(STEPS, token)) return;
        lastNow = now;
        endStalled(now);
        step = token;
        i = ai;
        n = an;
        stepSince = lastProgress = now;
        nextStallAt = now + STALL_MS;
        stalledThisStep = false;
    }

    /** {@link #enter(String, int, int, long)} keeping the current app index. */
    static synchronized void enter(String token, long now) { enter(token, i, n, now); }

    /** The step moved (a PROG frame, an InstallWait tick). The step and its stall record do not change. */
    static synchronized void progress(long now) {
        lastNow = now;
        lastProgress = now;
        nextStallAt = now + STALL_MS;
    }

    static synchronized String step() { return step; }
    static synchronized int i() { return i; }
    static synchronized int n() { return n; }
    /** Seconds since the current step began. */
    static synchronized long age(long now) { return Math.max(0, now - stepSince) / 1000; }
    static synchronized boolean abandoned() { return abandoned; }

    /** "AUTO-SWEEP-STEP\n<kind>\n<step>\n<i>\n<n>\n<secs>\n", or null unless 0 <= i <= n <= MAX_N,
     *  0 <= secs <= MAX_SECS and both tokens are of the closed sets. */
    static String request(String kind, String stepToken, int ai, int an, long secs) {
        if (!known(KINDS, kind) || !known(STEPS, stepToken)) return null;
        if (ai < 0 || ai > an || an > MAX_N || secs < 0 || secs > MAX_SECS) return null;
        return "AUTO-SWEEP-STEP\n" + kind + "\n" + stepToken + "\n" + ai + "\n" + an + "\n" + secs + "\n";
    }

    /** Send what is due at `now`: the pending `ended`, then a due `stall`, then a due `abandoned` and the abandon.
     *  The sends run outside the monitor; the abandon runs INSIDE it, and only while the pass that went past HARD_MS
     *  is still the current pass. UnarchiveService starts a pass (SWEEP_THREAD, reset) and owns SWEEP_SOCK under this
     *  monitor too, so a pass that starts while a send waits is never interrupted or closed by the earlier pass's
     *  abandon. */
    static void tick(long now, Sink sink) {
        String ended = null, stall = null, gone = null;
        long gonePass = 0;
        synchronized (SweepStall.class) {
            lastNow = now;
            if (endedStep != null) {
                ended = request(ENDED, endedStep, endedI, endedN, Math.min(endedSecs, MAX_SECS));
                endedStep = null;
            }
            if (step != null && now >= nextStallAt) {
                stall = request(STALL, step, i, n, Math.min((now - lastProgress) / 1000, MAX_SECS));
                stalledThisStep = true;
                nextStallAt += REPEAT_MS;
                if (nextStallAt <= now) nextStallAt = now + REPEAT_MS; // a late tick does not send a burst
            }
            if (step != null && !abandonSent && now - lastProgress >= HARD_MS) {
                gone = request(ABANDONED, step, i, n, Math.min((now - lastProgress) / 1000, MAX_SECS));
                abandoned = abandonSent = true;
                gonePass = pass;
            }
        }
        for (String req : new String[] { ended, stall, gone }) {
            if (req == null) continue;
            try { sink.send(req); } catch (Throwable ignore) {}
        }
        if (gone != null) {
            synchronized (SweepStall.class) {
                if (pass == gonePass) try { sink.abandon(); } catch (Throwable ignore) {}
            }
        }
    }
}
