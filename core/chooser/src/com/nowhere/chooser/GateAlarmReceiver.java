package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * #151 (a phone that can't wake you): the user-0 gate alarm fired -> launch the full-screen ring. The alarm was
 * scheduled by {@link ChooserActivity} from a logged-off session's relayed next-alarm time (a stopped roamed
 * user's own alarms don't fire, so the phone would otherwise never ring). Manifest-registered so it wakes even
 * if the chooser process had been reaped (the chooser is android:persistent, so it normally hasn't). Each fire also
 * records whether a roamed user was running, only stopped, or absent (NWP-20261204-07).
 */
public class GateAlarmReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context ctx, Intent intent) {
        try {
            ctx.startActivity(new Intent(ctx, GateAlarmActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    // NWP-20261116-12: the automatic snoozes so far ride from the alarm to the ring (GateAlarmAuto).
                    .putExtra(GateAlarmAuto.EXTRA, GateAlarmAuto.sane(intent.getIntExtra(GateAlarmAuto.EXTRA, 0))));
            // NWP-20260914-02: AFTER the launch, never before -- the alarm is what the user is waiting for.
            // This line is what separates "the alarm never fired" from "it fired and the UI went wrong",
            // which on 2026-09-13 were indistinguishable from every ticket filed at the gate.
            GateTrace.ev("fired");
            // NWP-20261204-07, §B "AN ALARM FROM A LOGGED-OFF PROFILE STILL RINGS AT THE GATE": was a roamed user
            // RUNNING when this fired? A stopped user's alarms do not fire, so "running" says its own clock could
            // ring too (candidate 2); "none" or "stopped" says only this gate copy could. gate_log.go's scope rule:
            // a relation, never a user id, a count or a time. Off this thread (binder calls per user), and after
            // the launch and "fired". Its order against ui-guard-self / ui-create is not guaranteed (separate
            // threads): a reader matches it by verb, not by position.
            final Context app = ctx.getApplicationContext();
            try {
                new Thread(() -> traceRoamed(app), "nowhere-gate-roamed").start();
            } catch (Throwable ignore) {
                // The thread did not start. The alarm launched; that matters more than this trace.
            }
        } catch (Throwable t) {
            GateTrace.ev("fired-err");
            android.util.Log.w("NowhereChooser", "gate alarm launch", t);
        }
    }

    /** NWP-20261204-07: sends ONE fired-roamed-* verb (GateAlarmVerbs.roamed). No log line here: none may name a user. */
    private static void traceRoamed(Context app) {
        try {
            android.app.admin.DevicePolicyManager dpm = (android.app.admin.DevicePolicyManager)
                    app.getSystemService(Context.DEVICE_POLICY_SERVICE);
            android.os.UserManager um = (android.os.UserManager) app.getSystemService(Context.USER_SERVICE);
            if (dpm == null || um == null || !dpm.isDeviceOwnerApp(app.getPackageName())) {
                GateTrace.ev(GateAlarmVerbs.roamed(0, 0, true));
                return;
            }
            android.content.ComponentName admin = new android.content.ComponentName(app, AdminReceiver.class);
            int secondary = 0, running = 0;
            for (android.os.UserHandle uh : dpm.getSecondaryUsers(admin)) {
                secondary++;
                if (um.isUserRunning(uh)) running++;
            }
            GateTrace.ev(GateAlarmVerbs.roamed(secondary, running, false));
        } catch (Throwable t) {
            GateTrace.ev(GateAlarmVerbs.roamed(0, 0, true));
        }
    }
}
