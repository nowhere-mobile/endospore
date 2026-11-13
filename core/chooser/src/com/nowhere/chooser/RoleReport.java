package com.nowhere.chooser;

import java.util.List;
import java.util.Map;

/** NWP-20261202-29: the default_roles key of every issue report (ProfileActivity.reportStatus, so the in-session and
 *  the scheduled report alike). For each default-app role it names the CLASS of the holder in the calling user, never
 *  the holder: the decision of 2026-11-09 ("the user's default-app choices roam, by the rules the SMS role already
 *  follows") reads the user-choosable roles on the device, and this makes that read and the holder after a sign-in and
 *  after the sweep checkable from a report. The value is built only from the words below, '=', ',' and '+', so it
 *  never holds a '.' and no package name can be in it. Pure, java.* only: core/chooser/tests/role-report runs it. */
final class RoleReport {
    private RoleReport() {}

    /** The role, then its word in the report, in report order. String literals: this class is java.* only. */
    static final String[][] ROLES = {
            {"android.app.role.BROWSER", "browser"},
            {"android.app.role.DIALER", "dialer"},
            {"android.app.role.SMS", "sms"},
            {"android.app.role.HOME", "home"},
            {"android.app.role.ASSISTANT", "assistant"},
            {"android.app.role.CALL_SCREENING", "callscreen"},
            {"android.app.role.CALL_REDIRECTION", "callredirect"},
            {"android.app.role.WALLET", "wallet"},
            {"android.app.role.NOTES", "notes"},
            {"android.app.role.EMERGENCY", "emergency"},
    };

    // ApplicationInfo.FLAG_SYSTEM and FLAG_UPDATED_SYSTEM_APP (public API values).
    static final int FLAG_SYSTEM = 0x1;
    static final int FLAG_UPDATED_SYSTEM_APP = 0x80;

    /** True for an app the image bundles, an updated one included. */
    static boolean isBundled(int flags) {
        return (flags & (FLAG_SYSTEM | FLAG_UPDATED_SYSTEM_APP)) != 0;
    }

    /** The class of a role's holders: unavailable (the image does not offer the role), unreadable (the holder list
     *  could not be read), none, or per holder chooser (self), bundled, user, or unknown (its flags could not be
     *  read); several holders join with '+' in list order. isSystem maps a holder to isBundled of its flags. */
    static String holderClass(boolean available, List<String> holders, String self, Map<String, Boolean> isSystem) {
        if (!available) return "unavailable";
        if (holders == null) return "unreadable";
        if (holders.isEmpty()) return "none";
        StringBuilder b = new StringBuilder();
        for (String h : holders) {
            if (b.length() > 0) b.append('+');
            b.append(one(h, self, isSystem));
        }
        return b.toString();
    }

    private static String one(String holder, String self, Map<String, Boolean> isSystem) {
        if (holder != null && holder.equals(self)) return "chooser";
        Boolean sys = holder == null || isSystem == null ? null : isSystem.get(holder);
        if (sys == null) return "unknown";
        if (sys) return "bundled";
        return "user";
    }

    /** "<word>=<class>" for every ROLES row, in order, joined with ','. A role missing from available (its read
     *  failed or was not reached) is unreadable. Null maps count as empty. Never throws. */
    static String format(Map<String, Boolean> available, Map<String, List<String>> holders, String self,
                         Map<String, Boolean> isSystem) {
        StringBuilder b = new StringBuilder();
        for (String[] r : ROLES) {
            if (b.length() > 0) b.append(',');
            Boolean av = available == null ? null : available.get(r[0]);
            String cls = av == null ? "unreadable"
                    : holderClass(av, holders == null ? null : holders.get(r[0]), self, isSystem);
            b.append(r[1]).append('=').append(cls);
        }
        return b.toString();
    }
}
