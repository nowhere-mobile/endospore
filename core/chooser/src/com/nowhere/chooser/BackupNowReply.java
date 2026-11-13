package com.nowhere.chooser;

/**
 * What the back-online notification's "Back up now" does with the daemon's BACKUP reply (NWP-20261029-12). Pure Java,
 * no android.*, so core/chooser/test-backup-now-reply-java.sh compiles it directly. The reply is read as ReplyCopy
 * reads it: first line only, trimmed.
 *
 * <p>A save already running is not a refusal (NWP-20261201-09; docs/product-decisions.md, 2026-11-07): BUSY seal-in-flight
 * and BUSY seal-run:<kind> mean the tap joins that save, so the "Backing up" notice stays and BackNowCycle clears it when
 * a save from after the reconnect lands.
 */
final class BackupNowReply {
    private BackupNowReply() {}

    /** The save started, or the tap joined the one running: leave the Backing up state; the user-0 watcher clears it. */
    static final int SAVING = 0;
    /** Nothing to save (NONE) or the data is local only (LOCAL): the prompt has no job left, clear it. */
    static final int CLEAR = 1;
    /** Refused for a reason other than a running save, an error, or no reply: put the prompt back with what happened. */
    static final int PROMPT = 2;

    private static String first(String reply) {
        return reply == null ? "" : reply.split("\n", 2)[0].trim();
    }

    /** True when a save is already running, so this tap joins it instead of starting one. */
    static boolean joins(String reply) {
        String f = first(reply);
        return f.equals("BUSY seal-in-flight") || f.startsWith("BUSY seal-run:");
    }

    static int action(String reply) {
        String f = first(reply);
        if (f.equals("OK") || joins(reply)) return SAVING;
        if (f.equals("NONE") || f.equals("LOCAL")) return CLEAR;
        return PROMPT;
    }

    /** The prompt's body for a PROMPT reply; null for SAVING (a joined reply included) and CLEAR. */
    static String body(String reply) {
        int a = action(reply);
        if (a != PROMPT) return null;
        if (first(reply).startsWith("BUSY")) return ReplyCopy.backupBusy(reply);
        return "Couldn't reach the save service, so nothing was saved. Try again in a moment.";
    }
}
