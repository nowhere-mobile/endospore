package com.nowhere.chooser;

import java.util.List;

/** NWP-20261117-15: the GET-MEDIA-STATUS reply, one line per kind. mediad's writeProg (core/agent/media_server.go)
 *  writes up to three lines -- "LOADING <done> <total> <nfiles> <name>" while a fetch runs, "DAMAGED <nfiles> <name>"
 *  once a chunk is proven corrupt, "INCOMPLETE <napps> <app>" after a short #media restore -- and the daemon relays
 *  them whole, or "IDLE". route() returns {loading, damaged, incomplete}: the first line of each kind, trimmed and
 *  whole (a name may hold spaces), null when absent. Other lines are ignored and the order does not matter.
 *  java.* only, so test-media-status-java.sh compiles it with its cases. */
final class MediaStatus {
    private MediaStatus() {}

    static String[] route(List<String> lines) {
        String[] out = new String[3];
        if (lines == null) return out;
        for (String raw : lines) {
            if (raw == null) continue;
            String line = raw.trim();
            int slot = line.startsWith("LOADING") ? 0
                    : line.startsWith("DAMAGED") ? 1
                    : line.startsWith("INCOMPLETE") ? 2 : -1;
            if (slot >= 0 && out[slot] == null) out[slot] = line;
        }
        return out;
    }
}
