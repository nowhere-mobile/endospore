package com.nowhere.chooser;

/**
 * UnarchiveReceiver's verdict (NWP-20261104-20), lifted out of the receiver so a JDK can run it: whether an intent is
 * the system's unarchive request. The receiver is exported, so any app in the session may target it explicitly with
 * any action; the receiver reads the intent, this decides. java.* only. The package grammar is
 * {@code core/agent/pkgname.go validPkgName}'s.
 */
final class UnarchiveGate {
    private UnarchiveGate() {}

    /** {@code Intent.ACTION_UNARCHIVE_PACKAGE}, spelt out so this compiles without the Android SDK. */
    static final String ACTION = "android.intent.action.UNARCHIVE_PACKAGE";

    /** True iff {@code action} is the system's unarchive action and {@code pkg} is an Android package name. */
    static boolean accept(String action, String pkg) {
        return ACTION.equals(action) && validPkg(pkg);
    }

    /** ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$, at most 255 chars. */
    private static boolean validPkg(String s) {
        if (s == null || s.isEmpty() || s.length() > 255) return false;
        int segs = 0;
        boolean start = true;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
            if (c == '.') {
                if (start) return false;
                start = true;
            } else if (letter) {
                if (start) segs++;
                start = false;
            } else if ((c >= '0' && c <= '9') || c == '_') {
                if (start) return false;
            } else {
                return false;
            }
        }
        return !start && segs >= 2;
    }
}
