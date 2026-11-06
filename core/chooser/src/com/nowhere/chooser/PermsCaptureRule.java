package com.nowhere.chooser;

/**
 * NWP-20261112-07 (Q061) -- which apps a MID-SESSION capturePerms must leave alone.
 *
 * A deferred app (on-demand or auto) installed this session gets its carried permission lines put back by roamd's
 * odrestore, whose grant_perms_for reads them from files/nowhere-perms. That restore lands after the install: the tap
 * materialise installs the APK (installApks), writes nowhere-od-materialised, and only then sends RESTORE-ODDATA; an
 * install by another installer over the placeholder reaches the same restore through the install-heal. A capture made
 * inside that window would find the app installed, record its fresh, ungranted state over the carried lines, and the
 * restore would then grant nothing: every permission the app carried would be lost at its first tap. So a mid-session
 * capture keeps such an app's lines verbatim until UnarchiveService.markOdRestored records the restore (the materialise
 * and the install-heal both write it); after that its live state is authoritative again.
 *
 * The sign-out capture (midSession false) is unchanged: the session is over and live state is authoritative. A
 * keep-INSTALLED app is granted by the login's GRANT-PERMS, before any mid-session capture can run, so it is never
 * held. The two strings equal ProfileActivity.MODE_ONDEMAND and MODE_AUTO; they are literals so this class stays pure
 * java.* and compiles alone in its suite (core/vendor-common/bin/test-perms-capture-receiver.sh).
 */
final class PermsCaptureRule {
    private PermsCaptureRule() {}

    /** True when a capture must re-emit pkg's carried lines verbatim instead of reading its live state. */
    static boolean keepCarried(boolean midSession, String mode, boolean restored) {
        return midSession && ("ondemand".equals(mode) || "auto".equals(mode)) && !restored;
    }

    /** NWP-20261123-11: files/nowhere-perms grouped by package -- the old record capturePerms carries forward. NULL for
     *  null text (SettingsText.read's "exists but could not be read whole"): unknown, never "nothing carried", so the
     *  caller writes nothing. A line's package is the text before its first space; a line with no space, or one that
     *  starts with a space, is skipped; lines keep their order within a package. */
    static java.util.HashMap<String, java.util.ArrayList<String>> oldLinesByPkg(String text) {
        if (text == null) return null;
        java.util.HashMap<String, java.util.ArrayList<String>> m = new java.util.HashMap<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader(text))) {
            String ln;
            while ((ln = br.readLine()) != null) {
                int sp = ln.indexOf(' ');
                if (sp <= 0) continue;
                m.computeIfAbsent(ln.substring(0, sp), k -> new java.util.ArrayList<>()).add(ln);
            }
        } catch (java.io.IOException unreachable) { // a StringReader does not throw
        }
        return m;
    }
}
