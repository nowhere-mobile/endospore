package com.nowhere.chooser;

import java.util.List;

/** NWP-20261117-15: the GET-MEDIA-STATUS reply, one line per kind. mediad's writeProg (core/agent/media_server.go)
 *  writes up to five lines -- "LOADING <done> <total> <nfiles> <name>" while a fetch runs, "DAMAGED <nfiles> <name>"
 *  once a chunk is proven corrupt, "INCOMPLETE <napps> <app>" after a short #media restore, (NWP-20261201-14)
 *  "RESTORING <done B> <total B> <files left>" while the after-gate #media restore has files left, numbers only, and
 *  (NWP-20261207-11) "RESTORE-WAITING", the token alone, after it while that restore is parked on the network --
 *  and the daemon relays them whole, or "IDLE". route() returns {loading, damaged, incomplete, restoring, waiting}:
 *  the first line of each kind, trimmed and whole (a name may hold spaces), null when absent; the waiting slot takes
 *  only a line that equals RESTORE-WAITING. Other lines are ignored and the order does not matter. restoring()
 *  validates a RESTORING line and restoringPermille() scales its bytes to the notification's 0-1000 bar
 *  (NWP-20261202-28); restoreWaiting() says whether the notification shows WAITING_BODY. java.* only, so
 *  test-media-status-java.sh compiles it with its cases. */
final class MediaStatus {
    private MediaStatus() {}

    /** The media notification's title while the after-gate restore runs (docs/media-after-gate.md §10 O3). */
    static final String RESTORING_TITLE = "Restoring photos and files";

    /** The media notification's body while the after-gate restore is parked on the network (§10 O3, NWP-20261207-11). */
    static final String WAITING_BODY = "Waiting for a network";

    static String[] route(List<String> lines) {
        String[] out = new String[5];
        if (lines == null) return out;
        for (String raw : lines) {
            if (raw == null) continue;
            String line = raw.trim();
            int slot = line.startsWith("LOADING") ? 0
                    : line.startsWith("DAMAGED") ? 1
                    : line.startsWith("INCOMPLETE") ? 2
                    : line.startsWith("RESTORING") ? 3
                    : line.equals("RESTORE-WAITING") ? 4 : -1;
            if (slot >= 0 && out[slot] == null) out[slot] = line;
        }
        return out;
    }

    /** "RESTORING <done> <total> <left>" -> {done, total, left}: three non-negative integers, left > 0 and
     *  done <= total. Anything else (null, a missing or extra field, a sign, a non-number, left 0) -> null. */
    static long[] restoring(String line) {
        if (line == null) return null;
        String[] f = line.trim().split("\\s+");
        if (f.length != 4 || !f[0].equals("RESTORING")) return null;
        long[] v = new long[3];
        for (int i = 0; i < 3; i++) {
            if (!f[i + 1].matches("[0-9]+")) return null;
            try {
                v[i] = Long.parseLong(f[i + 1]);
            } catch (NumberFormatException e) {
                return null; // overflow
            }
        }
        if (v[2] <= 0) return null; // left 0: the set is empty, nothing to show
        if (v[0] > v[1]) return null; // done > total: a broken line
        return v;
    }

    /** NWP-20261207-11: whether the after-gate restore is parked on the network -- a valid RESTORING line in slot 3
     *  and the RESTORE-WAITING line in slot 4. A lone RESTORE-WAITING line is not a restore. */
    static boolean restoreWaiting(String[] routed) {
        return routed != null && routed.length > 4 && restoring(routed[3]) != null && routed[4] != null;
    }

    /** The determinate bar of a parsed RESTORING line: done/total scaled to 0-1000. A total of 0 is a known size (the
     *  files left are empty), so it is 0, never the indeterminate bar. Computed in double so done * 1000 cannot
     *  overflow a long. */
    static int restoringPermille(long done, long total) {
        if (total <= 0 || done <= 0) return 0;
        if (done >= total) return 1000;
        return (int) ((double) done * 1000 / total);
    }

    /** NWP-20261114-34: the GET-MEDIA-LANDED reply as a counter, or null when it is not one (an empty or failed read,
     *  a non-number, a negative). mediad's media.landed counts the background runs that made files local since its
     *  start; the daemon answers "0" when there is none. */
    static String landed(String reply) {
        if (reply == null) return null;
        String v = reply.trim();
        if (v.isEmpty() || v.length() > 9) return null;
        for (int i = 0; i < v.length(); i++) {
            char c = v.charAt(i);
            if (c < '0' || c > '9') return null;
        }
        return String.valueOf(Integer.parseInt(v)); // "007" and "7" are one count
    }

    /** NWP-20261114-34: whether the gate starts the session's media rescan, given the count it last saw for the session
     *  (seen, "0" at the session's first tick, since each mediad start counts from 0) and this tick's reply. A changed,
     *  non-zero count is new landed files; "0" after a non-zero count is a mediad restart, which landed nothing yet; a
     *  read that is not a count changes nothing. A changed count, not a larger one: a restarted mediad counts from 1. */
    static boolean rescanAfterLanding(String seen, String reply) {
        String now = landed(reply);
        return now != null && !now.equals("0") && !now.equals(seen);
    }
}
