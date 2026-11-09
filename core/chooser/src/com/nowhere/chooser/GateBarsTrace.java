package com.nowhere.chooser;

/**
 * NWP-20261128-35: whether the gate traces its window's light-bar appearance, and the value it sends.
 *
 * <p>WHY THIS CLASS EXISTS. On 2026-10-29 on lynx, with the gate in light mode, the status-bar icons were drawn
 * light on the light page and were nearly invisible, though {@code ChooserActivity.applyGateBars} asks for dark
 * ones. Nothing read the appearance back, and a user build gives no logcat. So a report could not say whether
 * the window lost the request (a chooser fix) or SystemUI ignored it (a platform question). At the first focus
 * of each gate start, in light mode, the gate now sends {@code bars-light fields=<n>} to gate.log, which every
 * gate report carries.
 *
 * <p>Pure: no android import, so a javac suite runs it off the build host. The value is two bits of the
 * window's appearance, a property of the gate, never of a session.
 */
final class GateBarsTrace {
    private GateBarsTrace() {}

    /** WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS: the status-bar icons are dark. */
    static final int LIGHT_STATUS = 8;
    /** WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS: the navigation-bar icons are dark. */
    static final int LIGHT_NAV = 16;

    /** Trace only a light palette, once per activity instance, on API 30+ (getSystemBarsAppearance). */
    static boolean shouldTrace(boolean lightBars, boolean alreadyTraced, int sdk) {
        return lightBars && !alreadyTraced && sdk >= 30;
    }

    /** The two dark-icon bits the window holds: 24 both, 8 or 16 one, 0 none. Nothing else of the mask. */
    static int value(int appearance) {
        return appearance & (LIGHT_STATUS | LIGHT_NAV);
    }
}
