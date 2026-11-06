package com.nowhere.chooser;

/**
 * The line Your apps shows under its intro: where an app's sign-in lives (NWP-20261114-27). Decided in
 * docs/product-decisions.md, #44 (dn-1104 #5, Q081, 2026-10-22): one line stating the NWP-20260830-03 rule, that an
 * app's Keystore keys roam with its data and there is no per-app switch. Phone text, not storefront copy, so no COPY
 * GATE. Pure, java.lang only, so {@code test-signin-line-java.sh} can compile it with its cases; the same suite pins
 * where {@code ProfileActivity.showYourApps} adds it.
 *
 * <p>Why it never says an app "stays signed in" (Q081, 2026-10-20): keys bound to the screen lock or a fingerprint
 * are not carried, and auth-bound keys are lost at every cold-lock resume (2026-10-04). An app that keeps its sign-in
 * in such a key comes back signed out, so a promise to stay signed in would be false for it. The line says only that
 * the sign-in travels with the app's data, and that signing out happens inside the app.
 */
final class SignInCopy {
    private SignInCopy() {}

    static final String YOUR_APPS_LINE =
            "An app's sign-in travels with its data. To sign out of an app, sign out inside it.";
}
