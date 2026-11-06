package com.nowhere.chooser;

/**
 * The Profile screen's one-line save status for a stored session (NWP-20261104-09, Q058, docs/product-decisions.md;
 * soft red is the 2026-10-07 status-line decision). Pure and java.lang only so a javac suite compiles it directly.
 *
 * The inputs are what SEAL-DELTA reports: {@code run} (a save in flight, "" when none), {@code savedAgo} (the
 * formatted age of the last good save, null when there is none) and {@code verdict} (the last attempt's outcome:
 * "" | ok | fail | nocredit | refused; anything else is treated as none). First match wins.
 */
final class SaveStatusLine {
    private SaveStatusLine() {}

    static String text(String run, String savedAgo, String verdict) {
        final boolean saved = savedAgo != null && !savedAgo.isEmpty();
        if (run != null && !run.isEmpty()) return "Signed in · saving now…";
        if ("nocredit".equals(verdict)) return "Signed in · last save failed: plan out of credit";
        if ("fail".equals(verdict)) {
            return saved ? "Signed in · saved " + savedAgo + " · last try failed" : "Signed in · last save failed";
        }
        if ("refused".equals(verdict)) return "Signed in · last save held back";
        if (saved) return "Signed in · saved " + savedAgo;
        return "Signed in · not saved yet this session";
    }

    /** True when the line reports a failed save and is painted soft red; a held-back save is not a failure. */
    static boolean isError(String verdict) {
        return "fail".equals(verdict) || "nocredit".equals(verdict);
    }
}
