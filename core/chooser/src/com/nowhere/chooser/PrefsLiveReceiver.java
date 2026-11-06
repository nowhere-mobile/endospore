package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261119-21: applies, in USER 0's process, a Security-screen change the running session just saved (h45 #4 in
 * docs/product-decisions.md, 2026-10-25). The gate's idle and wipe statics are set at sign-in from GET-PREFS, which
 * serves the sign-in's snapshot, so the gate cannot see a later change by itself. ProfileActivity.sendLivePrefs, in the
 * roamed user, reads the five values back from nowhere-prefs after its write landed and sends them here.
 *
 * Not exported: only the chooser sends it, from its own process in the foreground user -- the same app, so the export
 * check passes, and sendBroadcastAsUser needs INTERACT_ACROSS_USERS_FULL, which the chooser holds (the
 * RejectedCallSealReceiver pattern). The values parse through RoamedPrefs with the gate's own defaults, so a missing or
 * junk extra reads exactly as it would at sign-in. ChooserActivity.applyLivePrefs ignores a sender that is not the
 * current, live session. It gets the APPLICATION context: armIdleWatcher registers receivers, which a receiver's own
 * Context refuses.
 */
public final class PrefsLiveReceiver extends BroadcastReceiver {

    static final String EXTRA_IDLE = "nowhere.prefs.idle", EXTRA_WIPE = "nowhere.prefs.wipe",
            EXTRA_WIPESAVED = "nowhere.prefs.wipesaved", EXTRA_HOLDLOCK = "nowhere.prefs.holdlock",
            EXTRA_HOLDAUDIO = "nowhere.prefs.holdaudio", EXTRA_UID = "nowhere.prefs.uid";

    @Override public void onReceive(Context ctx, Intent intent) {
        final Context app = ctx.getApplicationContext();
        final RoamedPrefs.Values v = RoamedPrefs.parse(intent.getStringExtra(EXTRA_IDLE), intent.getStringExtra(EXTRA_WIPE),
                intent.getStringExtra(EXTRA_WIPESAVED), intent.getStringExtra(EXTRA_HOLDLOCK),
                intent.getStringExtra(EXTRA_HOLDAUDIO),
                ChooserActivity.IDLE_LOGOFF_MS, ChooserActivity.HARD_WIPE_MS);
        ChooserActivity.applyLivePrefs(app, intent.getIntExtra(EXTRA_UID, -1), v);
    }
}
