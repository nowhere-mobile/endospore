package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.telephony.SubscriptionManager;

/**
 * NWP-20260930-05: seals, in USER 0's process, the missed-call record of a call NowhereCallControlService declines in
 * a stranger's session. That service runs as the foreground user (its class doc), so the seal used to run in the
 * stranger's chooser process: not persistent, so it could be frozen or stopped before the daemon answered, and with
 * no record of which lines are Private (TelArrival.knownPrivate), so a Private line could get the loss notice. User
 * 0's process is persistent (android:persistent in AndroidManifest.xml), and SEAL-TEL answers only it.
 *
 * Not exported: only the chooser sends it, from its own process in the foreground user -- the same app, so the export
 * check passes, and sendBroadcastAsUser needs INTERACT_ACROSS_USERS_FULL, which the chooser holds. onReceive returns
 * at once; the seal runs on a worker thread, retried to TelArrival.SEAL_DEADLINE_MS, as SmsDeliverReceiver's does.
 */
public final class RejectedCallSealReceiver extends BroadcastReceiver {

    static final String EXTRA_SUB = "nowhere.call.sub", EXTRA_ICCID = "nowhere.call.iccid", EXTRA_FROM = "nowhere.call.from",
            EXTRA_WHEN = "nowhere.call.when", EXTRA_MONO = "nowhere.call.mono";

    @Override public void onReceive(Context ctx, Intent intent) {
        final Context app = ctx.getApplicationContext();
        final int subId = intent.getIntExtra(EXTRA_SUB, SubscriptionManager.INVALID_SUBSCRIPTION_ID);
        final String iccid = intent.getStringExtra(EXTRA_ICCID), from = intent.getStringExtra(EXTRA_FROM);
        final long when = intent.getLongExtra(EXTRA_WHEN, 0L), mono = intent.getLongExtra(EXTRA_MONO, TelArrival.stamp());
        new Thread(() -> seal(app, subId, iccid, from, when, mono), "nowhere-seal-rejected-call").start();
    }

    /** One arrival id -- the call's subId and creation time, as the in-call service computes it -- retried to the
     *  deadline; a repeat is answered from the daemon's replay table. gateNotice false: the call was rejected while a
     *  stranger held the phone, and the owner's labelled notice would show them the line's label. An unassigned SIM's
     *  notice and the loss notice carry no label (SmsDeliverReceiver.settle) -- which is what gives a rejected call on
     *  an unassigned SIM its gate notice (docs/backlog.md, "An unbound-SIM call during a roamed session whose profile
     *  owns no SIM is rejected with no gate notice at all"). */
    static void seal(Context app, int subId, String iccid, String from, long when, long mono) {
        SmsDeliverReceiver.sealAndNotify(app, "call", subId, iccid, from, when, "", 3 /*MISSED*/, 0 /*durSec*/,
                false /*gateNotice*/, TelArrival.callId(subId, when), mono);
    }
}
