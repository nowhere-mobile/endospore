package com.nowhere.chooser;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.SystemClock;

/**
 * NWP-20260824-03: the wake-up that makes the OTA check actually happen on an idle phone.
 *
 * WHY THIS EXISTS. The login daemon kept its OTA answer warm with a Go {@code time.Sleep} loop. Go timers run
 * on CLOCK_MONOTONIC, which does NOT advance across system suspend, so on an idle device the sleep froze and
 * the check simply never ran. Chester proved it on frankel: no update offered for 30+ minutes, then it
 * appeared within SECONDS of the phone being connected to power. Sitting idle at the gate on battery is the
 * NORMAL state of an amnesiac phone, so OTA delivery was effectively gated on someone plugging the device in
 * -- while the gate answered a confident "up to date".
 *
 * The daemon-side fix (part A) makes that loop nap on the wall clock, but that is a MITIGATION, not a
 * guarantee: a process that is never scheduled cannot notice time passing however it measures it. Only
 * something that WAKES THE AP can guarantee a check, and on Android that is an ELAPSED_REALTIME_WAKEUP alarm.
 *
 * NOTHING EXISTING COULD BE REUSED. In precisely the bug state -- idle, logged off, at the gate on battery --
 * zero alarms are armed: the idle cold-lock alarm requires {@code sessionLive} and is torn down at logoff, the
 * #3 hard-wipe alarm is armed only when a cold-locked session is parked, and the #151 gate alarm exists only
 * if a logged-off session relayed a time. So this is a new, deliberately session-INDEPENDENT alarm, armed from
 * {@link NowhereApp} on every process birth (the same reason the reap watcher moved there in #141: the
 * persistent user-0 process can restart with no foreground gate task, so Activity.onCreate never runs).
 *
 * The idiom -- manifest-declared exported="false" receiver, getBroadcast with FLAG_UPDATE_CURRENT |
 * FLAG_IMMUTABLE, setExactAndAllowWhileIdle inside a try with a setAndAllowWhileIdle catch -- is copied
 * verbatim from the idle cold-lock alarm in ChooserActivity. USE_EXACT_ALARM is already held, and
 * docs/lock-model.md records that this API fires on time in Doze on hardware.
 */
public class OtaWakeReceiver extends BroadcastReceiver {

    static final String ACTION = "com.nowhere.chooser.OTA_WAKE";

    /** Request code, distinct from the three alarms already in this package (0 idle, 1 wipe, 1519 gate). */
    private static final int REQ = 824;

    /**
     * Cadence. 2h base with +/-20min of jitter, and a 20min fast lane while the DAEMON gives no answer to
     * OTA-REFRESH (an empty reply: no connection, a read timeout). The receiver never sees a check's result
     * -- OTA-REFRESH is fire-and-return -- so a check that ran and failed is invisible to it. At most 3 fast
     * wakes in a row, then the normal cadence; any other wake resets the count.
     *
     * Why 2h and not tighter: setExactAndAllowWhileIdle is throttled in Doze to roughly one fire per app per
     * ~9 minutes, and this package now holds FOUR allow-while-idle alarms sharing that budget -- one of which
     * (the idle cold-lock) is a SECURITY bound that must never be starved. Anything under ~15min is not
     * merely expensive, it is not deliverable. Against that, the release policy is a monthly security floor
     * plus out-of-band hotfixes, and an OOB hotfix should reach an idle device the same day; 2h caps
     * detection latency at 2h for roughly 12 wakes a day.
     *
     * ⚠ Why the jitter is a REQUIREMENT and not a nicety: a guaranteed timed wake-and-dial turns an
     * opportunistic in-process timer into a fixed-period beacon from a residential IP to the gateway, on a
     * key that names the device codename (ota/&lt;device&gt;/version). nowhere-cloud keeps no identity-linking
     * logs, but a perfectly regular cadence is a correlatable signal regardless of logging policy.
     */
    private static final long BASE_MS   = 2L * 60 * 60 * 1000;
    private static final long JITTER_MS = 20L * 60 * 1000;
    private static final long FAST_MS   = 20L * 60 * 1000;
    private static final int  FAST_MAX  = 3;

    /** Read cap for the daemon round trip. OTA-REFRESH is fire-and-return, so a healthy reply is instant;
     *  this only bites a wedged daemon, and stays far under the background-broadcast ANR bound. */
    private static final int REPLY_CAP_MS = 5000;

    private static int sConsecutiveFast = 0;

    /** Arm (or re-arm) the next wake. Idempotent: FLAG_UPDATE_CURRENT replaces any pending alarm. */
    static void arm(Context ctx) {
        arm(ctx, nextDelayMs(false));
    }

    static void arm(Context ctx, long delayMs) {
        if (android.os.UserHandle.myUserId() != 0) return; // the gate/user-0 process owns this, not a roamed one
        final Context app = ctx.getApplicationContext();
        AlarmManager am = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        PendingIntent pi = pending(app);
        long when = SystemClock.elapsedRealtime() + delayMs;
        try { am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, when, pi); }
        catch (Throwable t) { am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, when, pi); }
    }

    private static PendingIntent pending(Context app) {
        Intent i = new Intent(app, OtaWakeReceiver.class).setAction(ACTION);
        return PendingIntent.getBroadcast(app, REQ, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static long nextDelayMs(boolean fast) {
        if (fast) return FAST_MS;
        // Uniform in [BASE-JITTER, BASE+JITTER]. Math.random is not a security primitive and does not need to
        // be: this only has to be irregular, not unpredictable.
        return BASE_MS - JITTER_MS + (long) (Math.random() * (2 * JITTER_MS));
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (android.os.UserHandle.myUserId() != 0) return;
        // NWP-20260824-06: accept BOTH triggers. The manifest declares an ACTION_POWER_CONNECTED filter, and
        // this guard used to drop everything that was not our own alarm action -- so the power-connect trigger
        // was inert, which is embarrassing given that plugging the phone in is the exact signal that exposed
        // the original bug. A power connection re-arms the alarm too (below), which is harmless and keeps the
        // cadence anchored to the last time we actually checked.
        final String act = intent.getAction();
        final boolean powered = Intent.ACTION_POWER_CONNECTED.equals(act);
        if (!ACTION.equals(act) && !powered) return;
        final Context app = ctx.getApplicationContext();

        // ⚠ RE-ARM FIRST, unconditionally. Every early return below is a reason to check again LATER, never a
        // reason to stop checking -- and an alarm that fails to re-arm itself is a device that silently never
        // updates again until reboot. This is the one line whose absence would recreate the original bug in a
        // new shape.
        boolean fast = false;
        try {
            if (!networkUsable(app)) {
                // No validated network -- at the gate the device is Wi-Fi-only with cellular data off, so this
                // is a normal state, not an error. Do NOT open the socket: a refresh that cannot reach the
                // store would burn awake time failing and set lasterr for no reason.
                android.util.Log.i("NowhereChooser", "ota wake: no validated network, deferring");
            } else {
                // Fire-and-return. Deliberately does NOT wait for the answer: the refresh itself can take far
                // longer than any broadcast may live, and its result is read later from OTA-STATUS by whatever
                // paints the UI. The tag is a SECOND LINE -- appending it to the verb would miss the daemon's
                // concurrency allowlist and fall through to the login path.
                String r = DaemonSocket.roundTrip("OTA-REFRESH\n" + (powered ? "power" : "alarm") + "\n", REPLY_CAP_MS);
                android.util.Log.i("NowhereChooser", "ota wake (" + (powered ? "power" : "alarm") + "): OTA-REFRESH -> "
                        + (r.isEmpty() ? "(no reply)" : r));
                // Retry sooner only while the daemon gives no reply at all (an empty string: no connection, a read
                // timeout); a non-empty reply, whatever it says, is the normal cadence. Bounded so a dead daemon
                // can never turn this into a 20-minute wake loop.
                fast = r.isEmpty() && sConsecutiveFast < FAST_MAX;
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "ota wake", t);
        } finally {
            sConsecutiveFast = fast ? sConsecutiveFast + 1 : 0;
            arm(app, nextDelayMs(fast));
        }
    }

    /** True only for a network the system has VALIDATED (has actual connectivity), not merely connected. */
    private static boolean networkUsable(Context app) {
        try {
            ConnectivityManager cm = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return false;
            Network n = cm.getActiveNetwork();
            if (n == null) return false;
            NetworkCapabilities c = cm.getNetworkCapabilities(n);
            return c != null && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        } catch (Throwable t) {
            return false; // unknown -> treat as unusable; the next wake retries
        }
    }
}
