package com.nowhere.chooser;

/** NWP-20261205-09: when the gate honours its headless sign-in Intent extras (`profile`, `pass`).
 *
 *  The test harness drives a login with `am start --es profile <name> --es pass <passphrase>`, and ChooserActivity's
 *  onCreate and onNewIntent prefill and submit from those extras. On a user build that hook let any user-0 caller sign
 *  in, and `am start --es pass ...` put the passphrase on am's command line, which other processes can read while am
 *  runs. DECIDED 2026-11-04 (h57 #8, docs/product-decisions.md "nine answers to harvest 57 -- every recommendation
 *  accepted", option 1): the gate honours the extras only when `ro.debuggable` is 1.
 *
 *  `debuggable` is the caller's read of `ro.debuggable`. Only an exact "1" counts: a denied or empty read (the caller
 *  passes "0" as its default), "0", "true" or any other text is not debuggable, so the hook fails closed.
 *  Pure (java.* only) so test-harness-extras-java.sh runs it under javac. */
final class HarnessExtras {
    private HarnessExtras() {}

    static boolean honour(String debuggable, String profile, String pass) {
        return "1".equals(debuggable) && profile != null && pass != null;
    }
}
