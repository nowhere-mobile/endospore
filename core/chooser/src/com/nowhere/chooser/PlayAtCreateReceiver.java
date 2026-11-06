package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261124-09: writes, in the NEW session's chooser process, the Google Play answer the create form sends
 * (PlayAtCreate). ChooserActivity.sendPlayAtCreate, in user 0, sends it once, after a create and before the
 * switch-in, and only when the answer is on. A sign-in never sends it, and off is never sent.
 *
 * Not exported: only the chooser sends it, from its own process in user 0 -- the same app, so the export check
 * passes, and sendBroadcastAsUser needs INTERACT_ACROSS_USERS_FULL, which the chooser holds (the SimCaseReceiver
 * pattern). The flag goes through ProfileActivity.cfgPutStatic, the Profile › Apps row's own writer: it merges into
 * nowhere-config and never writes over a file it cannot read (NWP-20261111-17).
 *
 * It marks no package: none is installed in a just-created user, and AppInstallReceiver keeps each Play package
 * On-demand when it lands while the flag is on (PlayChoice.keepModeOnInstall).
 */
public final class PlayAtCreateReceiver extends BroadcastReceiver {

    @Override public void onReceive(Context ctx, Intent intent) {
        String v = intent.getStringExtra(PlayAtCreate.EXTRA);
        if (!PlayAtCreate.accepts(v)) return;
        ProfileActivity.cfgPutStatic(ctx, PlayChoice.CFG_KEY, v);
        boolean landed = PlayChoice.parse(ProfileActivity.cfgStatic(ctx, PlayChoice.CFG_KEY)) == PlayChoice.State.ON;
        android.util.Log.i("NowhereChooser", "play-at-create user " + android.os.UserHandle.myUserId()
                + ": play.wanted landed=" + landed + " (NWP-20261124-09)");
    }
}
