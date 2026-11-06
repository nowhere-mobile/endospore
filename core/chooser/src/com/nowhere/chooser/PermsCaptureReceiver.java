package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261112-07 -- the session half of permissions captured on change (Q061, docs/product-decisions.md 2026-10-20).
 *
 * Its only sender is the user-0 gate (NOWHERE-1073), which relays an explicit, extra-free broadcast to this receiver
 * in the live session user after 2 s of quiet once that session's permissions have changed. It re-runs capturePerms
 * into files/nowhere-perms, so the next periodic seal carries an Allow / Don't allow given in a session that never
 * signs out (a cold lock and its wipe, a power-off). The intent carries nothing: capturePerms reads the system itself.
 *
 * The gate arms only after this session's GRANT-PERMS: a capture before it would record a fresh user's ungranted state
 * over the profile's carried lines. An app uninstalled this session is still in the keep-set here and is carried
 * forward until the sign-out's capture prunes it (captureAppCode runs first there). An on-demand or auto app whose
 * restore has not landed keeps its carried lines verbatim (PermsCaptureRule.keepCarried): odrestore's grant_perms_for
 * reads them from nowhere-perms, so overwriting them before it runs would strip every permission the app carried.
 * An unreadable keep-set or record captures nothing (NWP-20261123-11).
 *
 * Not exported, as DozeCaptureReceiver: the gate reaches it because a cross-user broadcast between two instances of
 * the same app passes the non-exported check. Never acts in user 0, where nobody answers a permission.
 */
public class PermsCaptureReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (android.os.UserHandle.myUserId() == 0) return; // nobody answers permissions on the gate
        final PendingResult pending = goAsync();
        final Context app = ctx.getApplicationContext();
        new Thread(() -> {
            try {
                ProfileActivity.capturePerms(app, ProfileActivity.readAppModesStrictIn(app.getFilesDir()), true);
            } finally { pending.finish(); }
        }, "nowhere-permscap").start();
    }
}
