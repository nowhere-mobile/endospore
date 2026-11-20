package com.nowhere.chooser;

import android.app.admin.DeviceAdminReceiver;
import android.app.admin.DevicePolicyManager;
import android.content.Context;
import android.content.Intent;
import android.os.UserHandle;

/**
 * Device-admin receiver. Lets the chooser be the DEVICE OWNER (kiosk / Lock Task) and PROFILE OWNER of each
 * roamed user. It also carries the L4 failed-attempt backstop: too many wrong unlocks of a roamed session
 * auto-logs-off (seal + reap -> blank gate), bounding a brute-force of the session keyguard. The start clears the
 * task, and nothing starts while a sign-out is already under way (NWP-20261208-02).
 */
public class AdminReceiver extends DeviceAdminReceiver {
    // Wrong unlocks of a roamed session before auto-logoff. NOT setMaximumFailedPasswordsForWipe (that
    // factory-resets the device); we keep the device's provisioning/store config and just revert to the
    // amnesiac gate.
    private static final int MAX_FAILED = 5;

    @Override
    public void onPasswordFailed(Context context, Intent intent, UserHandle user) {
        try {
            DevicePolicyManager dpm =
                    (DevicePolicyManager) context.getSystemService(Context.DEVICE_POLICY_SERVICE);
            int fails = dpm.getCurrentFailedPasswordAttempts();
            android.util.Log.i("NowhereChooser", "L4 onPasswordFailed attempts=" + fails + " user=" + user);
            // NWP-20261208-02: the start clears the task, so it always reaches onCreate -- the path proven with Home in
            // front. Delivered to a stopped Profile screen on top (START_DELIVERED_TO_TOP), it did not sign out on lynx
            // 2026102901. The clear finishes only this user's chooser-affinity task, which the sign-out reaps anyway.
            // It would also destroy a screen that is already ending the session, so nothing starts while one is: the
            // sign-out flag is only READ here (doLogoffImpl raises it; a raise here that never reached onCreate would
            // stop the Auto sweep and refuse every later L4 for the session).
            boolean underWay = SignOutGate.begun() || ProfileActivity.anySignOutUnderWay();
            if (AutoLogoffGate.shouldStart(fails, MAX_FAILED, underWay)) {
                // The non-exported .AutoLogoff alias of ProfileActivity: ProfileActivity itself is exported and
                // ignores `auto` unless it arrives through the alias (NWP-20261106-03).
                context.startActivity(new Intent()
                        .setClassName(context, "com.nowhere.chooser.AutoLogoff")
                        .putExtra("auto", true)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK));
                android.util.Log.i("NowhereChooser", "L4 auto sign-out started (new instance, task cleared)");
            } else if (fails >= MAX_FAILED) {
                android.util.Log.i("NowhereChooser", "L4 auto sign-out already under way: not restarted");
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "L4 onPasswordFailed", t);
        }
    }
}
