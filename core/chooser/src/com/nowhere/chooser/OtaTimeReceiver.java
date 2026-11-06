package com.nowhere.chooser;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.app.admin.DevicePolicyManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.UserHandle;
import android.os.UserManager;
import java.util.Calendar;
import java.util.List;
import java.util.TimeZone;

/**
 * NWP-20261108-08: the preferred-time OTA install that survives deep sleep.
 *
 * WHY THIS EXISTS. The gate's {@code otaTimeCheck} is a Handler.postDelayed loop, and the Handler counts
 * SystemClock.uptimeMillis, which STOPS while the AP is suspended. A phone left charging at the gate at 23:00 with
 * "03:00" chosen suspends, the loop's next run is whenever something wakes it after 04:00, and the install window
 * ({@link OtaWindow#within}) is only the 60 minutes from HH:MM -- so nothing installs while Settings reads
 * "Install time: 3:00 AM". {@link OtaWakeReceiver} (2 h +/-20 min) only sends OTA-REFRESH and can step over a
 * 60-minute band. Backlog: the preferred-time OTA auto-install poll has the same class of bug.
 *
 * THE SHAPE. One RTC_WAKEUP alarm at the next occurrence of the chosen HH:MM, re-armed at every fire, armed at process
 * birth ({@link NowhereApp}), at the gate's onResume and by the time picker. The Handler poll stays as the awake
 * fast lane; both ask the same terms ({@link OtaWindow#installAtAlarm} is this receiver's copy of otaTimeCheck's).
 *
 * WHAT IT MUST NOT OPEN. The gate's timers die with the gate Activity, which finishes at the switch into a session,
 * so until now no auto-install trigger ran during a session. This alarm fires at HH:MM while a signed-in user
 * charges overnight. Its live-session term therefore does not rest on {@code ChooserActivity.sessionLive} alone (a
 * static a restart of the persistent process leaves false until the reap watcher's #123 self-heal): it also reads
 * any unlocked secondary user. And the receiver itself passes the Q063 hold (docs/product-decisions.md, 2026-10-20):
 * a parked cold lock holds automatic install, asked LAST, right before the decision.
 */
public class OtaTimeReceiver extends BroadcastReceiver {

    static final String ACTION = "com.nowhere.chooser.OTA_TIME";
    static final String EXTRA = "hhmm";

    /** Request code, distinct from the alarms already in this package (0 idle, 1 wipe, 1519 gate, 824 OTA wake). */
    private static final int REQ = 2019;

    /** Read cap per daemon round trip. Six reads at most, so a wedged daemon costs 30 s, inside the 60 s
     *  background-broadcast bound. */
    private static final int REPLY_CAP_MS = 5000;

    /** Arm (or re-arm) the alarm for the next {@code hhmm}. Idempotent: FLAG_UPDATE_CURRENT replaces a pending one.
     *  A malformed or empty time cancels. */
    static void arm(Context ctx, String hhmm) {
        if (UserHandle.myUserId() != 0) return; // the gate/user-0 process owns this, not a roamed one
        final Context app = ctx.getApplicationContext();
        long when = OtaWindow.nextStartMillis(hhmm, System.currentTimeMillis(), TimeZone.getDefault());
        if (when < 0) { cancel(app); return; }
        AlarmManager am = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(app, OtaTimeReceiver.class).setAction(ACTION).putExtra(EXTRA, hhmm);
        PendingIntent pi = PendingIntent.getBroadcast(app, REQ, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        // Why NOT the allow-while-idle variant: an install needs the phone charging, and a charging phone is not in
        // Doze, so a plain exact alarm is on time. It also spares the allow-while-idle budget the idle cold-lock
        // alarm (a security bound) shares. RTC_WAKEUP still wakes a suspended AP.
        try { am.setExact(AlarmManager.RTC_WAKEUP, when, pi); }
        catch (Throwable t) { am.set(AlarmManager.RTC_WAKEUP, when, pi); }
    }

    static void cancel(Context ctx) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        Intent i = new Intent(app, OtaTimeReceiver.class).setAction(ACTION);
        PendingIntent pi = PendingIntent.getBroadcast(app, REQ, i,
                PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE);
        if (pi == null) return;
        AlarmManager am = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
        if (am != null) am.cancel(pi);
        pi.cancel();
    }

    /** Arm from the daemon's stored time. Alarms do not survive a reboot, so this runs at every process birth and at
     *  the gate's onResume. No answer leaves whatever is armed; an empty answer (no time set) cancels. */
    static void armFromDaemon(Context ctx) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        new Thread(() -> {
            try {
                List<String> t = DaemonSocket.roundTripLinesOrNull("GET-OTA-TIME\n", REPLY_CAP_MS);
                if (t == null) return;          // no answer: leave whatever is armed
                if (t.isEmpty()) cancel(app);   // no time set (the reader drops the empty reply line)
                else arm(app, t.get(0));
            } catch (Throwable e) {
                android.util.Log.w("NowhereChooser", "ota time: arm", e);
            }
        }, "nowhere-otatime-arm").start();
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        final String armed = intent.getStringExtra(EXTRA);
        // ⚠ RE-ARM FIRST, unconditionally, before anything that can throw or block: a fire that dies below must
        // still leave tomorrow's alarm in place, or one bad fire ends the chain for good.
        arm(app, intent.getStringExtra(EXTRA));
        final PendingResult pr = goAsync();
        new Thread(() -> {
            try {
                String auto = DaemonSocket.roundTrip("GET-OTA-AUTO\n", REPLY_CAP_MS);
                List<String> times = DaemonSocket.roundTripLinesOrNull("GET-OTA-TIME\n", REPLY_CAP_MS);
                List<String> st = DaemonSocket.roundTripLines("OTA-STATUS\n", REPLY_CAP_MS);
                String status = st.isEmpty() ? "" : st.get(0).trim();
                boolean charging = charging(app);
                boolean live = sessionLive(app);
                Calendar c = Calendar.getInstance();
                int minute = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
                // Q063: asked LAST, right before the decision.
                boolean held = OtaUpdate.autoInstallHeld(DaemonSocket.roundTrip("GET-COLDLOCK\n", REPLY_CAP_MS),
                        DaemonSocket.roundTrip("GET-COLDLOCK-PENDING\n", REPLY_CAP_MS));
                if (times != null) { // the time changed since this alarm was armed: follow the daemon
                    String now = times.isEmpty() ? "" : times.get(0).trim();
                    if (!now.equals(armed == null ? "" : armed.trim())) {
                        if (now.isEmpty()) cancel(app); else arm(app, now);
                    }
                }
                if (OtaWindow.installAtAlarm(live, auto, times, minute, charging, status, held)) {
                    // The alarm's wakelock ends at pr.finish(), and OTA-APPLY only starts nowhere_otad, which takes its
                    // own nowhere_ota wakelock later: hold the AP awake across that gap, released by its own timeout.
                    android.os.PowerManager pm =
                            (android.os.PowerManager) app.getSystemService(Context.POWER_SERVICE);
                    if (pm != null) pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "nowhere:otatime").acquire(30_000);
                    String r = DaemonSocket.roundTrip("OTA-APPLY\n", REPLY_CAP_MS);
                    android.util.Log.i("NowhereChooser", "ota time: OTA-APPLY sent -> " + (r.isEmpty() ? "(no reply)" : r));
                } else {
                    android.util.Log.i("NowhereChooser", "ota time: " + why(live, auto, times, minute, charging, status, held));
                }
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "ota time", t);
            } finally {
                pr.finish();
            }
        }, "nowhere-otatime").start();
    }

    private static boolean charging(Context app) {
        try {
            Intent bs = app.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            return bs != null && bs.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
        } catch (Throwable t) {
            return false; // not charging blocks the install: the safe side
        }
    }

    /** True when a session may be signed in. This is the first auto-install trigger that fires DURING a session, and
     *  {@code ChooserActivity.sessionLive} is a static a restart of the persistent process resets until the reap
     *  watcher's #123 self-heal, so it is not enough alone: any unlocked secondary user (the #123 test) counts too.
     *  A cold-locked user is not unlocked; that session is the parked hold, read separately as {@code held}. A read
     *  that fails reads as live: an install is a reboot. */
    private static boolean sessionLive(Context app) {
        if (ChooserActivity.isSessionLive()) return true;
        try {
            DevicePolicyManager dpm = (DevicePolicyManager) app.getSystemService(Context.DEVICE_POLICY_SERVICE);
            UserManager um = (UserManager) app.getSystemService(Context.USER_SERVICE);
            if (dpm == null || um == null) return true;
            for (UserHandle uh : dpm.getSecondaryUsers(new ComponentName(app, AdminReceiver.class))) {
                if (um.isUserUnlocked(uh)) return true;
            }
            return false;
        } catch (Throwable t) {
            return true;
        }
    }

    /** The first term installAtAlarm failed, in its order, for the one log line per fire. Never a profile name. */
    private static String why(boolean live, String auto, List<String> times, int minute, boolean charging,
                              String status, boolean held) {
        if (live) return "a session is live";
        if (!charging) return "not charging";
        if (held) return "held: a session is parked by a cold lock (Q063)";
        if (auto == null || !"1".equals(auto.trim())) return "automatic install is off";
        if (times == null) return "no install time (GET-OTA-TIME: no answer)";
        if (times.isEmpty() || times.get(0) == null) return "no install time set";
        if (!OtaWindow.within(times.get(0).trim(), minute)) return "outside the install window";
        int sp = status == null ? -1 : status.indexOf(' ');
        String tok = status == null ? "" : (sp < 0 ? status : status.substring(0, sp));
        return "OTA-STATUS " + tok + ", not AVAIL: an install already started (the daemon seeds STAGING) or there is nothing to install";
    }
}
