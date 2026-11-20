package com.nowhere.chooser;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.ContextWrapper;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.view.Choreographer;
import android.view.InputEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.TextView;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * NWP-20261208-08: evidence for the backlog row "After a sign-out the gate can stop taking touches: Android shows
 * "Profile isn't responding" over the sign-in screen, "Wait" does not bring it back, and only "Close app" (a gate
 * restart) does".
 *
 * <p>WHY THIS CLASS EXISTS. The row's ANR trace shows the gate's main thread idle in Looper.loop and dumpsys input
 * lists its channel responsive, so the touch waits somewhere the main thread does not drain. This probe, in the
 * user-0 gate process only, samples the process's own windows once a second while the screen is on. On an input or
 * frame stall over 5 s it sends one block of fixed codes to gate.log over GATE-TRACE: where the event waits (a
 * window's pending queue, a held batch, an input stage such as the IME's, a late frame, a late main thread, or none
 * of these while the system marks this process not responding), which window, its ViewRootImpl input flags, focus,
 * IME and Lock Task. gate.log is in every issue report, gate and session.
 *
 * <p>⚠ EVERY VALUE IS AN INTEGER CODE FROM {@link Rule}. No window title, view text, class name, package or profile
 * reaches the wire; the daemon's closed grammar (gate_log.go) refuses anything else. The window kind is an
 * instanceof test, never a title. From the system's error-state list only the pid and the condition are read: the
 * rest of an entry names the Activity.
 *
 * <p>Not read here: InputDispatcher's wait queue (dumpsys input). The chooser's domain cannot reach it.
 */
final class GateInputProbe {
    private GateInputProbe() {}

    /** Pure: java.lang only, so test-gate-input-probe-java.sh compiles it off the build host. */
    static final class Rule {
        private Rule() {}

        static final long STALL_MS = 5000L;
        static final long TICK_MS = 1000L;
        static final int MAX_BLOCKS = 4;
        static final String[] VERBS = {"input-stall", "input-stall-why", "input-stall-win", "input-stall-vri",
                "input-stall-focus", "input-stall-ime", "input-stall-stage", "input-stall-clear"};

        /**
         * The stall's cause, first match in this order: 1 an event pending in a window's queue, 2 a batch scheduled
         * and not consumed, 5 an event deferred in an input stage (the IME path), 3 a late frame while interactive,
         * 4 the main thread late, 6 the system marks this process not responding. 0 none. An age below 0 is unknown
         * and never matches. Cause 6 is the row's case: the main thread idle and no Java queue holding the event.
         */
        static int why(long pendingAgeMs, long batchHeldMs, long stageAgeMs, long frameLateMs,
                       boolean interactive, long mainLateMs, boolean anrFlagged) {
            if (pendingAgeMs > STALL_MS) return 1;
            if (batchHeldMs > STALL_MS) return 2;
            if (stageAgeMs > STALL_MS) return 5;
            if (interactive && frameLateMs > STALL_MS) return 3;
            if (mainLateMs > STALL_MS) return 4;
            if (anrFlagged) return 6;
            return 0;
        }

        private static int digit(int v) { return Math.min(Math.max(0, v), 9); }

        /** Tens: events deferred (max 9). Units: stage 1 NativePreIme, 2 Ime, 3 NativePostIme, 4 other, 9 unread. */
        static int stageCode(int deferred, int stage) { return digit(deferred) * 10 + digit(stage); }

        /** Whole seconds in milliseconds, capped at 600000, never below 0. */
        static int secMs(long ms) {
            if (ms <= 0) return 0;
            long c = Math.min(ms, 600_000L);
            return (int) (c / 1000L * 1000L);
        }

        /** Hundreds: roots (max 9). Tens: kind 1 gate, 2 other Activity, 3 dialog, 4 sub-window, 5 other. Units: pending (max 9). */
        static int winCode(int roots, int kind, int pending) { return digit(roots) * 100 + digit(kind) * 10 + digit(pending); }

        static int vriFlags(boolean stopped, boolean pausedForTransition, boolean noReceiver, boolean notAdded,
                            boolean processScheduled, boolean batchScheduled, boolean batchImmediateScheduled,
                            boolean unread) {
            return (stopped ? 1 : 0) | (pausedForTransition ? 2 : 0) | (noReceiver ? 4 : 0) | (notAdded ? 8 : 0)
                    | (processScheduled ? 16 : 0) | (batchScheduled ? 32 : 0) | (batchImmediateScheduled ? 64 : 0)
                    | (unread ? 128 : 0);
        }

        /** Hundreds: window focus. Tens: view 0 none, 1 EditText, 2 TextView, 3 clickable, 4 other. Units: Lock Task (9 unread). */
        static int focusCode(int hasFocus, int view, int lockTask) { return digit(hasFocus) * 100 + digit(view) * 10 + digit(lockTask); }

        static int imeCode(boolean active, boolean acceptingText, boolean pendingEvents, boolean unread) {
            return (active ? 1 : 0) | (acceptingText ? 2 : 0) | (pendingEvents ? 4 : 0) | (unread ? 8 : 0);
        }

        static boolean shouldWrite(boolean stalled, boolean inEpisode, int written) {
            return stalled && !inEpisode && written < MAX_BLOCKS;
        }

        /**
         * A completed read is one this tick can judge recovery from: the read posted on the last tick has run and left
         * a snapshot. While a read is outstanding, or none has run since the screen came on, every window age is
         * unknown, so a cause of 0 then says nothing about the held event.
         */
        static boolean observed(boolean runOutstanding, boolean haveSnap) {
            return !runOutstanding && haveSnap;
        }

        /** An episode ends only when a completed read finds no stall. An unknown sample keeps it open. */
        static boolean shouldClear(boolean inEpisode, int cause, boolean observed) {
            return inEpisode && cause == 0 && observed;
        }

        /** A window age read on the main thread is unknown only while the read posted on an earlier tick has not run. */
        static long tickAge(boolean runOutstanding, long snapAgeMs) {
            return runOutstanding ? -1L : snapAgeMs;
        }

        static long mainLate(boolean runOutstanding, long postedAtMs, long nowMs) {
            return runOutstanding ? Math.max(0L, nowMs - postedAtMs) : 0L;
        }

        /** The largest age that is 0 or more, over all roots; -1 when there is none. */
        static long maxAge(long[] ages) {
            long m = -1L;
            if (ages == null) return m;
            for (long a : ages) if (a > m) m = a;
            return m;
        }

        private static long at(long[] a, int i) { return a != null && i < a.length ? a[i] : -1L; }

        /**
         * The root that holds the oldest event, pending or stage-deferred alike (ties to the lower index); else the
         * root with the longest held batch; else the gate window; else root 0. -1 when there are no roots.
         */
        static int worstRoot(long[] pendingAge, long[] stageAge, long[] batchHeld, int gateIdx) {
            int n = pendingAge == null ? 0 : pendingAge.length;
            if (n == 0) return -1;
            int best = -1;
            long bestAge = -1L;
            for (int i = 0; i < n; i++) {
                long ev = Math.max(pendingAge[i], at(stageAge, i));
                if (ev > bestAge) { best = i; bestAge = ev; }
            }
            if (best >= 0) return best;
            for (int i = 0; i < n; i++) {
                long b = at(batchHeld, i);
                if (b > bestAge) { best = i; bestAge = b; }
            }
            if (best >= 0) return best;
            return gateIdx >= 0 && gateIdx < n ? gateIdx : 0;
        }
    }

    /** One main-thread read. Numbers only: no reference to a view, a window or a string. Ages are at takenAt. */
    private static final class Snap {
        static final Snap EMPTY = new Snap(0L, 0);
        final long takenAt;
        final int roots;
        final int[] kind, pending, stageDeferred, stageKind, vri, hasFocus, focusView;
        final long[] pendingAge, stageAge, batchHeld;
        int gateIdx = -1;
        long frameLate = -1L;

        Snap(long takenAt, int roots) {
            this.takenAt = takenAt;
            this.roots = roots;
            kind = new int[roots]; pending = new int[roots]; stageDeferred = new int[roots]; stageKind = new int[roots];
            vri = new int[roots]; hasFocus = new int[roots]; focusView = new int[roots];
            pendingAge = new long[roots]; stageAge = new long[roots]; batchHeld = new long[roots];
        }
    }

    private static final AtomicBoolean STARTED = new AtomicBoolean(false);
    // Shared by the probe thread and the main thread.
    private static volatile long postedAt;
    private static volatile Snap lastSnap;
    // Main thread only.
    private static long[] batchSince = new long[0];
    private static int[] batchId = new int[0];
    private static long framePostedAt;
    private static final Choreographer.FrameCallback FRAME = t -> framePostedAt = 0L;
    // Probe thread only.
    private static boolean inEpisode;
    private static int written;
    private static long episodeStart;
    private static long anrSince = -1L;

    static void start(Context ctx) {
        if (android.os.UserHandle.myUserId() != 0) return;
        if (!STARTED.compareAndSet(false, true)) return;
        final Context app = ctx.getApplicationContext() != null ? ctx.getApplicationContext() : ctx;
        final Handler main = new Handler(Looper.getMainLooper());
        final Runnable read = () -> {
            try {
                lastSnap = readWindows();
            } finally { postedAt = 0; }
        };
        Thread t = new Thread(() -> {
            while (true) {
                try {
                    tick(app, main, read);
                } catch (Throwable ignore) {
                    // One bad tick must not end the probe.
                }
                try {
                    Thread.sleep(Rule.TICK_MS);
                } catch (InterruptedException e) {
                    return;
                }
            }
        }, "nowhere-input-probe");
        t.setDaemon(true);
        t.start();
    }

    // One tick, in this order: read what the last main-thread run left, decide, write, and post the next read LAST.
    // Posting first would leave every window age unknown on an idle main thread, so only cause 6 could fire.
    private static void tick(Context app, Handler main, Runnable read) {
        long now = SystemClock.uptimeMillis();
        PowerManager pm = app.getSystemService(PowerManager.class);
        boolean interactive = pm != null && pm.isInteractive();
        if (!interactive) {
            lastSnap = null; // a read from before the screen went off is not evidence about now
            return;
        }
        boolean anr = false;
        try {
            ActivityManager am = app.getSystemService(ActivityManager.class);
            List<ActivityManager.ProcessErrorStateInfo> errs = am.getProcessesInErrorState();
            if (errs != null) {
                for (ActivityManager.ProcessErrorStateInfo e : errs) {
                    if (e.pid == android.os.Process.myPid() && e.condition == android.app.ActivityManager.ProcessErrorStateInfo.NOT_RESPONDING) anr = true;
                }
            }
        } catch (Throwable ignore) {
            // unread: not flagged
        }
        if (!anr) anrSince = -1L;
        else if (anrSince < 0) anrSince = now;

        long p = postedAt;
        Snap s = lastSnap;
        boolean out = p != 0;
        boolean observed = Rule.observed(out, s != null);
        if (s == null) s = Snap.EMPTY;
        long mainLateMs = Rule.mainLate(out, p, now);
        long pendingAgeMs = Rule.tickAge(out, Rule.maxAge(s.pendingAge));
        long batchHeldMs = Rule.tickAge(out, Rule.maxAge(s.batchHeld));
        long stageAgeMs = Rule.tickAge(out, Rule.maxAge(s.stageAge));
        long frameLateMs = Rule.tickAge(out, s.frameLate);
        int cause = Rule.why(pendingAgeMs, batchHeldMs, stageAgeMs, frameLateMs, interactive, mainLateMs, anr);

        if (Rule.shouldWrite(cause != 0, inEpisode, written)) {
            long age;
            switch (cause) {
                case 1: age = pendingAgeMs; break;
                case 2: age = batchHeldMs; break;
                case 5: age = stageAgeMs; break;
                case 3: age = frameLateMs; break;
                case 4: age = mainLateMs; break;
                default: age = now - anrSince; break;
            }
            GateTrace.ev("input-stall", "ms", Rule.secMs(age));
            GateTrace.ev("input-stall-why", "fields", cause);
            // A late main thread has no fresh window state: the read that would have taken it has not run.
            if (cause != 4) {
                int lockTask = lockTask(app);
                int w = Rule.worstRoot(s.pendingAge, s.stageAge, s.batchHeld, s.gateIdx);
                int win, vri, focus, stage;
                if (w < 0) {
                    win = Rule.winCode(0, 5, 0);
                    vri = 128;
                    focus = Rule.focusCode(0, 0, lockTask);
                    stage = Rule.stageCode(0, 9);
                } else {
                    win = Rule.winCode(s.roots, s.kind[w], s.pending[w]);
                    vri = s.vri[w];
                    focus = Rule.focusCode(s.hasFocus[w], s.focusView[w], lockTask);
                    stage = Rule.stageCode(s.stageDeferred[w], s.stageKind[w]);
                }
                GateTrace.ev("input-stall-win", "fields", win);
                GateTrace.ev("input-stall-vri", "fields", vri);
                GateTrace.ev("input-stall-focus", "fields", focus);
                GateTrace.ev("input-stall-ime", "fields", ime(app));
                GateTrace.ev("input-stall-stage", "fields", stage);
            }
            inEpisode = true;
            written++;
            episodeStart = now - Math.max(0L, age);
        } else if (Rule.shouldClear(inEpisode, cause, observed)) {
            GateTrace.ev("input-stall-clear", "ms", Rule.secMs(now - episodeStart));
            inEpisode = false;
        }

        if (!out) {
            postedAt = now;
            if (!main.post(read)) postedAt = 0;
        }
    }

    private static int lockTask(Context app) {
        try {
            return app.getSystemService(ActivityManager.class).getLockTaskModeState();
        } catch (Throwable t) {
            return 9;
        }
    }

    private static int ime(Context app) {
        boolean active = false, accepting = false, pendingEvents = false, unread = false;
        InputMethodManager imm = null;
        try {
            imm = app.getSystemService(InputMethodManager.class);
        } catch (Throwable t) {
            unread = true;
        }
        if (imm == null) return Rule.imeCode(false, false, false, true);
        try {
            active = imm.isActive();
        } catch (Throwable t) {
            unread = true;
        }
        try {
            accepting = imm.isAcceptingText();
        } catch (Throwable t) {
            unread = true;
        }
        try {
            Object q = field(imm, "mPendingEvents");
            pendingEvents = q != null && ((Integer) q.getClass().getMethod("size").invoke(q)) > 0;
        } catch (Throwable t) {
            unread = true;
        }
        return Rule.imeCode(active, accepting, pendingEvents, unread);
    }

    private static Object field(Object o, String name) throws Exception {
        for (Class<?> c = o.getClass(); c != null; c = c.getSuperclass()) {
            try {
                Field f = c.getDeclaredField(name);
                f.setAccessible(true);
                return f.get(o);
            } catch (NoSuchFieldException next) {
                // look in the superclass
            }
        }
        throw new NoSuchFieldException();
    }

    private static boolean has(Object o, String name) {
        for (Class<?> c = o.getClass(); c != null; c = c.getSuperclass()) {
            try {
                c.getDeclaredField(name);
                return true;
            } catch (NoSuchFieldException next) {
                // look in the superclass
            }
        }
        return false;
    }

    private static boolean flag(Object o, String name, boolean[] unread) {
        try {
            return (Boolean) field(o, name);
        } catch (Throwable t) {
            unread[0] = true;
            return false;
        }
    }

    private static Class<?> cls(String name) {
        try {
            return Class.forName(name);
        } catch (Throwable t) {
            return null;
        }
    }

    // On the main thread only: every ViewRootImpl field is read on the thread that owns it.
    private static Snap readWindows() {
        long takenAt = SystemClock.uptimeMillis();
        List<Object> roots = new ArrayList<>();
        List<Object> params = new ArrayList<>();
        try {
            Object wmg = Class.forName("android.view.WindowManagerGlobal").getMethod("getInstance").invoke(null);
            Object lock = null;
            try {
                lock = field(wmg, "mLock");
            } catch (Throwable ignore) {
                // copy without the lock
            }
            if (lock != null) {
                synchronized (lock) {
                    roots.addAll((List<?>) field(wmg, "mRoots"));
                    params.addAll((List<?>) field(wmg, "mParams"));
                }
            } else {
                roots.addAll((List<?>) field(wmg, "mRoots"));
                params.addAll((List<?>) field(wmg, "mParams"));
            }
        } catch (Throwable t) {
            roots.clear();
            params.clear();
        }
        int n = roots.size();
        Snap s = new Snap(takenAt, n);
        if (batchSince.length != n) {
            long[] bs = new long[n];
            int[] bi = new int[n];
            for (int i = 0; i < n; i++) {
                bs[i] = i < batchSince.length ? batchSince[i] : -1L;
                bi[i] = i < batchId.length ? batchId[i] : 0;
            }
            batchSince = bs;
            batchId = bi;
        }
        Class<?> preIme = cls("android.view.ViewRootImpl$NativePreImeInputStage");
        Class<?> imeStage = cls("android.view.ViewRootImpl$ImeInputStage");
        Class<?> postIme = cls("android.view.ViewRootImpl$NativePostImeInputStage");
        boolean anyShown = false;
        for (int i = 0; i < n; i++) {
            Object r = roots.get(i);
            boolean[] unread = {false};
            s.pendingAge[i] = -1L;
            s.stageAge[i] = -1L;
            s.batchHeld[i] = -1L;
            try {
                s.pending[i] = (Integer) field(r, "mPendingInputEventCount");
            } catch (Throwable t) {
                unread[0] = true;
            }
            try {
                Object head = field(r, "mPendingInputEventHead");
                if (head != null) s.pendingAge[i] = takenAt - ((InputEvent) field(head, "mEvent")).getEventTime();
            } catch (Throwable t) {
                unread[0] = true;
            }
            boolean noReceiver = false, notAdded = false;
            try {
                noReceiver = field(r, "mInputEventReceiver") == null;
            } catch (Throwable t) {
                unread[0] = true;
            }
            try {
                notAdded = !((Boolean) field(r, "mAdded"));
            } catch (Throwable t) {
                unread[0] = true;
            }
            boolean stopped = flag(r, "mStopped", unread);
            boolean paused = flag(r, "mPausedForTransition", unread);
            boolean process = flag(r, "mProcessInputEventsScheduled", unread);
            boolean[] batchUnread = {false};
            boolean batch = flag(r, "mConsumeBatchedInputScheduled", batchUnread);
            boolean batchNow = flag(r, "mConsumeBatchedInputImmediatelyScheduled", unread);
            s.vri[i] = Rule.vriFlags(stopped, paused, noReceiver, notAdded, process, batch, batchNow, unread[0] || batchUnread[0]);

            // The batch hold, tracked per root by its index in mRoots; a different root at that index starts over.
            int id = System.identityHashCode(r);
            if (batchId[i] != id) {
                batchId[i] = id;
                batchSince[i] = -1L;
            }
            if (batch && !batchUnread[0]) {
                if (batchSince[i] < 0) batchSince[i] = takenAt;
                s.batchHeld[i] = takenAt - batchSince[i];
            } else {
                batchSince[i] = -1L;
            }

            // The input stages: an async stage (the IME's) holds an event that mPendingInputEventCount does not count.
            try {
                int firstAsync = 0;
                Object st = field(r, "mFirstInputStage");
                for (int guard = 0; st != null && guard < 16; guard++) {
                    if (has(st, "mQueueLength")) {
                        Class<?> c = st.getClass();
                        int k = c == preIme ? 1 : c == imeStage ? 2 : c == postIme ? 3 : 4;
                        if (firstAsync == 0) firstAsync = k;
                        int len = (Integer) field(st, "mQueueLength");
                        Object qh = field(st, "mQueueHead");
                        if (qh != null && len > 0) {
                            long age = takenAt - ((InputEvent) field(qh, "mEvent")).getEventTime();
                            if (age > s.stageAge[i]) {
                                s.stageAge[i] = age;
                                s.stageDeferred[i] = len;
                                s.stageKind[i] = k;
                            }
                        }
                    }
                    st = field(st, "mNext");
                }
                if (s.stageAge[i] < 0) {
                    s.stageDeferred[i] = 0;
                    s.stageKind[i] = firstAsync == 0 ? 4 : firstAsync;
                }
            } catch (Throwable t) {
                s.stageAge[i] = -1L;
                s.stageDeferred[i] = 0;
                s.stageKind[i] = 9;
            }

            View v = null;
            try {
                v = (View) field(r, "mView");
            } catch (Throwable ignore) {
                // no root view: no focus, kind from the type alone
            }
            if (v != null) {
                try {
                    if (v.getWindowVisibility() == View.VISIBLE) anyShown = true;
                } catch (Throwable ignore) {
                    // not shown
                }
                try {
                    s.hasFocus[i] = v.hasWindowFocus() ? 1 : 0;
                } catch (Throwable ignore) {
                    // no focus
                }
                try {
                    View f = v.findFocus();
                    s.focusView[i] = f == null ? 0 : f instanceof EditText ? 1 : f instanceof TextView ? 2 : f.isClickable() ? 3 : 4;
                } catch (Throwable ignore) {
                    // none
                }
            }
            int k = 5;
            try {
                int type = ((WindowManager.LayoutParams) params.get(i)).type;
                if (type == WindowManager.LayoutParams.TYPE_BASE_APPLICATION) {
                    Context c = v == null ? null : v.getContext();
                    while (c instanceof ContextWrapper && !(c instanceof Activity)) c = ((ContextWrapper) c).getBaseContext();
                    if (c instanceof ChooserActivity) k = 1;
                    else if (c instanceof Activity) k = 2;
                } else if (type == WindowManager.LayoutParams.TYPE_APPLICATION) {
                    k = 3;
                } else if (type >= 1000 && type <= 1999) {
                    k = 4;
                }
            } catch (Throwable ignore) {
                // other
            }
            s.kind[i] = k;
            if (k == 1 && s.gateIdx < 0) s.gateIdx = i;
        }

        // One frame callback outstanding. No window shown (a session in front): no frame is due, so not a stall.
        try {
            if (!anyShown) {
                Choreographer.getInstance().removeFrameCallback(FRAME);
                framePostedAt = 0L;
                s.frameLate = -1L;
            } else if (framePostedAt != 0L) {
                s.frameLate = takenAt - framePostedAt;
            } else {
                s.frameLate = 0L;
                framePostedAt = takenAt;
                Choreographer.getInstance().postFrameCallback(FRAME);
            }
        } catch (Throwable t) {
            s.frameLate = -1L;
        }
        return s;
    }
}
