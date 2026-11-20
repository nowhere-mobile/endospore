package com.nowhere.chooser;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.function.Predicate;

/** NWP-20261204-14: the od_half value of the session report. Q056 (docs/product-decisions.md, 2026-10-20) measures a
 *  half-materialised app before any per-app Repair is built; this is the reading that measurement takes, so it can be
 *  read off any filed session report instead of a hand-read of logcat. It builds no repair and no retry.
 *
 *  The value is "auto=<a> ondemand=<o> ondemand_ours=<m> notready=<n>":
 *  - auto: the profile's Auto apps with code and no confirmed restore (no nowhere-od-restored line). The sweep's
 *    restore-only retry covers exactly these, so this is the state the next sweep heals: the control value.
 *  - ondemand: the profile's on-demand apps with code and no confirmed restore. The launcher opens such an app
 *    directly and the sweep never retries it: the unhandled half state.
 *  - ondemand_ours: those ondemand ones also in nowhere-od-materialised: our own install landed, its restore did not.
 *  - notready: the restore-only replies this chooser process saw answer ERR-NOTREADY (a data folder the app does not
 *    own), passed through from UnarchiveService.RESTORE_NOTREADY.
 *
 *  Counts only, never a name: the value is built from the four fixed words and digits. A gate report never calls
 *  reportStatus, so only a session report carries it. Pure: java.* only, so the suite compiles it alone under javac.
 *  The keep-set lines are parsed exactly as ProfileActivity.keepSetByMode does, and MODE_AUTO / MODE_ONDEMAND below
 *  equal ProfileActivity's (test-od-half-states-java.sh pins both). */
final class OdHalfStates {
    private OdHalfStates() {}

    static final String MODE_AUTO = "auto";
    static final String MODE_ONDEMAND = "ondemand";

    /** keepLines: the raw lines of the profile's nowhere-appkeep. code / restored: hasInstalledCode / odRestored;
     *  restored is asked only for a package with code. materialised: the nowhere-od-materialised names (null = none). */
    static String reportValue(Iterable<String> keepLines, Predicate<String> code, Predicate<String> restored,
                              Set<String> materialised, int notready) {
        Set<String> auto = new LinkedHashSet<>();
        Set<String> ondemand = new LinkedHashSet<>();
        if (keepLines != null) {
            for (String raw : keepLines) {
                if (raw == null) continue;
                String line = raw.trim();
                if (line.isEmpty()) continue;
                // ALL tabs, as keepSetByMode: a 3rd `group:<name>` token must not corrupt the mode read.
                String[] f = line.split("\t", -1);
                if (f.length < 2) continue; // bare pkg == installed, neither on-demand nor auto
                String pkg = f[0].trim();
                if (pkg.isEmpty()) continue;
                String mode = f[1].trim();
                if (MODE_AUTO.equals(mode)) auto.add(pkg);
                else if (MODE_ONDEMAND.equals(mode)) ondemand.add(pkg);
            }
        }
        int a = 0, o = 0, m = 0;
        for (String pkg : auto) {
            if (half(pkg, code, restored)) a++;
        }
        for (String pkg : ondemand) {
            if (!half(pkg, code, restored)) continue;
            o++;
            if (materialised != null && materialised.contains(pkg)) m++;
        }
        return "auto=" + a + " ondemand=" + o + " ondemand_ours=" + m + " notready=" + notready;
    }

    /** Code and no confirmed restore. restored is read only when the app has code. */
    private static boolean half(String pkg, Predicate<String> code, Predicate<String> restored) {
        return code.test(pkg) && !restored.test(pkg);
    }
}
