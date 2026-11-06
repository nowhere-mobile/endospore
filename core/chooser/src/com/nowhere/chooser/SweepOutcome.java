package com.nowhere.chooser;

/** NWP-20261113-17: the per-app outcome of an Auto sweep, as the chooser sends it to the daemon's AUTO-SWEEP-APP
 *  (NWP-20261113-16), which writes `auto sweep app <i>/<n>: <outcome> in <ms>ms` to login.log. Field-seen on
 *  frankel 0.5.48 (ticket NW-a805853cb888): a 3072 s sweep left a report that could not say which app stalled,
 *  because the per-app result went to logcat only, which a report on a user build cannot collect.
 *
 *  The wire carries the app's index, the sweep's size, one token of a closed set and the elapsed milliseconds --
 *  NEVER a package, a label or a path. The tokens and the bounds mirror core/agent/auto_sweep.go
 *  (autoSweepOutcomeTokens, parseSweepApp), and test-sweep-outcome-java.sh compares the two lists. java.* only, so
 *  that suite compiles it alone. */
final class SweepOutcome {
    static final String INSTALLED = "installed";           // the sealed copy (or a tap's catalog update) installed
    static final String ALREADY = "already";               // installed and restored: nothing to do
    static final String RESTORE_ONLY = "restore-only";     // it had code: its restore was retried, nothing fetched
    static final String FETCH_FAILED = "fetch-failed";     // a dependency, a non-OK MATERIALIZE-APP other than busy, or no APK
    static final String INSTALL_FAILED = "install-failed"; // the fetched APK set did not install
    static final String STOPPED = "stopped";               // a sign-out stopped the sweep before this app
    static final String ERROR = "error";                   // the call threw, or ended at no recorded exit
    static final String BUSY = "busy";                     // NWP-20261118-05: the worker lane stayed busy; this app was not attempted
    static final String NEEDS_PLAY = "needs-play";         // NWP-20261119-15: a Play client with no Play stack; its placeholder stays
    static final String OLDER_COPY = "older-copy";         // NWP-20261126-07: the fetched copy was older than its placeholder; not installed, not fetched again this session

    /** The agent's order (core/agent/auto_sweep.go autoSweepOutcomeTokens). */
    static final String[] TOKENS = { INSTALLED, ALREADY, RESTORE_ONLY, FETCH_FAILED, INSTALL_FAILED, STOPPED, ERROR, BUSY, NEEDS_PLAY, OLDER_COPY };

    /** The daemon's bounds (parseSweepApp): 1 <= i <= n <= 9999, 0 <= ms <= MAX_MS. */
    static final int MAX_N = 9999;
    static final long MAX_MS = 86_400_000L;

    private SweepOutcome() {}

    /** The AUTO-SWEEP-APP request for app i of the sweep's n, or null for an input the daemon would refuse (an
     *  index out of range, a negative or over-long time, a token not in TOKENS). On null the caller sends nothing. */
    static String request(int i, int n, String outcome, long ms) {
        if (i < 1 || n < 1 || i > n || n > MAX_N || ms < 0 || ms > MAX_MS) return null;
        boolean known = false;
        for (String t : TOKENS) if (t.equals(outcome)) { known = true; break; }
        if (!known) return null;
        return "AUTO-SWEEP-APP\n" + i + "\n" + n + "\n" + outcome + "\n" + ms + "\n";
    }
}
