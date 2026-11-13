package com.nowhere.chooser;

/** NWP-20261202-04: the always-on VPN keys of an in-session issue report. They turn the profile's captured record
 *  (nowhere-vpn), the pending pick (nowhere-vpn-pick) and the session user's live always_on_vpn_app /
 *  always_on_vpn_lockdown / nowhere_vpn_lockdown_pending settings into fixed codes, so a report shows whether the
 *  framework holds "Block connections without VPN" on while the captured choice is off. No value carries a package
 *  name or any input text: every value is a literal of this class. The record and the pick parse as roamd's
 *  vpn_choice reads them: the first app= line and the first lockdown= line, the lockdown 0 or 1 even when app= is
 *  empty. java.* only, so test-vpn-report-keys-java.sh compiles it alone. */
final class VpnReportKeys {
    private VpnReportKeys() {}

    /** What the caller passes for a file it could not read. No file holds a NUL, so it is never valid content. */
    static final String UNREADABLE = "\0unreadable";

    /** recordText / pickText: the file's text, null for no file, UNREADABLE for a read error. liveRead false: the
     *  three Secure reads threw, and liveApp / liveLock / livePend are not used. */
    static java.util.LinkedHashMap<String, String> keys(String recordText, String pickText,
            boolean liveRead, String liveApp, String liveLock, String livePend) {
        java.util.LinkedHashMap<String, String> m = new java.util.LinkedHashMap<>();
        String[] rec = parse(recordText);
        String[] pick = parse(pickText);
        m.put("vpn_record", rec[0]);
        if ("set".equals(rec[0])) m.put("vpn_record_block", "1".equals(rec[2]) ? "1" : "0");
        m.put("vpn_pick", pick[0]);
        if (!liveRead) {
            m.put("vpn_live", "unread");
            return m;
        }
        String live;
        if (absent(liveApp)) live = "none";
        else if ("set".equals(rec[0]) && liveApp.equals(rec[1])) live = "record";
        else live = "other";
        m.put("vpn_live", live);
        String block;
        if ("1".equals(liveLock)) block = "1";
        else if ("0".equals(liveLock)) block = "0";
        else if (liveLock == null) block = "unset";
        else block = "other";
        m.put("vpn_live_block", block);
        String pend;
        if (absent(livePend)) pend = "none";
        else if (!absent(liveApp) && livePend.equals(liveApp)) pend = "live";
        else pend = "other";
        m.put("vpn_live_pending", pend);
        return m;
    }

    /** {code, package, lockdown}: code none (no file), off (app= empty), set (a valid package), or unreadable (a read
     *  error, no app= line, a bad package or a lockdown other than 0 or 1). */
    private static String[] parse(String text) {
        if (text == null) return new String[] {"none", null, null};
        if (UNREADABLE.equals(text)) return new String[] {"unreadable", null, null};
        String app = null, lock = null;
        for (String line : text.split("\n", -1)) {
            if (app == null && line.startsWith("app=")) app = line.substring(4);
            if (lock == null && line.startsWith("lockdown=")) lock = line.substring(9);
        }
        if (app == null || !pkgOk(app)) return new String[] {"unreadable", null, null};
        if (!("0".equals(lock) || "1".equals(lock))) return new String[] {"unreadable", null, null};
        if (app.isEmpty()) return new String[] {"off", null, null};
        return new String[] {"set", app, lock};
    }

    /** A package name as roamd accepts one ([A-Za-z0-9._]); "" is none. The grammar of ProfileActivity.vpnPkgOk. */
    private static boolean pkgOk(String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!(c == '.' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) {
                return false;
            }
        }
        return true;
    }

    /** A Secure string that holds nothing: null, "" or the literal "null". */
    private static boolean absent(String s) {
        return s == null || s.isEmpty() || "null".equals(s);
    }
}
