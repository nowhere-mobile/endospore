package com.nowhere.chooser;

/** NWP-20261026-20: doRemove's reboot decision, lifted pure (java.lang only) so it compiles and runs under javac
 *  (test-remove-retry-java.sh). The gate retries removeUser every 1.5 s; when the GRACE is over it asks the daemon's
 *  TEL-PENDING and, unless the answer is exactly "OK 0", retries one more GRACE before the reboot -- a reply it cannot
 *  read is "pending", the rule telPendingCount states (docs/product-decisions.md 2026-09-27, answer 4: "before
 *  rebooting with records pending, retry longer or log what it cost"). */
final class RemoveRetry {
    private RemoveRetry() {}

    /** ~24 s at the 1.5 s tick: covers the ~8 s switch to user 0 plus the removal, then the sure wipe (DIA-20260625-13). */
    static final int GRACE = 16;
    static final String RETRY = "RETRY", EXTEND = "EXTEND", REBOOT = "REBOOT";

    /** What the retry tick does after {@code tries} removals: RETRY while a grace runs; at the first grace's end REBOOT
     *  only for exactly "OK 0", else EXTEND; at the extended grace's end REBOOT, never a second extension. */
    static String next(int tries, boolean extended, String pendingReply) {
        if (tries < (extended ? 2 * GRACE : GRACE)) return RETRY;
        if (extended) return REBOOT;
        return pendingReply != null && "OK 0".equals(pendingReply.trim()) ? REBOOT : EXTEND;
    }

    /** The count for a log line: the digits of "OK <n>", else the daemon's own wording for a count it could not read
     *  (pendingTelWords). Nothing else of the reply is returned, so nothing else can be logged. */
    static String countWords(String pendingReply) {
        String r = pendingReply == null ? "" : pendingReply.trim();
        if (r.startsWith("OK ")) {
            String d = r.substring(3);
            if (d.matches("[0-9]{1,9}")) return String.valueOf(Integer.parseInt(d));
        }
        return "an unknown number of";
    }
}
