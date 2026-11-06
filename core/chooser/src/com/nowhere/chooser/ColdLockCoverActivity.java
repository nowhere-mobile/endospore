package com.nowhere.chooser;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Intent;
import android.os.Bundle;
import android.os.PowerManager;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * NWP-20261124-04: the "Locking…" cover the gate starts INSIDE the session's Android user when the owner unlocks after
 * an idle cold lock has committed (COLD-LOCK-ABORT answered COMMITTED, {@link ColdLockAbortReply}). Before it, the
 * owner unlocked into the session and used it for about 16 s until the switch to the gate landed.
 *
 * Chester, 2026-11-02: "go with option 1 for 1475". The gate does NOT switch here: the teardown must finish btpark and
 * the location, mobile-data and dev-toggle releases BEFORE the switch, because the switch to user 0 cycles the
 * Bluetooth stack for the new foreground user, and an early switch would park the gate's bonds (a resumed session would
 * come back unpaired). The daemon's own SWITCH does the switch, and the switch stops this activity, which finishes.
 *
 * Only that switch ends the cover ({@link ColdLockCoverRule}). Home, Recents or a tapped notification stop the cover
 * with the session still in front, so the cover raises itself again at once. It has no history flag and no timer:
 * either one would end the cover with the session still in front.
 *
 * It names no profile and no user (the #110 rule for surfaces that outlive a session) and reads no extras.
 */
public class ColdLockCoverActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        // The gate's one device-wide look, read from the Global setting the gate mirrors it to (as
        // MaterializingActivity does). A failed read is dark.
        GatePalette look = GatePalette.DARK;
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "cold-lock cover look not read, dark: " + t);
        }
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER);
        col.setBackgroundColor(look.bg);
        TextView tv = new TextView(this);
        tv.setText("Locking…");
        tv.setTextColor(look.accent);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        col.addView(tv, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        ProgressBar spin = new ProgressBar(this); // default = indeterminate spinner
        spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(look.accent));
        LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        sp.topMargin = Math.round(24 * getResources().getDisplayMetrics().density);
        col.addView(spin, sp);
        setContentView(col);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); // on until the switch, as the gate's cover
    }

    /** The lock is under way; there is nothing to go back to. */
    @Override public void onBackPressed() {}

    /** Home or Recents, with the session still in front: raise the cover over whatever the owner went to. */
    @Override protected void onUserLeaveHint() {
        super.onUserLeaveHint();
        afterStep(ColdLockCoverRule.afterStop(currentUser(), android.os.UserHandle.myUserId(), true));
    }

    /** The switch to the gate stops this user's activities: that is the cover's end. Any other stop raises it again. */
    @Override protected void onStop() {
        super.onStop();
        afterStep(ColdLockCoverRule.afterStop(currentUser(), android.os.UserHandle.myUserId(), interactive()));
    }

    private void afterStep(ColdLockCoverRule.Step step) {
        if (step == ColdLockCoverRule.Step.END) {
            finish();
        } else if (step == ColdLockCoverRule.Step.RAISE) {
            raise();
        }
    }

    /** singleTask: this brings the cover's task back to the front, it never makes a second cover. The chooser holds
     *  START_ACTIVITIES_FROM_BACKGROUND, so the background-start rules do not refuse a start from onStop. */
    private void raise() {
        try {
            startActivity(new Intent(this, ColdLockCoverActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_USER_ACTION
                            | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "cold-lock cover raise", t);
        }
    }

    /** The foreground user, or -1 when the read fails (the rule then keeps the cover). */
    private static int currentUser() {
        try { return ActivityManager.getCurrentUser(); } catch (Throwable t) { return -1; }
    }

    /** Whether the screen is on. A failed read says on, so the cover is raised. */
    private boolean interactive() {
        try {
            PowerManager pm = getSystemService(PowerManager.class);
            return pm == null || pm.isInteractive();
        } catch (Throwable t) {
            return true;
        }
    }
}
