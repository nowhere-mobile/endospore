package com.nowhere.chooser;

import java.util.List;

/**
 * NWP-20261201-10: what a health notice offers, decided from the daemon's answers. The decision of record is
 * docs/product-decisions.md 2026-11-08 ("no LLM in the OS"): a check never repairs on its own and never signs a profile
 * out; the notice offers a Fix, and Sign out only when a check after the Fix still fires. Pure, so
 * core/chooser/test-health-notice-java.sh runs every row under javac.
 */
final class HealthNotice {
    private HealthNotice() {}

    static final String RULE_ID = "play-push-frozen";
    static final String TITLE = "Notifications may not arrive";
    static final String BODY = "Google Play services stopped receiving push messages, so app notifications may not arrive. Tap Fix to restart it.";
    static final String BODY_SIGN_OUT = "Restarting Play services did not help. Signing out and signing back in fixes it.";
    static final String FIX = "Fix";
    static final String SIGN_OUT = "Sign out";
    /** The screen the Sign out button opens: its own Sign out is the only thing that signs out. Never the AutoLogoff alias. */
    static final String SIGN_OUT_CLASS = "com.nowhere.chooser.ProfileActivity";
    /** A check this many seconds after the Fix that still fires shows the Fix did not help. */
    static final long RECHECK_AFTER_FIX_S = 60;

    static final int NONE = 0;             // cancel any notice
    static final int KEEP = 1;             // no usable answer: change nothing
    static final int FIX_ONLY = 2;
    static final int FIX_AND_SIGN_OUT = 3;

    /**
     * {@code healthLines}: GET-HEALTH's reply, one {@code <id> <VERDICT> <age_s>} per rule, or {@code NONE}.
     * {@code fixReply}: GET-HEALTH-FIX's reply, the seconds since this session's last Fix, or {@code NONE}.
     * This rule's own line decides first, so another rule's CLEAR cannot cancel this rule's notice. A daemon without
     * GET-HEALTH answers BLANK, which is not a usable line and reads as KEEP.
     */
    static int offer(List<String> healthLines, String fixReply) {
        if (healthLines == null) return KEEP;
        String verdict = null;
        long checkAge = -1;
        boolean cancelSeen = false;
        for (String raw : healthLines) {
            if (raw == null) continue;
            String line = raw.trim();
            if (line.equals("NONE")) { cancelSeen = true; continue; }
            String[] f = line.split("\\s+");
            if (f.length != 3 || !knownVerdict(f[1])) continue;
            long age;
            try { age = Long.parseLong(f[2]); } catch (NumberFormatException e) { continue; }
            if (f[0].equals(RULE_ID)) {
                if (verdict == null) { verdict = f[1]; checkAge = age; }
            } else if (f[1].equals("CLEAR") || f[1].equals("NOT-APPLICABLE")) {
                cancelSeen = true;
            }
        }
        if (verdict == null) return cancelSeen ? NONE : KEEP;
        if (verdict.equals("UNMEASURED")) return KEEP;
        if (!verdict.equals("FIRING")) return NONE;
        if (fixReply == null) return KEEP;
        String reply = fixReply.trim();
        if (reply.equals("NONE")) return FIX_ONLY;
        if (reply.isEmpty() || !reply.chars().allMatch(c -> c >= '0' && c <= '9')) return KEEP;
        long fixAge;
        try { fixAge = Long.parseLong(reply); } catch (NumberFormatException e) { return KEEP; }
        return checkAge >= 0 && fixAge - checkAge >= RECHECK_AFTER_FIX_S ? FIX_AND_SIGN_OUT : FIX_ONLY;
    }

    private static boolean knownVerdict(String v) {
        return v.equals("FIRING") || v.equals("CLEAR") || v.equals("NOT-APPLICABLE") || v.equals("UNMEASURED");
    }
}
