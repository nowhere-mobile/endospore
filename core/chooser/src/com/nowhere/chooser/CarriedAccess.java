package com.nowhere.chooser;

/** NWP-20261207-17 (#39, Q024; decision NWP-20261022-31): the Profile screen lists the accessibility services and the
 *  usage-access apps that travel with the profile, each with an off switch. Both roam exactly as the user set them,
 *  captured from the live state at seal (roamd's a11y_seal_capture reads enabled_accessibility_services; capturePerms
 *  records usage access only on MODE_ALLOWED), so turning one off in the live session is what stops it travelling.
 *
 *  PURE (java.* only), so test-carried-access-java.sh compiles and runs it under javac unchanged. ProfileActivity does
 *  the reads and the writes; this class only parses and edits the two texts.
 *
 *  The words below are DRAFTS awaiting Chester's mockup approval: ProfileActivity uses these constants, never a literal. */
final class CarriedAccess {
    private CarriedAccess() {}

    /** roamd's grammar for an enabled_accessibility_services entry `<pkg>/<cls>` (a11y_seal_capture). */
    static final java.util.regex.Pattern PKG_RE = java.util.regex.Pattern.compile("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+");
    static final java.util.regex.Pattern CLS_RE = java.util.regex.Pattern.compile("[A-Za-z0-9_.$]+");
    /** A framework target (color inversion, magnification ...): the platform's own, never an app's, never listed. */
    static final String FRAMEWORK_PKG = "com.android.server.accessibility";
    /** The exact nowhere-perms line capturePerms writes for an app with usage access: `<pkg>` + this. */
    static final String USAGE_SUFFIX = " appop:android:get_usage_stats";

    // DRAFT -- awaiting Chester's mockup approval (every constant below).
    static final String ROW_LABEL = "Accessibility and usage access";
    static final String SCREEN_TITLE = "Accessibility and usage access";
    static final String SCREEN_SUBTITLE = "what travels with this profile";
    static final String NOTE = "These travel with this profile to every phone it signs in on. Turn one off here to stop"
            + " it travelling.";
    static final String A11Y_TITLE = "Accessibility services";
    static final String USAGE_TITLE = "Usage access";
    static final String A11Y_EMPTY = "No accessibility service is on.";
    static final String USAGE_EMPTY = "No app has usage access.";
    static final String OFF_FAILED = "Couldn't turn this off. Try again, or turn it off in Android Settings.";
    static final String NOT_INSTALLED = "not on this phone yet";
    static final String LOADING = "Checking…";

    /** The app services of an enabled_accessibility_services value, in order, each once: entries `<pkg>/<cls>` in roamd's
     *  grammar whose package is not the framework's. A bare framework entry (magnification), a malformed entry and an
     *  empty field are dropped. null or "" -> empty. */
    static java.util.List<String> services(String enabledList) {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        if (enabledList == null) return new java.util.ArrayList<>(out);
        for (String e : enabledList.split(":", -1)) {
            if (e.isEmpty()) continue;
            int s = e.indexOf('/');
            if (s <= 0) continue;
            String p = e.substring(0, s), c = e.substring(s + 1);
            if (!PKG_RE.matcher(p).matches() || !CLS_RE.matcher(c).matches()) continue;
            if (FRAMEWORK_PKG.equals(p)) continue;
            out.add(e);
        }
        return new java.util.ArrayList<>(out);
    }

    /** True when the list still holds any `<pkg>/<cls>` entry in roamd's grammar, a framework target (color inversion)
     *  included: the off writes accessibility_enabled 0 only when not, as AOSP Settings' setAccessibilityServiceState
     *  does on an empty component set. Not services(): its display filter hides framework entries, and a framework
     *  component left in the list is still on. A bare entry with no '/' (magnification) is not a component. */
    static boolean anyComponent(String enabledList) {
        if (enabledList == null) return false;
        for (String e : enabledList.split(":", -1)) {
            int s = e.indexOf('/');
            if (s <= 0) continue;
            if (PKG_RE.matcher(e.substring(0, s)).matches() && CLS_RE.matcher(e.substring(s + 1)).matches()) return true;
        }
        return false;
    }

    /** The list minus every field equal to `component`; every other field (framework and malformed ones too) is kept in
     *  order. Empty fields are dropped. "" when nothing is left; null -> "". */
    static String without(String enabledList, String component) {
        if (enabledList == null) return "";
        java.util.ArrayList<String> kept = new java.util.ArrayList<>();
        for (String e : enabledList.split(":", -1)) {
            if (e.isEmpty()) continue;
            if (e.equals(component)) continue;
            kept.add(e);
        }
        return String.join(":", kept);
    }

    /** The packages of the lines exactly `<pkg> appop:android:get_usage_stats`, in order, each once. null -> empty. */
    static java.util.List<String> usageLines(java.util.List<String> permsLines) {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        if (permsLines == null) return new java.util.ArrayList<>(out);
        for (String ln : permsLines) {
            if (ln == null || !ln.endsWith(USAGE_SUFFIX)) continue;
            String p = ln.substring(0, ln.length() - USAGE_SUFFIX.length());
            if (!p.isEmpty() && p.indexOf(' ') < 0) out.add(p);
        }
        return new java.util.ArrayList<>(out);
    }

    /** Every line but `pkg`'s usage-access line, each other line unchanged (the same String) and in order. */
    static java.util.List<String> withoutUsage(java.util.List<String> permsLines, String pkg) {
        java.util.ArrayList<String> out = new java.util.ArrayList<>();
        if (permsLines == null) return out;
        for (String ln : permsLines) {
            if (!ln.equals(pkg + USAGE_SUFFIX)) out.add(ln);
        }
        return out;
    }

    /** The phone side of a usage-access off, so usageOff's order is testable off the device. */
    interface UsageOps {
        /** Delete the app's carried usage line from nowhere-perms; true when it is gone (or was never there). */
        boolean forget();
        /** The app's uid when it is installed NOW, else -1. */
        int uid();
        /** Set the live appop to MODE_IGNORED; true when a re-read is no longer MODE_ALLOWED. */
        boolean ignore(int uid);
    }

    /** Usage access off for one listed app, installed or not when the screen read it. First the carried line goes, so a
     *  restore that has not run yet finds nothing to grant; then the installation is checked AGAIN, because an install
     *  and its permission restore can complete while the screen is open, and an installed app's live grant is revoked.
     *  True only when the line is gone and, for an installed app, the live grant is no longer MODE_ALLOWED. */
    static boolean usageOff(UsageOps ops) {
        boolean forgot = ops.forget();
        int uid = ops.uid();
        if (uid < 0) return forgot;
        return ops.ignore(uid) && forgot;
    }

    /** SettingsText.read's text as lines (it ends each line with '\n'). null -> null. */
    static java.util.List<String> splitLines(String text) {
        if (text == null) return null;
        java.util.ArrayList<String> out = new java.util.ArrayList<>(java.util.Arrays.asList(text.split("\n", -1)));
        if (!out.isEmpty() && out.get(out.size() - 1).isEmpty()) out.remove(out.size() - 1);
        return out;
    }

    /** The file text of `lines`: each line followed by '\n'. An empty list -> "". */
    static String lines(java.util.List<String> lines) {
        StringBuilder sb = new StringBuilder();
        for (String ln : lines) sb.append(ln).append('\n');
        return sb.toString();
    }
}
