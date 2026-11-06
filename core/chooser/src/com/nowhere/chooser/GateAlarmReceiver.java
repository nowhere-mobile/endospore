package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * #151 (a phone that can't wake you): the user-0 gate alarm fired -> launch the full-screen ring. The alarm was
 * scheduled by {@link ChooserActivity} from a logged-off session's relayed next-alarm time (a stopped roamed
 * user's own alarms don't fire, so the phone would otherwise never ring). Manifest-registered so it wakes even
 * if the chooser process had been reaped (the chooser is android:persistent, so it normally hasn't).
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
        } catch (Throwable t) {
            GateTrace.ev("fired-err");
            android.util.Log.w("NowhereChooser", "gate alarm launch", t);
        }
    }
}
