package com.nowhere.chooser;

import java.util.function.LongFunction;

/**
 * Your data's "Changed on this phone since the last save" line, from SEAL-DELTA-WALK's figures (h56 #6,
 * NWP-20261128-11). The figures are PLAINTEXT BYTES ON THIS PHONE, not upload size, and a blind path is flagged,
 * never folded in.
 *
 * A deleted file counts from the lists the phone already holds: #media from its head, the vault and #de from the
 * last landed seal's scan cache (files of 1 MiB or more). A small app file has no path in that cache, so the
 * second sentence says such deletions are not counted. A scope whose scan cache was not read (deletedUnknown)
 * never gets "No new changes since the last save.": its deletions were not checked.
 *
 * Pure java.lang, so test-delta-line-java.sh compiles it alone.
 */
final class DeltaLine {
    private DeltaLine() {}

    static final String SMALL = "Deletions of small app files are not counted.";
    static final String BLIND_SUFFIX = " · some areas couldn’t be read";
    static final String UNKNOWN_SUFFIX = " · some deletions couldn’t be checked";

    /** The line, then SMALL on its own line. Never null. fmt formats a byte count ("12 MB"). */
    static String line(long changedBytes, long changedFiles, long blind, long deletedBytes, long deletedFiles,
                       boolean deletedUnknown, LongFunction<String> fmt) {
        boolean changed = changedBytes > 0 || changedFiles > 0;
        boolean deleted = deletedFiles > 0;
        StringBuilder s = new StringBuilder();
        if (changed) {
            s.append("Changed on this phone since the last save: ~").append(fmt.apply(changedBytes))
                    .append(" across ").append(changedFiles).append(changedFiles == 1 ? " file" : " files");
            if (deleted) {
                s.append(" · ").append(deletedFiles).append(" deleted (~").append(fmt.apply(deletedBytes))
                        .append(')');
            }
            if (blind > 0) s.append(BLIND_SUFFIX);
        } else if (deleted) {
            s.append("Deleted on this phone since the last save: ~").append(fmt.apply(deletedBytes))
                    .append(" across ").append(deletedFiles).append(deletedFiles == 1 ? " file" : " files");
            if (blind > 0) s.append(BLIND_SUFFIX);
        } else if (blind > 0) {
            s.append("Couldn’t read some areas to check for changes.");
        } else if (deletedUnknown) {
            s.append("No new changes found since the last save.");
        } else {
            s.append("No new changes since the last save.");
        }
        if (deletedUnknown) s.append(UNKNOWN_SUFFIX);
        return s.append('\n').append(SMALL).toString();
    }

    /** The line takes the accent colour when something changed or was deleted. */
    static boolean active(long changedBytes, long changedFiles, long deletedFiles) {
        return changedBytes > 0 || changedFiles > 0 || deletedFiles > 0;
    }
}
