package com.nowhere.chooser;

/**
 * NWP-20261106-03: whether ProfileActivity honours the {@code auto} extra (java.lang only, so it runs under javac).
 *
 * <p>ProfileActivity is exported (the drawer's Profile entry), so any app in a session can start it with
 * {@code auto=true}. The L4 backstop (five wrong keyguard unlocks) starts the non-exported {@code .AutoLogoff}
 * alias instead; the extra is honoured only when the launch came through that alias.
 */
final class AutoLogoffGate {
    private AutoLogoffGate() {}

    static final String ALIAS = "com.nowhere.chooser.AutoLogoff";

    static boolean honoured(String launchedClass, boolean autoExtra) {
        return autoExtra && ALIAS.equals(launchedClass);
    }
}
