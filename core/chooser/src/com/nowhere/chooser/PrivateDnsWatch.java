package com.nowhere.chooser;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Application;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * NWP-20261122-07: the gate half of the blocked-encrypted-DNS prompt (h49 #2, h50 #4 A1/B1; the rules are in
 * PrivateDnsDowngrade). NWP-20261127-07: the session half (h50 #4 A1). User 0 only: start returns at once in any other
 * user.
 *
 * Started from NowhereApp.onCreate (every process birth: this process is android:persistent and can restart during a
 * session with no gate Activity) and from ChooserActivity.onCreate; idempotent. At start, and at every change of the
 * default network, it puts strict mode back if the marker is there (rule (ii)). When the default network says private
 * DNS is broken while strict mode is on, it asks on the prompt's surface: the decided dialog on the resumed gate, or,
 * while a roamed user is in front, a notification with the decided title and body in that user, whose tap opens the
 * same dialog there (PrivateDnsPromptActivity). That dialog's choice comes back to user 0 by an explicit broadcast
 * (PrivateDnsChoiceReceiver -> onChoice) with the prompt's token, so the Gate here decides, phone-wide. The surface is
 * fed at start (ActivityManager.getCurrentUser: a process born mid-session gets no switch broadcast), at every
 * ACTION_USER_SWITCHED and at every resume and pause of the gate.
 *
 * Everything here is RAM except the marker: files/dns-downgraded in user 0's files dir, empty, no network name
 * (docs/threat-model.md section 2, third table). "Stay private" keeps the Network object in RAM only. Logs carry the
 * mode word and a user id only, never a network name, SSID or id. All callbacks run on the main thread, so no locks.
 * The prompt's state (which network it asks about, where it shows, when it closes, when a button may write) is
 * PrivateDnsDowngrade.Gate.
 */
final class PrivateDnsWatch {
    private static final String TAG = "NowhereChooser";
    private static final String SETTING = "private_dns_mode";
    private static final AtomicBoolean STARTED = new AtomicBoolean(false);
    private static final String CHANNEL = "nowhere.privatedns";
    private static final int NOTIF_ID = 0x0D25; // the chooser's other ids are 0x0D1A-0x0D24 (ChooserActivity)

    private static PrivateDnsDowngrade.Io io;
    private static PrivateDnsDowngrade.Gate gate; // the prompt's state, per default network (PrivateDnsDowngrade.Gate)
    private static PromptUi ui;                   // the gate dialog and the session notification
    private static Activity front;                // the resumed gate, or null
    private static boolean gateResumed;           // a ChooserActivity is resumed
    private static int currentUser = -1;          // the current user (ActivityManager), -1 unread
    private static AlertDialog dialog;            // the showing gate dialog, or null
    private static Method brokenMethod;
    private static boolean brokenLogged;

    private PrivateDnsWatch() {}

    static void start(Context ctx) {
        if (android.os.UserHandle.myUserId() != 0) return;
        if (!STARTED.compareAndSet(false, true)) return;
        final Context app = ctx.getApplicationContext();
        io = new SettingsIo(app);
        ui = new PromptUi(app);
        gate = new PrivateDnsDowngrade.Gate(io, ui);
        PrivateDnsDowngrade.restoreIfMarked(io); // rule (ii): at every start
        currentUser = currentUser(); // a process born mid-session gets no switch broadcast
        feed();
        try {
            IntentFilter f = new IntentFilter(Intent.ACTION_USER_SWITCHED);
            Handler main = new Handler(Looper.getMainLooper());
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(new UserSwitch(), f, null, main, Context.RECEIVER_NOT_EXPORTED);
            } else {
                app.registerReceiver(new UserSwitch(), f, null, main);
            }
        } catch (Throwable t) {
            Log.w(TAG, "private dns watch: user-switch receiver: " + t.getClass().getName());
        }
        ((Application) app).registerActivityLifecycleCallbacks(new GateFront());
        ConnectivityManager cm = app.getSystemService(ConnectivityManager.class);
        if (cm == null) {
            Log.w(TAG, "private dns watch: no ConnectivityManager");
            return;
        }
        cm.registerDefaultNetworkCallback(new DefaultNet(), new Handler(Looper.getMainLooper()));
    }

    /** The current user, or -1 (read as SURFACE_NONE, the fail-safe) when it cannot be read. */
    private static int currentUser() {
        try {
            return android.app.ActivityManager.getCurrentUser();
        } catch (Throwable t) {
            return -1;
        }
    }

    /** Tell the Gate where the prompt can show now. Main thread. */
    private static void feed() {
        gate.onSurface(PrivateDnsDowngrade.surface(gateResumed, currentUser));
    }

    /**
     * The choice made on a session's dialog, from PrivateDnsChoiceReceiver on the main thread. The Gate refuses a token
     * that is not its open prompt's (an old notification, a second tap after a change of surface). A choice clears the
     * prompt without closing it, so the notification that carried this token is cancelled here.
     */
    static void onChoice(long token, boolean cont) {
        if (gate == null) return; // the watch is not started in this process
        if (cont) gate.onContinue(token); else gate.onStay(token);
        ui.chosen(token);
    }

    /** ACTION_USER_SWITCHED, on the main thread: the user now in front. */
    private static final class UserSwitch extends BroadcastReceiver {
        @Override
        public void onReceive(Context c, Intent i) {
            int to = i.getIntExtra(Intent.EXTRA_USER_HANDLE, -1);
            if (to < 0) return;
            currentUser = to;
            feed();
        }
    }

    private static final class DefaultNet extends ConnectivityManager.NetworkCallback {
        @Override
        public void onAvailable(Network n) {
            if (!gate.onAvailable(n)) return; // the same default network: nothing changed
            PrivateDnsDowngrade.restoreIfMarked(io); // rule (ii): a new default network
        }

        @Override
        public void onLost(Network n) {
            gate.onLost(n);
            PrivateDnsDowngrade.restoreIfMarked(io); // rule (ii): the network went away
        }

        @Override
        public void onCapabilitiesChanged(Network n, NetworkCapabilities nc) {
            gate.onBroken(n, privateDnsBroken(nc));
        }
    }

    /** "The gate is resumed": a resumed ChooserActivity. */
    private static final class GateFront implements Application.ActivityLifecycleCallbacks {
        @Override
        public void onActivityResumed(Activity a) {
            if (!(a instanceof ChooserActivity)) return;
            front = a;
            gateResumed = true;
            feed();
        }

        @Override
        public void onActivityPaused(Activity a) {
            if (a != front) return;
            front = null;
            gateResumed = false;
            feed(); // closes the dialog with no choice made; the next resume asks again
        }

        @Override
        public void onActivityDestroyed(Activity a) {
            if (a != front) return;
            front = null;
            gateResumed = false;
            feed();
        }

        @Override public void onActivityCreated(Activity a, Bundle b) {}
        @Override public void onActivityStarted(Activity a) {}
        @Override public void onActivityStopped(Activity a) {}
        @Override public void onActivitySaveInstanceState(Activity a, Bundle b) {}
    }

    /**
     * NetworkCapabilities.isPrivateDnsBroken() is hidden; the chooser is platform-signed, so reflection reaches it.
     * A null, a missing method or any failure reads false (logged once): the fail-safe is never to downgrade.
     */
    static boolean privateDnsBroken(NetworkCapabilities nc) {
        if (nc == null) return false;
        try {
            if (brokenMethod == null) brokenMethod = NetworkCapabilities.class.getMethod("isPrivateDnsBroken");
            return Boolean.TRUE.equals(brokenMethod.invoke(nc));
        } catch (Throwable t) {
            if (!brokenLogged) {
                brokenLogged = true;
                Log.w(TAG, "private dns broken signal unreadable: " + t.getClass().getName());
            }
            return false;
        }
    }

    /**
     * The prompt on its surface: the dialog on the resumed gate, or a notification in the roamed user in front. Each
     * button, the dismissal and the notification's tap carry the token the Gate gave this prompt.
     */
    private static final class PromptUi implements PrivateDnsDowngrade.Ui {
        private final Context app;
        private int postedUid = -1; // the user the notification went to; -1 = none
        private long postedToken;   // the token it carries; 0 = none

        PromptUi(Context app) {
            this.app = app;
        }

        @Override
        public boolean show(long token, int surface) {
            dismiss(); // one prompt at a time
            if (surface == PrivateDnsDowngrade.SURFACE_GATE) return showGate(token);
            if (surface > 0) return postSession(token, surface);
            return false;
        }

        /** The decided dialog on the resumed gate. */
        private boolean showGate(long token) {
            Activity a = front;
            if (a == null) return false;
            try {
                dialog = new AlertDialog.Builder(a)
                        .setTitle(PrivateDnsDowngrade.TITLE)
                        .setMessage(PrivateDnsDowngrade.BODY)
                        .setCancelable(false) // a choice is required; a back press must not loop the prompt
                        .setPositiveButton(PrivateDnsDowngrade.CONTINUE, (d, w) -> gate.onContinue(token))
                        .setNegativeButton(PrivateDnsDowngrade.STAY, (d, w) -> gate.onStay(token))
                        .setOnDismissListener(d -> gate.onDismissed(token))
                        .show();
                return true;
            } catch (Throwable t) {
                dialog = null;
                Log.w(TAG, "private dns prompt: " + t.getClass().getName());
                return false;
            }
        }

        /**
         * The decided title and body as a notification in roamed user uid, posted through that user's context (the
         * ChooserActivity.postBackupNotice shape). Its tap opens PrivateDnsPromptActivity there with this token, through
         * an IMMUTABLE PendingIntent made from that user's context, so no holder can fill in another token. Ongoing: it
         * stays until a choice is made or the Gate closes the prompt.
         */
        private boolean postSession(long token, int uid) {
            try {
                Context uc = app.createContextAsUser(android.os.UserHandle.of(uid), 0);
                NotificationManager nm = uc.getSystemService(NotificationManager.class);
                if (nm == null) return false;
                // The channel's name is the decided title: a channel name shows in Settings, and there are no new words.
                nm.createNotificationChannel(new NotificationChannel(CHANNEL, PrivateDnsDowngrade.TITLE,
                        NotificationManager.IMPORTANCE_HIGH));
                PendingIntent pi = PendingIntent.getActivity(uc, 0,
                        new Intent(uc, PrivateDnsPromptActivity.class)
                                .putExtra(PrivateDnsPromptActivity.EXTRA_TOKEN, token)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                Notification n = new Notification.Builder(uc, CHANNEL)
                        .setSmallIcon(R.drawable.ic_nowhere_notif)
                        .setContentTitle(PrivateDnsDowngrade.TITLE)
                        .setContentText(PrivateDnsDowngrade.BODY)
                        .setStyle(new Notification.BigTextStyle().bigText(PrivateDnsDowngrade.BODY))
                        .setContentIntent(pi)
                        .setOngoing(true)
                        .setShowWhen(false)
                        .build();
                nm.notify(NOTIF_ID, n);
                postedUid = uid;
                postedToken = token;
                Log.i(TAG, "private dns prompt -> user " + uid + " (mode " + io.mode() + ")");
                return true;
            } catch (Throwable t) {
                Log.w(TAG, "private dns prompt -> user " + uid + ": " + t.getClass().getName());
                return false;
            }
        }

        /** A choice came back with this token: cancel the notification only when it carries this token. */
        void chosen(long token) {
            if (token == 0 || token != postedToken) return;
            cancelSession();
        }

        @Override
        public void dismiss() {
            cancelSession();
            AlertDialog d = dialog;
            dialog = null;
            if (d == null) return;
            try {
                d.dismiss();
            } catch (Throwable ignored) {
            }
        }

        /** Cancel the notification in the user it was posted to, if any. Never throws. */
        private void cancelSession() {
            int uid = postedUid;
            postedUid = -1;
            postedToken = 0;
            if (uid <= 0) return;
            try {
                Context uc = app.createContextAsUser(android.os.UserHandle.of(uid), 0);
                NotificationManager nm = uc.getSystemService(NotificationManager.class);
                if (nm != null) nm.cancel(NOTIF_ID);
            } catch (Throwable t) {
                Log.w(TAG, "private dns prompt cancel, user " + uid + ": " + t.getClass().getName());
            }
        }
    }

    /** The real Io: Settings.Global (the chooser holds WRITE_SECURE_SETTINGS) and the user-0 marker file. */
    private static final class SettingsIo implements PrivateDnsDowngrade.Io {
        private final ContentResolver cr;
        private final java.io.File marker;

        SettingsIo(Context app) {
            cr = app.getContentResolver();
            marker = new java.io.File(app.getFilesDir(), "dns-downgraded");
        }

        @Override
        public String mode() {
            try {
                return Settings.Global.getString(cr, SETTING);
            } catch (Throwable t) {
                return null;
            }
        }

        @Override
        public boolean setMode(String m) {
            try {
                boolean ok = Settings.Global.putString(cr, SETTING, m);
                Log.i(TAG, "private dns mode -> " + m + (ok ? "" : " (NOT written)"));
                return ok;
            } catch (Throwable t) {
                Log.w(TAG, "private dns mode -> " + m + " failed: " + t.getClass().getName());
                return false;
            }
        }

        @Override
        public boolean marked() {
            return marker.exists();
        }

        @Override
        public boolean mark() {
            try {
                return marker.createNewFile() || marker.exists();
            } catch (Throwable t) {
                return false;
            }
        }

        @Override
        public boolean unmark() {
            try {
                return marker.delete() || !marker.exists();
            } catch (Throwable t) {
                return false;
            }
        }
    }
}
