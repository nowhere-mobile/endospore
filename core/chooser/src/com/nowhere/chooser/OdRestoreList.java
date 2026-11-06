package com.nowhere.chooser;

import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** NWP-20261128-16 (h53 #1, docs/product-decisions.md 2026-11-02): the Auto sweep's restore-only retries go to the
 *  daemon as ONE RESTORE-ODDATA request per chunk, so the shared reads (the `pm list packages -3` grant read) are done
 *  once per chunk, not once per app. The daemon side is NWP-20261125-08 (core/agent app_code.go handleRestoreOdData):
 *  a list of 2..16 names answers NONE, OK LOCAL or ERR-PKG as one line with no package lead, or one "<pkg> <reply>"
 *  line per package in request order, then "END <n>"; a sign-out answers "<pkg> STOPPED" for each package not run.
 *  A list of one is never built: the one-name form answers one line with no lead (UnarchiveService.restoreOnlyLocked).
 *  Pure java.util, so test-od-restore-list-java.sh compiles it alone. */
final class OdRestoreList {
    private OdRestoreList() {}

    /** Below the daemon's odRestoreMaxList (16): the sweep holds MAT_LOCK for one chunk, so a tap waits behind at most
     *  this many restores. */
    static final int CHUNK = 8;

    /** The one-line replies with no package lead: each applies to every package sent. Not Set.of: minSdk is 24. */
    private static final Set<String> WHOLE = new HashSet<>(Arrays.asList("NONE", "OK LOCAL", "ERR-PKG"));
    private static final String STOPPED = "STOPPED";

    /** "RESTORE-ODDATA\n<pkg> <pkg> ...\n" for 2..CHUNK names. */
    static String request(List<String> pkgs) {
        if (pkgs.size() < 2 || pkgs.size() > CHUNK)
            throw new IllegalArgumentException("a RESTORE-ODDATA list holds 2.." + CHUNK + " names, not " + pkgs.size());
        return "RESTORE-ODDATA\n" + String.join(" ", pkgs) + "\n";
    }

    /** Every sent package maps to its reply text ("OK <pkg>", "OK NOSRC", "ERR-...", or a whole-list line), or to null
     *  when it has none: a cut reply (no line for it), STOPPED, or a connect that failed (no lines). null is "no reply":
     *  the caller writes no marker, so the next sweep retries the restore. END, a line naming a package not sent and a
     *  line with no space are ignored; a package's first line wins. */
    static Map<String, String> parse(List<String> lines, List<String> sent) {
        Map<String, String> m = new LinkedHashMap<>();
        for (String p : sent) m.put(p, null);
        if (lines.size() == 1 && WHOLE.contains(lines.get(0).trim())) {
            for (String p : sent) m.put(p, lines.get(0).trim());
            return m;
        }
        for (String line : lines) {
            int sp = line.indexOf(' ');
            if (sp <= 0) continue;
            String head = line.substring(0, sp), rest = line.substring(sp + 1).trim();
            if (!m.containsKey(head) || m.get(head) != null || rest.isEmpty()) continue;
            if (rest.equals(STOPPED)) continue;
            m.put(head, rest);
        }
        return m;
    }
}
