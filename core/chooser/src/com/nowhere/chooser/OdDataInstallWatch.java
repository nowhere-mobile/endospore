package com.nowhere.chooser;

import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.UserHandle;
import android.os.UserManager;
import android.util.Log;

/** NWP-20261130-03 (RF-013): the user-0 half of the launch barrier's package-added event. A manifest receiver cannot hear
 *  ACTION_PACKAGE_ADDED (AppInstallReceiver's header), and the session chooser's runtime receiver dies with its process.
 *  The user-0 process is android:persistent, so it listens for every user's installs here and relays each one by name to
 *  OdDataAddedReceiver in that session; an explicit broadcast starts a dead process. The rules are OdDataBarrier.Watch.
 *  Every step is caught: a failure logs and never throws into the gate. */
final class OdDataInstallWatch implements OdDataBarrier.Watch.Platform {
    private static final String TAG = "NowhereChooser";

    private final Context app;
    private final OdDataBarrier.Watch rule = new OdDataBarrier.Watch();

    private OdDataInstallWatch(Context app) { this.app = app; }

    /** USER 0, at every process birth (NowhereApp). Registered for ALL users: PACKAGE_ADDED goes to the installing user. */
    static void register(Context ctx) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        try {
            HandlerThread ht = new HandlerThread("nowhere-odwatch");
            ht.start();
            Handler h = new Handler(ht.getLooper());
            final OdDataInstallWatch w = new OdDataInstallWatch(app);
            IntentFilter added = new IntentFilter(Intent.ACTION_PACKAGE_ADDED);
            added.addDataScheme("package");
            app.registerReceiverForAllUsers(new BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) {
                    try {
                        Uri d = i.getData();
                        w.rule.onAdded(w, getSendingUserId(), d == null ? null : d.getSchemeSpecificPart(), app.getPackageName());
                    } catch (Throwable t) {
                        Log.w(TAG, "od-watch added", t);
                    }
                }
            }, added, null, h, Context.RECEIVER_NOT_EXPORTED);
            IntentFilter users = new IntentFilter(Intent.ACTION_USER_SWITCHED);
            users.addAction(Intent.ACTION_USER_UNLOCKED);
            app.registerReceiverForAllUsers(new BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) {
                    try {
                        w.rule.onUserChange(w);
                    } catch (Throwable t) {
                        Log.w(TAG, "od-watch user change", t);
                    }
                }
            }, users, null, h, Context.RECEIVER_NOT_EXPORTED);
        } catch (Throwable t) {
            Log.w(TAG, "od-watch register", t);
        }
    }

    @Override public int currentUser() { return ActivityManager.getCurrentUser(); }

    @Override public boolean unlocked(int user) {
        UserManager um = app.getSystemService(UserManager.class);
        return um != null && um.isUserUnlocked(UserHandle.of(user));
    }

    @Override public void relay(int user, String pkg) {
        send(user, new Intent(app, OdDataAddedReceiver.class).setData(Uri.fromParts("package", pkg, null)));
    }

    @Override public void sweep(int user) {
        send(user, new Intent(app, OdDataAddedReceiver.class));
    }

    private void send(int user, Intent i) {
        // FOREGROUND: the background queue can hold a broadcast for seconds, and the app is launchable until this lands.
        app.sendBroadcastAsUser(i.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES | Intent.FLAG_RECEIVER_FOREGROUND), UserHandle.of(user));
    }
}
