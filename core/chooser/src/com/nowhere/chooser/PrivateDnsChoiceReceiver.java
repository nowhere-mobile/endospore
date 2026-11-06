package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

/**
 * NWP-20261127-07 (h50 #4 A1): takes, in USER 0, the choice made on PrivateDnsPromptActivity in a signed-in session to
 * PrivateDnsWatch's Gate, which applies it phone-wide. The activity sends it with sendBroadcastAsUser(...,
 * UserHandle.SYSTEM), the PrefsLiveReceiver shape.
 *
 * Not exported: only the chooser sends it, from its own process in the foreground user -- the same app, so the export
 * check passes. It acts only in user 0, where the watch runs; a copy in any other user does nothing. The Gate refuses a
 * token that is not its open prompt's, and a watch that is not started in this process does nothing. The work runs on
 * the main thread, where every other Gate call runs.
 */
public final class PrivateDnsChoiceReceiver extends BroadcastReceiver {
    static final String EXTRA_CHOICE = "nowhere.privatedns.choice";

    @Override public void onReceive(Context ctx, Intent intent) {
        if (android.os.UserHandle.myUserId() != 0) return;
        final long token = intent.getLongExtra(PrivateDnsPromptActivity.EXTRA_TOKEN, 0);
        final String choice = intent.getStringExtra(EXTRA_CHOICE);
        final boolean cont;
        if (PrivateDnsDowngrade.CHOICE_CONTINUE.equals(choice)) cont = true;
        else if (PrivateDnsDowngrade.CHOICE_STAY.equals(choice)) cont = false;
        else return;
        new Handler(Looper.getMainLooper()).post(() -> PrivateDnsWatch.onChoice(token, cont));
    }
}
