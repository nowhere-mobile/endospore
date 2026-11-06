package com.nowhere.chooser;

/**
 * NWP-20261019-12: what a tap on the Software update screen's "Check for updates" waits for.
 *
 * OTA-STATUS answers from the daemon's cache, and a refresh it kicks benefits only the NEXT read, so a tap used to be
 * answered with whatever the cache already held. A tap now sends OTA-REFRESH once and watches OTA-VERSIONS for an
 * attempt that FINISHED after the tap (core/agent/ota_versions.go):
 * <pre>
 *   running X checked N lasterr E store S tried_ms T refreshing R
 * </pre>
 * {@code tried_ms} is when the last store check finished, success or not (-1 = never); {@code refreshing} is 1 while
 * one is in flight. It never polls OTA-REFRESH itself: every call to that verb starts a store check when none is
 * running.
 *
 * Pure Java, no Android types, so core/chooser/tests/ota-check-wait runs every arm under a plain JDK
 * (core/vendor-common/bin/test-ota-check-wait-java.sh).
 */
final class OtaCheckWait {
    private OtaCheckWait() {}

    /** An older daemon, or a failed read: no {@code tried_ms}, so there is nothing to wait on -- today's behaviour. */
    static final int LEGACY = 0;
    /** No attempt has finished since the tap yet (or one is still in flight): keep polling. */
    static final int WAIT = 1;
    /** An attempt finished after the tap, with no error: OTA-STATUS is now the live answer. */
    static final int FRESH = 2;
    /** An attempt finished after the tap and failed. Named so it is never read as OTA-STATUS's FAILED (an install failed). */
    static final int CHECK_FAILED = 3;
    /** The cap passed with no attempt finished since the tap. */
    static final int TIMEOUT = 4;

    static final class Versions {
        final boolean known;      // the line carried a tried_ms key
        final long triedMs;       // -1 = never tried
        final boolean refreshing;
        final String lastErr;     // "none" when the last attempt succeeded

        Versions(boolean known, long triedMs, boolean refreshing, String lastErr) {
            this.known = known;
            this.triedMs = triedMs;
            this.refreshing = refreshing;
            this.lastErr = lastErr;
        }
    }

    /** Scans the reply as a whitespace-separated key/value list, as the Software update screen does for {@code running}. */
    static Versions parse(String otaVersionsLine) {
        boolean known = false, refreshing = false;
        long tried = -1;
        String err = "";
        String[] p = otaVersionsLine == null ? new String[0] : otaVersionsLine.trim().split("\\s+");
        for (int i = 0; i + 1 < p.length; i++) {
            if ("tried_ms".equals(p[i])) {
                try { tried = Long.parseLong(p[i + 1]); known = true; } catch (NumberFormatException ignore) { }
            } else if ("refreshing".equals(p[i])) {
                refreshing = "1".equals(p[i + 1]);
            } else if ("lasterr".equals(p[i])) {
                err = p[i + 1];
            }
        }
        return new Versions(known, known ? tried : -1, refreshing, err);
    }

    /** What to do after reading {@code now}, given the read {@code before} the tap's OTA-REFRESH. */
    static int decide(Versions before, Versions now, long waitedMs, long capMs) {
        if (!before.known || !now.known) return LEGACY;
        boolean changed = now.triedMs >= 0 && now.triedMs != before.triedMs;
        if (changed && !now.refreshing) return verdict(now);
        if (waitedMs >= capMs) return changed ? verdict(now) : TIMEOUT;
        return WAIT;
    }

    private static int verdict(Versions now) {
        return "none".equals(now.lastErr) ? FRESH : CHECK_FAILED;
    }

    /**
     * An "Up to date" the tap's own check could not confirm is the stale answer this exists to stop. So is UNKNOWN
     * (NWP-20261108-09): once the daemon records a failed check, a tap whose own check failed on a phone that never
     * completed one reads OTA-STATUS's UNKNOWN (that read re-kicks a refresh and says "checking"), and
     * renderOtaStatus would park "Checking for updates…", a claim nothing updates (DIA-20260813-21).
     */
    static boolean replaceUpToDate(int decision, String statusHead) {
        return decision == CHECK_FAILED && ("NONE".equals(statusHead) || "UNKNOWN".equals(statusHead));
    }
}
