package com.nowhere.chooser;

/** NWP-20261105-06 (Q064, docs/product-decisions.md 2026-10-20): what a tap on the gate's telephony banner does. Pure
 *  (java.lang / java.util), so core/vendor-common/bin/test-notice-tap-java.sh compiles and runs it. Each notice is a
 *  telNotices entry: {line label, "call" | "message", count, "true" for a loss notice, its own line, "true" for the
 *  unassigned line's}. Several notices open the per-notice popup -- Lock Task disables the shade, so it is the only way
 *  to see them. One notice, whatever its running count, keeps the 2026-09-01 (e) rule: the unassigned line's leads to
 *  owner VERIFY (never past it) when an owner secret is set, and anything else is inert. */
final class NoticeTap {
    static final String POPUP = "popup", VERIFY = "verify", NONE = "none";

    private NoticeTap() {}

    static String action(java.util.List<String[]> notices, boolean ownerSecretSet) {
        if (notices == null || notices.isEmpty()) return NONE;
        if (notices.size() == 1) return inboxButton(notices.get(0), ownerSecretSet) ? VERIFY : NONE;
        return POPUP;
    }

    /** Whether the popup gives this entry the "Open owner inbox" route: the unassigned line's, and an owner secret to
     *  verify against (with none, owner mode would open the enrolment screen unauthenticated). */
    static boolean inboxButton(String[] notice, boolean ownerSecretSet) {
        return ownerSecretSet && notice != null && notice.length > 5 && "true".equals(notice[5]);
    }

    /** The popup's text: each notice's own line (field 4), in order -- what it would show alone, nothing more. */
    static java.util.List<String> lines(java.util.List<String[]> notices) {
        java.util.ArrayList<String> out = new java.util.ArrayList<>();
        if (notices == null) return out;
        for (String[] n : notices) out.add(n[4]);
        return out;
    }
}
