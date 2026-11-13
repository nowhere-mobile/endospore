package com.nowhere.chooser;

/**
 * NWP-20261202-05 (decided 2026-11-09, docs/product-decisions.md: "the user's default-app choices roam, by the rules
 * the SMS role already follows"): the pure rules of DefaultRoleRoam, java.* only, so a javac suite runs them alone
 * (core/chooser/tests/default-roles). Chester's report: after a roam the browser he set as default asked again whether
 * it or Vanadium should be the default.
 *
 * THE RULE SET IS SmsRoleRoam's (read its class comment): capture only the user's own observed change after this
 * session's apply; nothing inferred clears a recorded choice; a recorded app that is archived or absent takes its role
 * back when it lands. ONE generalisation: SMS's stand-in is Messaging, a constant; here the stand-in is the role's
 * BUNDLED holder (FLAG_SYSTEM or FLAG_UPDATED_SYSTEM_APP), which is what the role controller assigns as its default and
 * as its fallback. Never "the holder seen at apply": a default assigned after the apply, or the fallback after a
 * re-archive, would then read as a choice and overwrite the record. Flags that cannot be read are "unknown", and every
 * rule then changes nothing.
 *
 * THE RECORD is nowhere-roles in the chooser's CE files dir (beside nowhere-sms, so it seals), one `<role> <pkg>` line
 * per recorded role. THE MARKER is nowhere-roles-applied: `session=<user serial>`, then `<role> <state> <target>` per
 * role this session's apply ran for (state applied / deferred / fallback; target the recorded app or `-`). roamd's
 * `in` op removes the marker at every roam-in; the serial is the second lock.
 *
 * ROLES is the exclusive roles Settings > Default apps offers; DefaultRoleRoam keeps those RoleManager.isRoleAvailable
 * reports. NEVER HOME (ChooserActivity.ensureRoamedHomeRole pins it, #131), NEVER SMS (SmsRoleRoam owns it), NEVER
 * EMERGENCY.
 */
final class DefaultRoles {
    static final String[] ROLES = {
            "android.app.role.BROWSER",
            "android.app.role.DIALER",
            "android.app.role.ASSISTANT",
            "android.app.role.CALL_SCREENING",
            "android.app.role.CALL_REDIRECTION",
            "android.app.role.WALLET",
            "android.app.role.NOTES",
    };
    static final String RECORD = "nowhere-roles";
    static final String MARKER = "nowhere-roles-applied";
    static final int CAP = 4096;
    // ApplicationInfo.FLAG_SYSTEM and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP.
    static final int FLAG_SYSTEM = 1;
    static final int FLAG_UPDATED_SYSTEM_APP = 1 << 7;

    private DefaultRoles() {}

    static boolean isRole(String r) {
        if (r == null) return false;
        for (String x : ROLES) if (x.equals(r)) return true;
        return false;
    }

    /** The text after the last '.', e.g. BROWSER: the only role text a log line carries. */
    static String roleWord(String r) {
        return r == null ? "?" : r.substring(r.lastIndexOf('.') + 1);
    }

    /** A plausible Android package name: dotted, letters, digits, underscores, at most 255. */
    static boolean isPackageName(String s) {
        if (s == null || s.isEmpty() || s.length() > 255 || s.indexOf('.') < 0) return false;
        if (s.startsWith(".") || s.endsWith(".") || s.contains("..")) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!(c == '.' || c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
        }
        return true;
    }

    /** The holder's kind, FAIL-CLOSED: "unknown" when its flags could not be read, "bundled" for a system app (an
     *  updated one included), else "user". */
    static String kindOf(boolean readable, int flags) {
        if (!readable) return "unknown";
        return (flags & (FLAG_SYSTEM | FLAG_UPDATED_SYSTEM_APP)) != 0 ? "bundled" : "user";
    }

    /** SmsRoleRoam.recordUnknown's rule: the record exists within the cap and still could not be read. Then the
     *  sign-in applies nothing and writes no marker, so nothing is captured and the record is kept. */
    static boolean recordUnknown(boolean isFile, long length, String content) {
        return isFile && length <= CAP && content == null;
    }

    /** CAPTURE's read of the record: the parsed record, or null when it is UNKNOWN (recordUnknown's rule). On null
     *  capture writes nothing, so a failed read never replaces every other role's recorded choice with one line. */
    static java.util.Map<String, String> recordForCapture(boolean isFile, long length, String content) {
        return recordUnknown(isFile, length, content) ? null : parseRecord(content);
    }

    /** role -> package. A line that is not exactly `<role> <pkg>`, names a role not in ROLES or a non-package drops
     *  that line only; a repeated role keeps its first line. */
    static java.util.Map<String, String> parseRecord(String content) {
        java.util.Map<String, String> rec = new java.util.LinkedHashMap<>();
        if (content == null) return rec;
        for (String l : content.split("\n")) {
            String[] f = l.split(" ", -1);
            if (f.length != 2 || !isRole(f[0]) || !isPackageName(f[1])) continue;
            rec.putIfAbsent(f[0], f[1]);
        }
        return rec;
    }

    static String recordText(java.util.Map<String, String> rec) {
        StringBuilder b = new StringBuilder();
        for (String r : ROLES) {
            String p = rec.get(r);
            if (p != null) b.append(r).append(' ').append(p).append('\n');
        }
        return b.toString();
    }

    static String markerText(String session, java.util.Map<String, String[]> m) {
        StringBuilder b = new StringBuilder("session=").append(session).append('\n');
        for (String r : ROLES) {
            String[] e = m.get(r);
            if (e != null) b.append(r).append(' ').append(e[0]).append(' ').append(e[1]).append('\n');
        }
        return b.toString();
    }

    /** role -> {state, target} when the marker belongs to THIS session, else null. A malformed line of a role, or a
     *  role seen twice, drops that role: its apply "has not run", so nothing of it is captured. */
    static java.util.Map<String, String[]> parseMarker(String content, String session) {
        if (content == null || session == null || session.isEmpty()) return null;
        String s = null;
        java.util.Map<String, String[]> m = new java.util.LinkedHashMap<>();
        java.util.Set<String> bad = new java.util.HashSet<>();
        for (String l : content.split("\n")) {
            if (l.startsWith("session=")) { s = l.substring(8); continue; }
            String[] f = l.split(" ", -1);
            if (f.length == 0 || !isRole(f[0])) continue;
            boolean good = f.length == 3
                    && ("applied".equals(f[1]) || "deferred".equals(f[1]) || "fallback".equals(f[1]))
                    && ("-".equals(f[2]) || isPackageName(f[2]));
            if (!good || m.containsKey(f[0])) bad.add(f[0]);
            else m.put(f[0], new String[]{f[1], f[2]});
        }
        if (!session.equals(s)) return null;
        for (String r : bad) m.remove(r);
        return m;
    }

    /** What sign-in does with a role's record, as {the package to give the role or null to leave the holder, the
     *  state, the target}. presence is the recorded app's (SmsRoleRoam.presence). */
    static String[] signInPlan(String record, String presence, String self) {
        if (record == null || record.equals(self)) return new String[]{null, "applied", "-"};
        if ("installed".equals(presence) || "unknown".equals(presence)) return new String[]{record, "applied", record};
        return new String[]{null, "deferred", record};
    }

    /** What a capture records, or null for nothing. m is this role's marker entry {state, target}; kind is holder's.
     *  Only captureStep calls it: the marker guard is there. */
    static String captureValue(String[] m, String record, String holder, String kind, String self) {
        if (!isPackageName(holder) || holder.equals(self) || "unknown".equals(kind)) return null;
        if (m != null && ("deferred".equals(m[0]) || "fallback".equals(m[0])) && "bundled".equals(kind)) return null;
        if (holder.equals(record)) return null;
        if ("bundled".equals(kind) && record == null) return null;
        return holder;
    }

    /** What a capture does when a bundled app or nobody holds the role while the recorded app is not installed:
     *  "none" (presence unknown: change nothing), "deferred" (archived or absent: keep the record, the marker moves to
     *  deferred), or null to go on to captureValue. */
    static String standInState(String record, String holder, String kind, String self, String presence) {
        if (record == null || record.equals(self) || "installed".equals(presence)) return null;
        if (!"".equals(holder) && !"bundled".equals(kind)) return null;
        if (!"archived".equals(presence) && !"absent".equals(presence)) return "none";
        return "deferred";
    }

    /** THE ONE ENTRY the capture calls: null (nothing), {"defer", record} (the marker moves to deferred) or
     *  {"record", pkg} (record pkg, the marker moves to applied). */
    static String[] captureStep(String[] m, String record, String holder, String kind, String self, String presence) {
        if (m == null) return null;
        String st = standInState(record, holder, kind, self, presence);
        if ("none".equals(st)) return null;
        if ("deferred".equals(st)) {
            if (m != null && "deferred".equals(m[0]) && record.equals(m[1])) return null;
            return new String[]{"defer", record};
        }
        String v = captureValue(m, record, holder, kind, self);
        return v == null ? null : new String[]{"record", v};
    }

    /** Whether the recorded app, now landed, takes the role back: only from a bundled holder, nobody or the chooser;
     *  never from a user app, never through an unreadable list. */
    static boolean takeOver(java.util.List<String> holders, String kind, String self) {
        if (holders == null) return false;
        return holders.isEmpty() || holders.contains(self) || "bundled".equals(kind);
    }

    /** The app onMaterialised gives a role to, or null: only the recorded app this session waits for. */
    static String materialiseTarget(String[] m, String pkg, java.util.List<String> holders, String kind, String self) {
        if (m == null || "applied".equals(m[0]) || !m[1].equals(pkg)) return null;
        return takeOver(holders, kind, self) ? pkg : null;
    }

    /** One step of a TAKEOVER, re-read on every attempt: "held", "assign" or "leave". */
    static String takeoverStep(java.util.List<String> holders, String kind, String self, String want) {
        if (holders != null && holders.contains(want)) return "held";
        if (holders == null) return "leave";
        return holders.isEmpty() || holders.contains(self) || "bundled".equals(kind) ? "assign" : "leave";
    }

    /** One step of the SIGN-IN apply: the profile's choice, whoever holds the role, through an unreadable list too. */
    static String signInStep(java.util.List<String> holders, String want) {
        return holders != null && holders.contains(want) ? "held" : "assign";
    }

    static String summary(int applied, int deferred, int refused, int none) {
        return "default roles at sign-in: " + applied + " applied, " + deferred + " deferred, " + refused + " refused, "
                + none + " no record (NWP-20261202-05)";
    }
}
