package com.nowhere.chooser;

import android.app.Notification;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import java.util.Locale;

/**
 * task_c272758a (force-ours): in a roamed session the amnesiac phone delivers every SMS/MMS by INJECTING it
 * into the user's own provider -- the SIM stays on the gate and is never natively delivered here (#148/#149).
 * The default messaging app (Bugle) nonetheless observes the provider insert and raises its OWN conversation
 * notification for a live-arriving row, which DUPLICATES the single nowhere notice TelIngest posts (and, unlike
 * ours, does not reliably clear on read in a secondary user). Since EVERY Bugle message notification in a roamed
 * session is such a duplicate, this listener cancels them -- leaving OUR notice as the one, consistent,
 * clear-on-read ping (Chester's ask). Marking the row seen=1 does NOT stop Bugle (it notifies off the insert's
 * fresh timestamp, not the seen column), so cancelling the posted notice is the reliable lever.
 *
 * NWP-20261010-13: it is also what clears OUR notice once its message is read (TelIngest.clearReadNotices), because
 * it is the component of ours that is bound for as long as its user is in use: the framework binds a granted
 * listener while its user is the CURRENT (foreground) user, unbinds it when that user goes to the background (a
 * cold lock switches to the gate), and binds it again -- and rebinds it after its process dies -- when the user
 * is current again. Each connect sweeps, so a read that landed while it was unbound is caught then. The read-watch
 * it replaces ran in the delivery worker and gave up after 3 minutes, so a text read later kept its notice. A
 * JobScheduler content-URI trigger was the other host considered; it would need a new manifest component (which a
 * pinned-fingerprint reflash does not register without a data wipe, the B4 lesson) and re-scheduling after every
 * run, for no gain over a binding that already exists. For the same reason it hosts the capture of the profile's SMS
 * app (Chester, 2026-10-11): a role listener records every change of the SMS role holder (SmsRoleRoam.capture).
 *
 * Enabled per roamed user at login by TelIngest.ensureNotificationListener, through
 * NotificationManager.setNotificationListenerAccessGranted -- a plain enabled_notification_listeners write does not
 * bind it. Granted before TelIngest posts its first notice in a run, so there is no notice the clear can miss.
 * The gate (user 0) never runs a roamed session's Bugle and posts no message notice of TelIngest's, so it is inert there.
 */
public final class MessagingSuppressor extends NotificationListenerService {
    private static final String BUGLE = "com.android.messaging";

    // NWP-20261010-13: the read clear's thread, observer and sweep -- set while the listener is connected, else null.
    // Every sweep runs on this one thread, so two never overlap. Guarded by `this`.
    private android.os.HandlerThread clearThread;
    private android.os.Handler clearHandler;
    private android.database.ContentObserver clearObserver;
    private final Runnable sweep = this::sweepReadNotices;
    private long sweepPendingSince; // when the waiting event sweep was first asked for (0 = none waiting)
    private boolean sweepForEvent;  // the waiting sweep answers an event (a change, a notice, a connect)
    private int idleResweeps;       // re-sweeps in a row that cleared nothing, since the last event
    // NWP-20261010-13: the SMS role listener that captures the profile's SMS app (SmsRoleRoam.capture).
    private android.app.role.OnRoleHoldersChangedListener roleListener;

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        cancelIfBugleMessage(sbn);
        // NWP-20261010-13: our own message notice just went up -> sweep, which starts the re-sweep while it is unread.
        if (sbn != null && getPackageName().equals(sbn.getPackageName()) && TelIngest.noticeRow(sbn.getTag()) != null) {
            scheduleEventSweep();
        }
    }

    // NWP-20261118-16: one of our message notices went (a tap, a swipe, or a cancel of ours) -> re-sync the message
    // group's summary, so a summary left with no notice goes. The summary's own removal does not come back here: its
    // tag names no row (MessageGroup.SUMMARY_TAG).
    @Override public void onNotificationRemoved(StatusBarNotification sbn) {
        if (sbn != null && getPackageName().equals(sbn.getPackageName()) && TelIngest.noticeRow(sbn.getTag()) != null) {
            TelIngest.syncMessageSummary(this);
        }
    }

    @Override public void onListenerConnected() {
        // We may enable the listener just AFTER the first live row inserted (Bugle already posted) -- clear any
        // Bugle message notice already showing when we bind.
        try {
            StatusBarNotification[] active = getActiveNotifications();
            if (active != null) for (StatusBarNotification sbn : active) cancelIfBugleMessage(sbn);
        } catch (Throwable ignore) {}
        startReadClear();
        startRoleCapture();
    }

    @Override public void onListenerDisconnected() {
        stopRoleCapture();
        stopReadClear();
    }

    @Override public void onDestroy() {
        stopRoleCapture();
        stopReadClear();
        super.onDestroy();
    }

    /** NWP-20261010-13: capture the profile's SMS app (SmsRoleRoam) whenever the SMS role changes in this user, and once
     *  now -- a change made while this listener was unbound (its process died) is caught at the reconnect. Runs on the
     *  read clear's thread, off the main thread. OBSERVE_ROLE_HOLDERS is a signature permission (AndroidManifest.xml);
     *  if the listener cannot be added, the connect-time capture still runs at every rebind. */
    private synchronized void startRoleCapture() {
        stopRoleCapture();
        final android.os.Handler h = clearHandler;
        if (h == null) return;
        h.post(() -> SmsRoleRoam.capture(this));
        h.post(() -> { for (String r : DefaultRoles.ROLES) DefaultRoleRoam.capture(this, r); }); // NWP-20261202-05
        try {
            roleListener = (roleName, user) -> {
                if (android.app.role.RoleManager.ROLE_SMS.equals(roleName)) h.post(() -> SmsRoleRoam.capture(this));
                if (DefaultRoles.isRole(roleName)) h.post(() -> DefaultRoleRoam.capture(this, roleName));
            };
            getSystemService(android.app.role.RoleManager.class).addOnRoleHoldersChangedListenerAsUser(
                    h::post, roleListener, android.os.Process.myUserHandle());
        } catch (Throwable t) {
            roleListener = null;
            android.util.Log.w("NowhereChooser", "NWP-20261010-13 sms role listener", t);
        }
    }

    private synchronized void stopRoleCapture() {
        if (roleListener == null) return;
        try {
            getSystemService(android.app.role.RoleManager.class).removeOnRoleHoldersChangedListenerAsUser(
                    roleListener, android.os.Process.myUserHandle());
        } catch (Throwable ignore) {}
        roleListener = null;
    }

    /** Cancel a Bugle conversation/message notification (the duplicate of our injected-SMS notice). Scoped to
     *  message notices (category MESSAGE, or a "conversation" channel) so a non-message Bugle notice is untouched. */
    private void cancelIfBugleMessage(StatusBarNotification sbn) {
        try {
            if (sbn == null || !BUGLE.equals(sbn.getPackageName())) return;
            Notification n = sbn.getNotification();
            if (n == null) return;
            String ch = n.getChannelId();
            boolean isMessage = Notification.CATEGORY_MESSAGE.equals(n.category)
                    || (ch != null && ch.toLowerCase(Locale.ROOT).contains("conversation"));
            if (isMessage) cancelNotification(sbn.getKey());
        } catch (Throwable ignore) {}
    }

    /** NWP-20261010-13: start clearing read notices for as long as the listener is connected: a sweep now (a text may
     *  have been read while it was unbound), then one after every change to the message providers. All three
     *  authorities are observed because a read can land on any of them: Messaging marks a conversation read through
     *  content://mms-sms (MmsSmsProvider), which notifies only its own authority -- the likely reason the old watch's
     *  observer on content://sms and content://mms "did not reliably fire" and needed a 3 s poll. Each registration
     *  stands alone, so one the provider refuses does not cost the others. */
    private synchronized void startReadClear() {
        stopReadClear();
        clearThread = new android.os.HandlerThread("nowhere-msg-readclear");
        clearThread.start();
        clearHandler = new android.os.Handler(clearThread.getLooper());
        clearObserver = new android.database.ContentObserver(clearHandler) {
            @Override public void onChange(boolean self) { scheduleEventSweep(); }
        };
        for (String uri : new String[]{"content://sms", "content://mms", "content://mms-sms"}) {
            try {
                getContentResolver().registerContentObserver(android.net.Uri.parse(uri), true, clearObserver);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NWP-20261010-13 observe " + uri, t);
            }
        }
        scheduleEventSweep();
    }

    private synchronized void stopReadClear() {
        if (clearObserver != null) {
            try { getContentResolver().unregisterContentObserver(clearObserver); } catch (Throwable ignore) {}
            clearObserver = null;
        }
        if (clearThread != null) {
            clearThread.quitSafely();
            clearThread = null;
        }
        clearHandler = null;
        sweepPendingSince = 0;
        sweepForEvent = false;
        idleResweeps = 0;
    }

    /** A sweep for an event: debounced (a burst is one sweep) but throttled (sweepDelay), and it restarts the
     *  re-sweep backoff. A no-op while the listener is disconnected. */
    private synchronized void scheduleEventSweep() {
        if (clearHandler == null) return;
        long now = android.os.SystemClock.uptimeMillis();
        if (sweepPendingSince == 0) sweepPendingSince = now;
        sweepForEvent = true;
        clearHandler.removeCallbacks(sweep);
        clearHandler.postDelayed(sweep, sweepDelay(now, sweepPendingSince));
    }

    /** A backstop re-sweep in delayMs, unless an event sweep is already waiting (it runs sooner and does the same). */
    private synchronized void scheduleResweep(long delayMs) {
        if (clearHandler == null || sweepForEvent) return;
        clearHandler.removeCallbacks(sweep);
        clearHandler.postDelayed(sweep, delayMs);
    }

    private void sweepReadNotices() {
        boolean event;
        synchronized (this) {
            event = sweepForEvent;
            sweepForEvent = false;
            sweepPendingSince = 0;
        }
        int[] r = {0, 0};
        try { r = TelIngest.clearReadNotices(this); } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NWP-20261010-13 read clear", t);
        }
        long next;
        synchronized (this) {
            idleResweeps = nextIdleResweeps(event, r[1], idleResweeps);
            next = resweepDelay(r[0], idleResweeps);
        }
        if (next >= 0) scheduleResweep(next);
    }

    /** NWP-20261010-13: how long an event sweep waits. Each event pushes it 0.5 s out (a delivery pass or a thread
     *  marked read is a burst of changes, and one sweep answers it), but never more than 2 s past the first event it
     *  answers, so a provider that keeps changing cannot hold the sweep off for ever. now and pendingSince are uptime
     *  ms; pendingSince is when the first still-unanswered event came. */
    static long sweepDelay(long now, long pendingSince) {
        return Math.max(0L, Math.min(500L, pendingSince + 2_000L - now));
    }

    /** NWP-20261010-13: the backoff count after a sweep: back to 0 after an event or when the sweep cleared anything,
     *  else one more idle re-sweep. */
    static int nextIdleResweeps(boolean event, int cleared, int idle) {
        return event || cleared > 0 ? 0 : idle + 1;
    }

    /** NWP-20261010-13: when to re-sweep without a change notification, or -1 for not until the next event. Only while
     *  a notice of ours is showing whose row is unread, or gone but young (TelIngest.noticeAction's POLL) -- never for
     *  one we cannot read back. The backstop is for a read that reaches the provider without notifying any observed
     *  authority; it costs one getActiveNotifications and one one-column query per notice. It BACKS OFF -- 15 s, then
     *  double each time a re-sweep clears nothing -- and STOPS after 6 idle re-sweeps (about 16 minutes): a read that
     *  never reaches the provider (Messaging not the default SMS app, so its mark-read is refused) would otherwise
     *  poll for the rest of the session. A provider change or a new notice of ours starts it again from 15 s. */
    static long resweepDelay(int pollable, int idle) {
        if (pollable <= 0 || idle >= 6) return -1L;
        return 15_000L << Math.max(idle, 0);
    }
}
