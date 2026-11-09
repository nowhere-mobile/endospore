package com.nowhere.chooser;

/** NWP-20261129-13 (h55 #4, docs/product-decisions.md, 2026-11-03): the list of packages one sign-in could not park.
 *  Writer: roamd's reap_stale_ondemand, as .appcode/od-unparked beside the manifest. Reader:
 *  ChooserActivity.installRoamedAppCode, which raises no placeholder for a listed package.
 *  The file holds one package name per line. A blank line, or a line that is not a package name, is ignored.
 *  The name test is the one a reaped name can pass: AppCodeManifest's stricter rule would drop `1a.b`, which the reap
 *  lists, and a dropped name is raised. A kept junk name matches no manifest row, so it does no harm.
 *  Pure, java.util only, so test-od-unparked-java.sh compiles it alone. */
final class OdUnparked {
    private OdUnparked() {}

    static java.util.Set<String> parse(String text) {
        java.util.Set<String> out = new java.util.HashSet<>();
        if (text == null) return out;
        for (String line : text.split("\n", -1)) {
            String name = line.endsWith("\r") ? line.substring(0, line.length() - 1) : line;
            if (isPackageName(name)) out.add(name);
        }
        return out;
    }

    /** SmsRoleRoam.isPackageName's rule, copied: that class needs Android types and this one must not. */
    private static boolean isPackageName(String s) {
        if (s == null || s.isEmpty() || s.length() > 255 || s.indexOf('.') < 0) return false;
        if (s.startsWith(".") || s.endsWith(".") || s.contains("..")) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!(c == '.' || c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
        }
        return true;
    }
}
