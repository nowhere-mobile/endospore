package com.nowhere.chooser;

/** The wait-and-decide rule of a committed PackageInstaller session (NWP-20260831-03), once, for both full-session
 *  installs: {@code UnarchiveService.installApks} (an on-demand materialise) and {@code ChooserActivity.installApkSet}
 *  (the login materialise). Pure java.lang -- no android.* import -- so test-install-wait-java.sh runs it under javac.
 *
 *  ⚠ A TIMEOUT IS NOT A VERDICT. The receiver's status defaults to FAILURE, and the old single 120s await reported a
 *  still-running install as failed: device-proven on lynx 2026-08-30, where a 243MB 12-apk gms set landed at ~4
 *  minutes -- our abort cascaded to every dependent app ("play store installation is broken?") while the install then
 *  succeeded unobserved. So the wait re-arms in BEAT_MS beats while the SESSION still exists (alive = still
 *  installing); when the session is gone without our broadcast, a lagging broadcast gets one LAG_MS beat, and then
 *  the codePath decides: every applied session mints a new random-suffix codePath, so a non-null path that differs
 *  from the one before commit means the install applied (a first install's null "before" with a path after is a
 *  landing, not "unchanged"). HARD_MS bounds the WAITING, not the install. */
final class InstallWait {
    private InstallWait() {}

    interface Latch { boolean await(long ms) throws InterruptedException; }
    interface Session { boolean alive(); }
    /** The package's sourceDir now; null when it is not installed. */
    interface CodePath { String now(); }
    interface Clock { long now(); }
    interface Tick { void stillRunning(); }

    enum Outcome { BROADCAST, LANDED, GONE_UNCHANGED, HARD_BOUND }

    static final long BEAT_MS = 30_000;
    static final long LAG_MS = 5_000;
    static final long HARD_MS = 600_000;

    static Outcome await(Latch latch, Session session, CodePath path, String pathBefore, Clock clock, Tick tick)
            throws InterruptedException {
        long deadline = clock.now() + HARD_MS;
        while (!latch.await(BEAT_MS)) {
            if (!session.alive()) {
                if (latch.await(LAG_MS)) return Outcome.BROADCAST;
                String after = path.now();
                return after != null && !after.equals(pathBefore) ? Outcome.LANDED : Outcome.GONE_UNCHANGED;
            }
            if (clock.now() > deadline) return Outcome.HARD_BOUND;
            tick.stillRunning();
        }
        return Outcome.BROADCAST;
    }

    /** The status message a site records for the outcome; null for BROADCAST (the receiver's own message stands). */
    static String message(Outcome o) {
        switch (o) {
            case LANDED: return "session finished without our broadcast; codePath changed";
            case GONE_UNCHANGED: return "session gone, codePath unchanged (abandoned or failed without a broadcast)";
            case HARD_BOUND: return "still installing at the 10-minute hard bound; giving up on WAITING, not on the install";
            default: return null;
        }
    }
}
