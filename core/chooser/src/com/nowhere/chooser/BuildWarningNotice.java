package com.nowhere.chooser;

/**
 * NWP-20261120-03 (Q098 in docs/product-decisions.md, decided 2026-10-20): the gate's build-warning notice. When the
 * operator publishes a signed warning naming this build, the daemon caches it (core/agent build_warning_fetch.go) and
 * GET-BUILD-WARNING answers WARN; before sign-in the gate shows everyone the same notice, with a way to continue. It
 * never blocks: any other reply (NONE, an error, an older daemon without the verb, no daemon) shows nothing.
 * Pure (java.lang only), so test-build-warning-notice-java.sh compiles it off the build host.
 */
final class BuildWarningNotice {
    private BuildWarningNotice() {}

    // The words are the decision's example, verbatim; not final copy (the maintainer's to change at the device run).
    static final String TITLE = "A known problem in this version";
    static final String TEXT = "A known problem in this version can lose data.";
    static final String BUTTON = "Continue";

    /** Whether to raise the notice now: the daemon answered WARN, none is on screen, the person at the gate has not
     *  tapped Continue since the last screen-off, and this gate is not going. */
    static boolean due(String reply, boolean showing, boolean dismissed, boolean finishing) {
        return reply != null && "WARN".equals(reply.trim()) && !showing && !dismissed && !finishing;
    }
}
