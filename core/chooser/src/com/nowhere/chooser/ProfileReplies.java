package com.nowhere.chooser;

/** What the Profile screen decides from a GET-SESSION-TYPE / GET-OFFLINE / SET-TZ reply, decided here so a daemon that
 *  does not answer is never rendered as an answer (docs/backlog.md, "every user-facing daemon read/write that times
 *  out fails SILENTLY"; NWP-20261025-09). sendDaemon returns "" on any failure. Pure Java, no android.* import:
 *  core/vendor-common/bin/test-profile-replies-java.sh compiles this file directly. */
final class ProfileReplies {
    private ProfileReplies() {}

    private static String trim(String s) {
        return s == null ? "" : s.trim();
    }

    /** The session type for the status line. No reply is UNKNOWN, never a definite state (NWP-20261006-23). An
     *  offline-started stored session reports LOCAL too (#49), so LOCAL cannot be told from a throwaway without the
     *  GET-OFFLINE answer: LOCAL with no "1" or "0" there is UNKNOWN, not "Throwaway" with a Save offer. */
    static String sessionType(String typeReply, String offlineReply) {
        String t = trim(typeReply);
        if (t.isEmpty()) return "UNKNOWN";
        String off = trim(offlineReply);
        if ("LOCAL".equals(t) && !"1".equals(off) && !"0".equals(off)) return "UNKNOWN";
        return t;
    }

    /** Whether the session was started offline: the daemon writes exactly "1" or "0", and only "1" is offline. */
    static boolean offline(String offlineReply) {
        return "1".equals(trim(offlineReply));
    }

    /** The toast after a time-zone pick. roamd's settz answers OK APPLIED / OK AUTO, ERR-TZ, the lane's
     *  ERR-WORKER-BUSY / ERR-TIMEOUT, and a dead socket gives "". Only the two OKs mean the zone is live; for any
     *  other reply the pref is saved and the gate applies the roamed tz= at the next sign-in, which
     *  writePrefetchMetered already words this way (NWP-20261007-08). A pref that was not saved says so. */
    static String tzToast(boolean saved, String reply, String olson) {
        if (!saved) return "Couldn't save the time zone. Try again.";
        String r = trim(reply);
        if (r.startsWith("OK APPLIED") || r.startsWith("OK AUTO")) {
            return (olson == null || olson.isEmpty()) ? "Time zone: Automatic" : "Time zone: " + olson;
        }
        return "Saved. It takes effect from your next sign-in.";
    }
}
