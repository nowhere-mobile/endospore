package com.nowhere.chooser;

import java.util.Locale;

/** Cases for SignInCopy (NWP-20261114-27, #44 / Q081). Exits 1 on any failure. */
public class SignInLineCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    public static void main(String[] args) {
        String line = SignInCopy.YOUR_APPS_LINE;
        // docs/product-decisions.md #44 (dn-1104 #5, Q081, 2026-10-22), byte for byte.
        check("YOUR_APPS_LINE is the #44 text",
                "An app's sign-in travels with its data. To sign out of an app, sign out inside it.".equals(line));
        if (line == null) line = "";
        // Q081: keys bound to the screen lock or a fingerprint are not carried, and auth-bound keys are lost at every
        // cold-lock resume, so the line never promises that an app stays signed in.
        String low = line.toLowerCase(Locale.ROOT);
        for (String banned : new String[] {"stay signed in", "stays signed in", "keep me signed in"}) {
            check("YOUR_APPS_LINE does not say \"" + banned + "\"", !low.contains(banned));
        }
        if (failures > 0) {
            System.err.println("  " + failures + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
