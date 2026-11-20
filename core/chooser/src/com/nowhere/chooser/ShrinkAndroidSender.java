package com.nowhere.chooser;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.UserHandle;
import android.util.Log;
import java.util.LinkedHashSet;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * NWP-20261210-01 (decision 2026-11-05 h59 #5): tells the agent which packages Android cleared or uninstalled in this
 * session, through EXPECT-SHRINK-ANDROID, so the seal guard can allow the shrink that follows. AppInstallReceiver
 * calls onBroadcast for every package broadcast; ShrinkAndroidArm decides which ones arm.
 *
 * The send runs on this class's OWN single daemon thread, never on AppInstallReceiver's WORKER: the verb is in the
 * agent's TryLock set and the read can wait 90 s, and the install path must not wait behind it. All queue and retry
 * state is touched only on that thread. A reply other than OK or NONE (BUSY while a long op holds the session lock,
 * ERR, or no reply) keeps the names queued and schedules one retry; a new event resets the retry count.
 * The queue lives in process memory only: a chooser process that dies loses it, and a runtime receiver sees nothing
 * while its process is dead. The log line carries counts and a fixed reply class only, never a package name.
 */
final class ShrinkAndroidSender {
    private static final String TAG = "NowhereChooser";
    private static final ScheduledExecutorService EXECUTOR = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread thread = new Thread(r, "nowhere-shrink-android");
        thread.setDaemon(true);
        return thread;
    });
    /** Names not yet acknowledged, in arrival order; bounded at MAX_PKGS, the oldest kept. EXECUTOR thread only. */
    private static final LinkedHashSet<String> QUEUED = new LinkedHashSet<>();
    private static int attempts;
    private static ScheduledFuture<?> retry;

    private ShrinkAndroidSender() {}

    static void onBroadcast(Context context, Intent intent) {
        String action = intent.getAction();
        Uri data = intent.getData();
        String pkg = data == null ? null : data.getSchemeSpecificPart();
        boolean replacing = intent.getBooleanExtra(Intent.EXTRA_REPLACING, false);
        boolean archival = false;
        try {
            archival = intent.getBooleanExtra("android.intent.extra.ARCHIVAL", false); // API 35+, read by name
        } catch (Throwable ignore) {}
        Boolean dataRemoved = intent.hasExtra(Intent.EXTRA_DATA_REMOVED)
                ? intent.getBooleanExtra(Intent.EXTRA_DATA_REMOVED, false) : null;
        final String armed = ShrinkAndroidArm.armed(action, pkg, context.getPackageName(), UserHandle.myUserId(),
                replacing, archival, dataRemoved);
        if (armed == null) return;
        EXECUTOR.execute(() -> {
            cancelRetry();
            attempts = 0;
            if (QUEUED.size() < ShrinkAndroidArm.MAX_PKGS) QUEUED.add(armed);
            send();
        });
    }

    /** EXECUTOR thread only. */
    private static void send() {
        String payload = ShrinkAndroidArm.payload(QUEUED);
        if (payload == null) return;
        int n = QUEUED.size();
        String reply;
        try {
            reply = DaemonSocket.roundTrip(payload, 90000);
        } catch (Throwable t) {
            reply = "";
        }
        String replyClass = replyClass(reply);
        Log.i(TAG, "shrink-android: " + n + " package(s) sent, reply " + replyClass + " (NWP-20261210-01)");
        if ("OK".equals(replyClass) || "NONE".equals(replyClass)) {
            QUEUED.clear();
            cancelRetry();
            attempts = 0;
            return;
        }
        scheduleRetry();
    }

    /** The fixed reply class the log may print: OK, NONE, ERR, BUSY, or none (no reply). Never the raw reply. */
    private static String replyClass(String reply) {
        if ("OK".equals(reply) || "NONE".equals(reply) || "ERR".equals(reply) || "BUSY".equals(reply)) return reply;
        return reply == null || reply.isEmpty() ? "none" : "ERR";
    }

    /** At most one retry pending. EXECUTOR thread only. */
    private static void scheduleRetry() {
        if (retry != null && !retry.isDone()) return;
        long delay = ShrinkAndroidArm.retryDelayMs(++attempts);
        if (delay < 0) return;
        retry = EXECUTOR.schedule(() -> {
            retry = null;
            send();
        }, delay, TimeUnit.MILLISECONDS);
    }

    private static void cancelRetry() {
        if (retry != null) retry.cancel(false);
        retry = null;
    }
}
