package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261122-13: holds, in the SESSION's chooser process, the SIM case the gate sends (h52 #3,
 * docs/product-decisions.md, 2026-11-01). ChooserActivity.sendSimCase, in user 0, sends it at sign-in and after each
 * re-verdict; ProfileActivity.showPreferences reads stored() and draws ForeignSimLine.line of it.
 *
 * Not exported: only the chooser sends it, from its own process in user 0 -- the same app, so the export check
 * passes, and sendBroadcastAsUser needs INTERACT_ACROSS_USERS_FULL, which the chooser holds (the PrefsLiveReceiver
 * pattern, in the other direction). The case lives in process memory only: the seal carries every file under the
 * chooser's data dir, and the case must not roam. A malformed extra stores null, so no line is drawn from it.
 */
public final class SimCaseReceiver extends BroadcastReceiver {

    static final String EXTRA_CASE = "nowhere.simcase";

    private static volatile ForeignSimLine.Case stored;

    static ForeignSimLine.Case stored() {
        return stored;
    }

    @Override public void onReceive(Context ctx, Intent intent) {
        stored = ForeignSimLine.decode(intent.getStringExtra(EXTRA_CASE));
    }
}
