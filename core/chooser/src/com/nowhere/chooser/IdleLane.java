package com.nowhere.chooser;

/** NWP-20261114-04: ONE serial lane for the idle watcher's binder calls (the max-time-to-lock set and clear, the alarm
 *  cancel, the receiver unregisters). Tasks run in the order they were posted, so armIdleWatcher's set lands after its
 *  own teardown's clear, never before it. Every task runs inside its own catch: an uncaught Throwable on Android kills
 *  the process, and this is the persistent device-owner HOME process. java.* only, so a javac suite runs it unchanged. */
final class IdleLane {
    private static IdleLane sLane;
    private final java.util.concurrent.ExecutorService exec;

    IdleLane() {
        exec = java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "nowhere-idle-binder");
            t.setDaemon(true);
            return t;
        });
    }

    /** Runs r on the lane, after every task posted before it. */
    static void post(Runnable r) { lane().run(r); }

    private static synchronized IdleLane lane() {
        if (sLane == null) sLane = new IdleLane();
        return sLane;
    }

    void run(final Runnable r) {
        exec.execute(() -> {
            try { r.run(); }
            catch (Throwable t) { System.err.println("nowhere-idle-binder: task threw " + t); }
        });
    }
}
