package com.nowhere.chooser;

/** The gate's "Back up my data" choices (NWP-20261202-25). DECIDED 2026-11-10 (docs/product-decisions.md, "the periodic
 *  save runs every 15 minutes by default, and its choices become 2, 5, 10, 15 and 30 minutes"): a save takes 3-10
 *  minutes of local work, so 30 seconds and 1 minute are dropped. DEFAULT_SECS must equal the agent's
 *  syncIntervalDefault (core/agent/main.go): the "(default)" label names the cadence the agent runs when no choice is
 *  stored. Pure Java (no android.*), so test-sync-choices-java.sh compiles it alone. */
final class SyncChoices {
    private SyncChoices() {}

    static final int[] SECS = {120, 300, 600, 900, 1800};
    static final String[] LABELS = {"Every 2 minutes", "Every 5 minutes", "Every 10 minutes",
            "Every 15 minutes (default)", "Every 30 minutes"};
    static final int DEFAULT_SECS = 900;
}
