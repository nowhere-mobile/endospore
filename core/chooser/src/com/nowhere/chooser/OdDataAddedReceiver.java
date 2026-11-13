package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

/** NWP-20261130-03 (RF-013): the session half of OdDataInstallWatch. It is in the manifest so an explicit broadcast starts
 *  a dead session chooser. With a package it holds that app; with none it reconciles every installed app. */
public class OdDataAddedReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        final Context app = context.getApplicationContext();
        Uri d = intent == null ? null : intent.getData();
        final String pkg = d == null ? null : d.getSchemeSpecificPart();
        if (pkg == null || pkg.isEmpty()) {
            new Thread(() -> OdDataBarrierHost.reconcile(app), "nowhere-od-barrier-sweep").start();
            return;
        }
        final PendingResult pending = goAsync();
        new Thread(() -> {
            try {
                OdDataBarrierHost.onRelayedAdd(app, pkg);
            } finally {
                pending.finish();
            }
        }, "nowhere-od-barrier-relayed").start();
    }
}
