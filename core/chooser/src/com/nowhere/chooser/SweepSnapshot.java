package com.nowhere.chooser;

/** NWP-20261203-07 (backlog: "P1: An Auto sweep stalls after its first fetch and no app installs for the rest of the
 *  session ..."): the report's view of the Auto sweep. The chooser's own lines are in logcat only, and a report does
 *  not carry logcat, so a stalled sweep's report named nothing. reportStatus puts four keys from this class: the state
 *  line (sweep_state), the frames of the sweep thread (sweep_stack) and of a tap that holds the materialise lane
 *  (lane_stack), and chooser_up_s.
 *
 *  Counts, Thread.State names, fixed words and frames only. A frame whose class is not a platform or chooser class is
 *  written `?`, so an app's own class (a callback into it, a lambda in its package) is never sent. A thread's name is
 *  never read: a name can hold a package. The pass age is `age_s=`, not `pass_s=`: the agent's report scrub
 *  (report_issue.go reIssueKV) drops the value after any key that holds `pass`, so `pass_s=37` arrives redacted.
 *  java.lang only, so test-sweep-snapshot-java.sh runs it under plain javac. */
final class SweepSnapshot {
    private SweepSnapshot() {}

    static final int MAX_FRAMES = 12;
    static final int MAX_CHARS = 1500;

    /** The class prefixes whose frames are sent. Every other class is `?`. */
    private static final String[] SHARED = {
        "android.", "com.android.", "java.", "javax.", "dalvik.", "libcore.", "sun.", "jdk.", "com.nowhere.chooser.",
    };

    /** One read of UnarchiveService's sweep state (UnarchiveService.snapshot). */
    static final class Input {
        final Thread sweep;     // the sweep thread, null when no sweep runs
        final long since;       // elapsedRealtime at the start of its current pass
        final Thread laneOwner; // the thread that holds MAT_LOCK, null when free
        final int laneQueue;    // threads waiting for MAT_LOCK
        final int taps;         // LIVE_TAPS.size()
        final int queue;        // Q_PENDING.size()
        final int workers;      // ACTIVE.get()

        Input(Thread sweep, long since, Thread laneOwner, int laneQueue, int taps, int queue, int workers) {
            this.sweep = sweep;
            this.since = since;
            this.laneOwner = laneOwner;
            this.laneQueue = laneQueue;
            this.taps = taps;
            this.queue = queue;
            this.workers = workers;
        }
    }

    /** The thread other than the sweep that holds the materialise lane (a tap worker), else null. One rule for the
     *  state line's `lane=tap` and for the lane_stack key. */
    static Thread tapHolder(Input in) {
        if (in == null || in.laneOwner == null || in.laneOwner == in.sweep) return null;
        return in.laneOwner;
    }

    /** `idle`, or `running age_s=<s> thread=<state> lane=<sweep|tap|free> lane_queue=<n> taps=<n> queue=<n>
     *  workers=<n>`. */
    static String state(Input in, long nowMs) {
        if (in == null || in.sweep == null) return "idle";
        String lane = in.laneOwner == null ? "free" : tapHolder(in) != null ? "tap" : "sweep";
        long age = Math.max(0L, (nowMs - in.since) / 1000L);
        return "running age_s=" + age
                + " thread=" + in.sweep.getState().name()
                + " lane=" + lane
                + " lane_queue=" + in.laneQueue
                + " taps=" + in.taps
                + " queue=" + in.queue
                + " workers=" + in.workers;
    }

    /** The top MAX_FRAMES frames, `<class>.<method>:<line>` joined by ` < `, a class outside SHARED as `?`, cut to
     *  MAX_CHARS. The frame's file name is never written. */
    static String frames(StackTraceElement[] st) {
        if (st == null || st.length == 0) return "";
        StringBuilder b = new StringBuilder();
        int n = Math.min(st.length, MAX_FRAMES);
        for (int i = 0; i < n; i++) {
            if (i > 0) b.append(" < ");
            StackTraceElement e = st[i];
            if (e != null && shared(e.getClassName())) {
                b.append(e.getClassName()).append('.').append(e.getMethodName()).append(':').append(e.getLineNumber());
            } else {
                b.append('?');
            }
        }
        return b.length() > MAX_CHARS ? b.substring(0, MAX_CHARS) : b.toString();
    }

    private static boolean shared(String cls) {
        if (cls == null) return false;
        for (String p : SHARED) if (cls.startsWith(p)) return true;
        return false;
    }
}
