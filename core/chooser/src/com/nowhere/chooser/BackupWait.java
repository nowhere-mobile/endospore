package com.nowhere.chooser;

/** What "Back up now" shows while the save waits for a background re-key batch (NWP-20261206-20).
 *
 *  During a re-key batch the daemon answers BACKUP with "OK" and a second line "WAIT rekey-batch" (F10a,
 *  NOWHERE-1891): the save is queued, not refused, and starts when the batch ends. An older daemon closes the
 *  socket after "OK", so the second line is null and nothing on screen changes. The row this answers is
 *  docs/backlog.md, "Back up now during a background re-key waits for the batch already running; it answers BUSY
 *  only while a user op is queued behind that batch".
 *
 *  Pure java.lang, so core/vendor-common/bin/test-backup-wait-java.sh compiles and runs it directly. */
final class BackupWait {
    private BackupWait() {}

    /** DRAFT (NWP-20261206-20, mockup gate): Chester has not approved these words; the merger does not merge until he
     *  does. It starts with "Backing up…" (the row's CLOSES WHEN) and uses the Tie screen's term "move under the
     *  chip". The save's first SEALING frame with a total replaces it with the usual progress text. */
    static final String REKEY_BATCH =
            "Backing up… your save starts as soon as the phone finishes moving one part of your data under its chip.";

    /** REKEY_BATCH when {@code line}, trimmed, is exactly "WAIT rekey-batch"; null for null, "", any other WAIT
     *  reason and anything else, so an unknown reason keeps today's "Backing up…". */
    static String text(String line) {
        if (line == null) return null;
        return line.trim().equals("WAIT rekey-batch") ? REKEY_BATCH : null;
    }
}
