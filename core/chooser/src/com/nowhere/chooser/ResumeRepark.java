package com.nowhere.chooser;

/** NWP-20261111-12 (Q087, docs/product-decisions.md 2026-10-20): what the gate makes of the daemon's answer when it
 *  re-parks a session whose RESUME succeeded but whose user switch failed (ChooserActivity.reparkAfterFailedResume).
 *  handleColdLock (core/agent/main.go) writes exactly one of three first lines: "OK NOSESSION", "OK LOGOFF" or
 *  "OK LOCKING". Only "OK LOCKING" says a teardown started -- the same affirmative reading as IdleLockGate.afterReply;
 *  anything else, a dead socket ("") included, is "not re-parked". Pure java.lang, so
 *  core/vendor-common/bin/test-resume-repark-java.sh compiles this file itself under plain javac. */
final class ResumeRepark {
    private ResumeRepark() {}

    /** True only when the trimmed COLD-LOCK reply is exactly "OK LOCKING". */
    static boolean landed(String coldLockReply) {
        return coldLockReply != null && "OK LOCKING".equals(coldLockReply.trim());
    }

    /** The resume screen's line after a failed switch: the re-park's outcome when it landed, else today's line. */
    static String failedSwitchLine(boolean landed) {
        return landed ? "Couldn't open your session. It's locked again; try again." : "couldn't resume — try again";
    }
}
