package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261002-03 -- the session half of the LIVE Doze record (DozeAppsMirror, "THE LIVE RECORD").
 *
 * Its only sender is the user-0 gate (DozeAppsMirror.relayToLiveSession), which relays an explicit, extra-free
 * broadcast to this receiver in the live session user when that session's own battery-Unrestricted set has changed.
 * It re-records the set (DozeAppsMirror.capture) into files/nowhere-doze-apps, so the next periodic seal carries it
 * into the profile's store head -- which is what lets a choice survive a session that ends in a cold lock and is
 * then signed into fresh by the same profile. The intent carries nothing: capture reads the system itself.
 *
 * Not exported: the gate reaches it because a cross-user broadcast between two instances of the same app passes
 * the non-exported check. Never acts in user 0, where nobody makes choices. capture() removes nothing.
 */
public class DozeCaptureReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (android.os.UserHandle.myUserId() == 0) return; // nobody makes choices on the gate
        final PendingResult pending = goAsync();
        final Context app = ctx.getApplicationContext();
        new Thread(() -> {
            try { DozeAppsMirror.capture(app); } finally { pending.finish(); }
        }, "nowhere-dozecap").start();
    }
}
