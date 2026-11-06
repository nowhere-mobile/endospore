package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261012-07: user 0's default-dialer answer to Telecom's missed-call notification, so that Telecom never posts
 * its own. Chester, 2026-10-12, on frankel: "after logging off, lock screen shows missed call".
 *
 * Every SIM call is also written to the SYSTEM user's call log (Telecom CallLogManager: a MULTI_USER account's call is
 * logged with addForAllUsers). On the switch back to user 0 at a sign-out, Telecom's CallsManager.onUserSwitch runs
 * MissedCallNotifierImpl.reloadFromDatabase for user 0, which reads that log's unread missed calls and shows each. The
 * same notifier shows a live miss at the gate. In both, MissedCallNotifierImpl decides ONE thing: whether user 0's
 * default dialer -- the chooser (ChooserActivity.ensureDefaultDialerRole) -- has a receiver for
 * ACTION_SHOW_MISSED_CALLS_NOTIFICATION (shouldManageNotificationThroughDefaultDialer: a queryBroadcastReceivers in that
 * user, nothing more). With none, Telecom posts its own notification in user 0 (tag MissedCallNotifierImpl, channel
 * TelecomMissedCalls) carrying the caller's number: a cleartext trace on the non-amnesiac user, the leak #197 could only
 * race with cancels. With this receiver it hands the dialer the broadcast instead and posts nothing. Telecom waits for
 * no reply and has no fallback: the choice is made on the receiver's existence before the broadcast is sent.
 *
 * What the receiver does with it is NOT a notification. The owner's record of the call is the sealed inbox (the
 * InCallService seals it), and the gate's own notices -- "Missed call - an unassigned SIM" and the loss notice -- are
 * posted by SmsDeliverReceiver with the chooser's own NotificationManager, never through Telecom, so they are untouched.
 * Here: delete user 0's call log, which is all the broadcast is about (TelScrub.callLog), and, when the broadcast
 * reports calls, zero Telecom's per-user count with cancelMissedCallsNotification. That cancel comes back as a count-0
 * broadcast, which is dropped (plan), and Telecom sends no second count-0 (its "skipping redundant clear"), so the
 * exchange ends there.
 *
 * Only in user 0. The chooser exists in every user, and a roamed user's call log is that session's own -- it must
 * never be scrubbed from here. Telecom addresses the broadcast to the dialer of the user it concerns, and the chooser
 * holds the dialer role only in user 0, so a roamed user should never receive it; plan() refuses it regardless.
 *
 * Who can send it: the action is a protected broadcast (frameworks/base core/res/AndroidManifest.xml), so only the
 * system can, and Telecom sends it with READ_PHONE_STATE as the receiver permission, which the chooser holds as user 0's
 * dialer. Exported, with no permission of its own, exactly as the AOSP Dialer declares its receiver.
 */
public final class MissedCallReceiver extends BroadcastReceiver {
    /** TelecomManager.ACTION_SHOW_MISSED_CALLS_NOTIFICATION. */
    static final String ACTION = "android.telecom.action.SHOW_MISSED_CALLS_NOTIFICATION";
    /** TelecomManager.EXTRA_NOTIFICATION_COUNT: the missed calls the notification would show; 0 means dismiss it. */
    static final String EXTRA_COUNT = "android.telecom.extra.NOTIFICATION_COUNT";

    static final int DROP = 0;         // nothing to do
    static final int SCRUB_RESET = 1;  // delete user 0's call log, then zero Telecom's count

    /** What to do with one broadcast. action: the intent's; userId: the user this process runs in; count: the
     *  EXTRA_COUNT, or -1 when absent. A count of 0 is Telecom's dismiss -- the answer to our own cancel -- and needs
     *  nothing; an absent count is treated as calls, because scrubbing is always safe in user 0. */
    static int plan(String action, int userId, int count) {
        if (!ACTION.equals(action)) return DROP;
        if (userId != 0) return DROP;
        if (count == 0) return DROP;
        return SCRUB_RESET;
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        final int count = intent == null ? -1 : intent.getIntExtra(EXTRA_COUNT, -1);
        final int plan = plan(intent == null ? null : intent.getAction(),
                android.os.Process.myUserHandle().getIdentifier(), count);
        // No number, no name: the extras carry the caller's number, and this log line must not.
        android.util.Log.i("NowhereChooser", "missed-call broadcast count=" + count + " -> "
                + (plan == SCRUB_RESET ? "scrub" : "drop"));
        if (plan != SCRUB_RESET) return;
        final Context app = ctx.getApplicationContext();
        final PendingResult pr = goAsync();
        new Thread(() -> {
            try {
                TelScrub.callLog(app);
                android.telecom.TelecomManager tm = app.getSystemService(android.telecom.TelecomManager.class);
                if (tm != null) tm.cancelMissedCallsNotification();
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "missed-call scrub", t);
            } finally {
                pr.finish();
            }
        }, "nowhere-scrub-missed").start();
    }
}
