package com.nowhere.chooser;

import java.util.List;

/** NWP-20261117-15: the GET-MEDIA-STATUS reply, one line per kind. mediad's writeProg (core/agent/media_server.go)
 *  writes up to four lines -- "LOADING <done> <total> <nfiles> <name>" while a fetch runs, "DAMAGED <nfiles> <name>"
 *  once a chunk is proven corrupt, "INCOMPLETE <napps> <app>" after a short #media restore, and (NWP-20261201-14)
 *  "RESTORING <done B> <total B> <files left>" while the after-gate #media restore has files left, numbers only --
 *  and the daemon relays them whole, or "IDLE". route() returns {loading, damaged, incomplete, restoring}: the first
 *  line of each kind, trimmed and whole (a name may hold spaces), null when absent. Other lines are ignored and the
 *  order does not matter. restoring() validates a RESTORING line and restoringPermille() scales its bytes to the
 *  notification's 0-1000 bar (NWP-20261202-28). java.* only, so
 *  test-media-status-java.sh compiles it with its cases. */
final class MediaStatus {
    private MediaStatus() {}

    /** The media notification's title while the after-gate restore runs (docs/media-after-gate.md §10 O3). */
    static final String RESTORING_TITLE = "Restoring photos and files";

    static String[] route(List<String> lines) {
        String[] out = new String[4];
        if (lines == null) return out;
        for (String raw : lines) {
            if (raw == null) continue;
            String line = raw.trim();
            int slot = line.startsWith("LOADING") ? 0
                    : line.startsWith("DAMAGED") ? 1
                    : line.startsWith("INCOMPLETE") ? 2
                    : line.startsWith("RESTORING") ? 3 : -1;
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

    /** The determinate bar of a parsed RESTORING line: done/total scaled to 0-1000. A total of 0 is a known size (the
     *  files left are empty), so it is 0, never the indeterminate bar. Computed in double so done * 1000 cannot
     *  overflow a long. */
    static int restoringPermille(long done, long total) {
        if (total <= 0 || done <= 0) return 0;
        if (done >= total) return 1000;
        return (int) ((double) done * 1000 / total);
    }
}
