package com.nowhere.chooser;

/**
 * The device owner's keyguard-disabled flags on user 0, the gate (NWP-20261114-12; docs/product-decisions.md,
 * 2026-10-24, "biometrics cannot be enrolled under the device owner, and Owner settings say that what is changed
 * there persists").
 *
 * <p>ChooserActivity.onCreate ORs DevicePolicyManager.KEYGUARD_DISABLE_BIOMETRICS into the flags already set, so it
 * keeps any flag another call set, and writes only when a mask bit is missing, so a re-run changes nothing.
 *
 * <p>Pure java.lang: core/chooser/test-owner-biometrics.sh compiles this file directly.
 */
final class OwnerKeyguard {
    private OwnerKeyguard() {}

    /** The flags to write: the ones already set, plus every bit of the biometrics mask. */
    static int withBiometricsOff(int current, int biometricsMask) {
        return current | biometricsMask;
    }

    /** True when a bit of the biometrics mask is not set yet. */
    static boolean needsWrite(int current, int biometricsMask) {
        return (current & biometricsMask) != biometricsMask;
    }
}
