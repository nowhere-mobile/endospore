package com.nowhere.chooser;

/**
 * The toast the Storage screen's "Stop keeping it" and "Stop carrying it" show (NWP-20261128-15). The words came out
 * of ProfileActivity.applyStorageDrop unchanged, with one new branch: when EXPECT-SHRINK was accepted but the keep-set
 * rewrite did not land (an unreadable keep-set, or a full phone), the toast says SettingsSaveCopy.NOT_SAVED instead
 * of "Stopped keeping". java.lang only, so core/chooser/test-keepset-unsaved-java.sh can run it under javac.
 */
final class StorageDropCopy {
    private StorageDropCopy() {}

    /** shrinkOk: the daemon answered OK to EXPECT-SHRINK. saved: the keep-set rewrite landed. reply: the daemon's
     *  trimmed answer, never null. failed and reason: DaemonReply.failed() and reason(). */
    static String line(boolean shrinkOk, boolean saved, String reply, boolean failed, String reason,
                       CharSequence label) {
        if (shrinkOk) return saved ? "Stopped keeping " + label + ". It's still here until you log off."
                                   : SettingsSaveCopy.NOT_SAVED;
        if (reply.startsWith("NONE")) return "No active session.";
        // NWP-20260826-05: the daemon now answers BUSY rather than blocking, so this is the case that used to reach
        // us as a 90s timeout -- or, before -01, as nothing at all. Same words as the timeout branch on purpose: from
        // where the user is standing they ARE the same event, and the difference (we gave up vs the daemon declined)
        // is ours to log, not theirs to parse.
        if (reply.startsWith("BUSY")) return "The phone is busy saving or downloading. Nothing "
                + "changed — tap it again in a moment.";
        if (failed) return "Nothing changed — " + reason + ". Tap it again in a moment.";
        return "Couldn't prepare that change — try again.";
    }
}
