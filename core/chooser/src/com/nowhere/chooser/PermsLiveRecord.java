package com.nowhere.chooser;

import android.content.Context;
import android.content.Intent;
import android.os.UserHandle;

/**
 * NWP-20261112-10 -- the user-0 half of permissions captured on change (Q061, docs/product-decisions.md 2026-10-20).
 *
 * The persistent gate process listens for runtime-permission changes (PackageManager.addOnPermissionsChangeListener,
 * which needs OBSERVE_GRANT_REVOKE_PERMISSIONS; the chooser is platform-signed). A change of a uid that belongs to the
 * armed session marks the record pending; after 2 s of quiet the gate sends an explicit, extra-free broadcast to
 * PermsCaptureReceiver in that session, which re-runs capturePerms into files/nowhere-perms, and the next periodic seal
 * carries the answer. Modelled on DozeAppsMirror's THE LIVE RECORD.
 *
 * User 0 only, process memory only: the armed user id and a pending flag, never persisted, and logs carry the user id
 * only. ChooserActivity.provisionRoamedApps disarms before it sends GRANT-PERMS and arms only on an OK reply
 * (PermsRelayGate.armOn); DozeAppsMirror's ACTION_USER_REMOVED receiver disarms a departed session. A relay that cannot
 * run (the session not current, or locked) stays pending and is retried at the next user switch, unlock or change.
 * Appop (special app access) changes fire no permission callback, so they are still captured only at sign-out. Every
 * step is caught: a failure logs and never throws into the gate.
 */
final class PermsLiveRecord {
    private PermsLiveRecord() {}

    private static final Object LOCK = new Object();
    private static int liveUser = -1;          // the session armed by the last OK GRANT-PERMS; -1 = disarmed
    private static boolean pending;            // a relevant change not yet relayed
    private static android.os.Handler h;       // the relay thread, set by register
    private static Runnable relay;

    /** USER 0, after an OK GRANT-PERMS for uid: relay that session's permission changes to it from now on. */
    static void arm(int uid) {
        synchronized (LOCK) { liveUser = uid; pending = false; }
    }

    /** USER 0, before every GRANT-PERMS: forget any armed session. */
    static void disarm() {
        synchronized (LOCK) { liveUser = -1; pending = false; }
    }

    /** USER 0, on ACTION_USER_REMOVED: if the departed user is the armed session, forget it. */
    static void disarmFor(int departed) {
        synchronized (LOCK) { if (departed == liveUser) { liveUser = -1; pending = false; } }
    }

    /** USER 0, at every process birth (NowhereApp): the permission listener, and a user switch / unlock receiver that
     *  retries a pending relay. Registered for ALL users for DozeAppsMirror.relayFilter's reason: ACTION_USER_UNLOCKED
     *  goes only to the user being unlocked. Both run the relay on their own HandlerThread; the listener is called on
     *  the main looper, so it only flips the flag and posts. */
    static void register(Context ctx) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        try {
            android.os.HandlerThread ht = new android.os.HandlerThread("nowhere-permsrelay");
            ht.start();
            synchronized (LOCK) {
                h = new android.os.Handler(ht.getLooper());
                relay = () -> relay(app);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "perms relay thread", t);
            return;
        }
        try {
            app.getPackageManager().addOnPermissionsChangeListener(uid -> onChanged(uid));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "perms relay listener register", t);
        }
        try {
            android.content.IntentFilter f = new android.content.IntentFilter(Intent.ACTION_USER_SWITCHED);
            f.addAction(Intent.ACTION_USER_UNLOCKED);
            app.registerReceiverForAllUsers(new android.content.BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) { onWake(); }
            }, f, null, h, Context.RECEIVER_NOT_EXPORTED);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "perms relay receiver register", t);
        }
    }

    private static void onChanged(int uid) {
        try {
            synchronized (LOCK) {
                if (!PermsRelayGate.relevant(uid, liveUser)) return;
                pending = true;
            }
            schedule();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "perms relay change", t);
        }
    }

    private static void onWake() {
        try {
            boolean p;
            synchronized (LOCK) { p = pending; }
            if (p) schedule();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "perms relay wake", t);
        }
    }

    /** (Re)start the quiet spell: the relay runs QUIET_MS after the last change. */
    private static void schedule() {
        android.os.Handler hh; Runnable r;
        synchronized (LOCK) { hh = h; r = relay; }
        if (hh == null || r == null) return;
        hh.removeCallbacks(r);
        hh.postDelayed(r, PermsRelayGate.QUIET_MS);
    }

    /** USER 0, on the relay thread: ask the armed session to capture its permissions, only when it is current and
     *  unlocked. The intent is explicit and carries nothing. Traces the user id only. */
    private static void relay(Context app) {
        try {
            int cur = android.app.ActivityManager.getCurrentUser();
            android.os.UserManager um = app.getSystemService(android.os.UserManager.class);
            boolean unlocked = cur > 0 && um != null && um.isUserUnlocked(UserHandle.of(cur));
            synchronized (LOCK) {
                if (!pending || !PermsRelayGate.mayRelay(cur, liveUser, unlocked)) return;
                app.sendBroadcastAsUser(new Intent(app, PermsCaptureReceiver.class)
                        .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES), UserHandle.of(cur));
                pending = false;
            }
            ChooserActivity.idleTrace("permsrelay user=" + cur);
        } catch (Throwable t) {
            ChooserActivity.idleTrace("permsrelay err");
            android.util.Log.w("NowhereChooser", "perms relay", t);
        }
    }
}
