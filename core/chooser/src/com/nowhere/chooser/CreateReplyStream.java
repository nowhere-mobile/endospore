package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.IOException;
import java.util.function.IntConsumer;

/** NWP-20261120-06 (Q167, docs/product-decisions.md 2026-10-20): the reader of a CREATE / CREATE-CODE reply from the
 *  login daemon's socket. The daemon streams "PROGRESS create <done> <total>" lines before the verdict -- the start,
 *  the purge's ticks when the name was deleted before, and the end of a create that succeeded -- so the gate's bar
 *  moves while the purge runs. A fresh create streams the same first and last lines, so the bar gives nothing away.
 *  Pure JDK, so a javac suite (test-create-progress-java.sh) runs it off the build host. */
final class CreateReplyStream {
    static final String PREFIX = "PROGRESS create ";

    private CreateReplyStream() {}

    /** Reads a CREATE / CREATE-CODE reply: each "PROGRESS create <d> <t>" line calls onPct with its percentage
     *  ({@link #pct}); any other PROGRESS line is skipped. Returns the first other non-empty line, trimmed, or ""
     *  on EOF or an IOException, as a failed one-line read does. A daemon that streams nothing gives its verdict. */
    static String verdict(BufferedReader br, IntConsumer onPct) {
        try {
            String line;
            while ((line = br.readLine()) != null) {
                line = line.trim();
                if (line.startsWith(PREFIX)) {
                    int p = pct(line);
                    if (p >= 0) onPct.accept(p);
                } else if (line.startsWith("PROGRESS ")) {
                    continue; // another phase's line: not this bar's
                } else if (!line.isEmpty()) {
                    return line;
                }
            }
        } catch (IOException e) {
            return "";
        }
        return "";
    }

    /** The percentage of a "PROGRESS create <d> <t>" line: t > 0 ? 100*d/t : 0, clamped to 0..100; -1 when the
     *  numbers do not parse, so the caller skips the line. */
    static int pct(String line) {
        String[] p = line.substring(PREFIX.length()).trim().split("\\s+");
        if (p.length < 2) return -1;
        long d, t;
        try { d = Long.parseLong(p[0]); t = Long.parseLong(p[1]); }
        catch (NumberFormatException e) { return -1; }
        long pc = t > 0 ? 100L * d / t : 0;
        return (int) Math.max(0, Math.min(100, pc));
    }
}
