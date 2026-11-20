package com.nowhere.chooser;

/**
 * NWP-20261210-21: the pure rule for the platform EmergencyInfo app's two editors in user 0.
 *
 * <p>Decision: {@code docs/product-decisions.md}, 2026-11-02, #12 -- Emergency information is read-only at the gate and
 * is edited only from owner mode, after the owner passphrase. The gate keeps {@code com.android.emergency} in its Lock
 * Task allowlist, so the emergency dialer still opens the read-only card ({@code .view.ViewInfoActivity}, which is
 * never listed here). The two editors are disabled whenever the gate locks the kiosk, and are back at their default
 * state only while owner mode stands the kiosk down ({@code ChooserActivity.applyEmergencyEditGate}).
 *
 * <p>Pure Java: the Android constants are literals, so a javac suite runs it off the build host
 * ({@code core/chooser/test-emergency-edit-gate-java.sh}).
 */
final class EmergencyEditGate {
    private EmergencyEditGate() {}

    /** The platform EmergencyInfo package. */
    static final String PKG = "com.android.emergency";

    /** Its two exported editors. The read-only view is not an editor and stays reachable. */
    static final String[] EDITORS = {
        PKG + ".edit.EditInfoActivity",
        PKG + ".edit.EditMedicalInfoActivity",
    };

    /** PackageManager.COMPONENT_ENABLED_STATE_DEFAULT. */
    static final int STATE_DEFAULT = 0;
    /** PackageManager.COMPONENT_ENABLED_STATE_DISABLED. */
    static final int STATE_DISABLED = 2;
    /** PackageManager.DONT_KILL_APP. */
    static final int DONT_KILL_APP = 1;

    /** The state the editors want: DEFAULT while owner mode has stood the kiosk down, DISABLED otherwise. */
    static int wanted(boolean ownerStoodDown) {
        return ownerStoodDown ? STATE_DEFAULT : STATE_DISABLED;
    }

    /** Write only on a transition, so a lock that finds the editors disabled leaves them (and the app) alone. */
    static boolean needsWrite(int current, int wanted) {
        return current != wanted;
    }

    /** Disabling kills an editor left open from owner mode; enabling keeps the app running. */
    static int flags(int wanted) {
        return wanted == STATE_DISABLED ? 0 : DONT_KILL_APP;
    }

    /** The one log line per apply: counts only, never a package, a user or a profile. */
    static String line(boolean owner, int changed, int kept, int failed) {
        return "emergency-edit state=" + (owner ? "owner" : "locked")
                + " changed=" + changed + " kept=" + kept + " failed=" + failed;
    }
}
