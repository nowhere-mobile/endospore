package com.nowhere.chooser;

/** NWP-20261203-17: the Auto sweep's failed-apps notice. Backlog section C, "When every app in an Auto sweep fails, the
 *  user is not told: ..." (Chester, husky 0.5.55, ticket NW-222be2ee470a, 2026-11-12). DECIDED by Chester, 2026-11-12,
 *  "Notice with a count" (docs/product-decisions.md, "four answers to harvest 64 ..."): any pass with at least one app
 *  that fetch-failed, install-failed or ended in error posts one notice with the count, and a tap opens Your apps; an
 *  all-failed pass is the count equal to the total. The landing card is unchanged. The words are DRAFTS for Chester
 *  (mockup gate). Counts only, never a package, a label or a path. java.* only, so test-sweep-fail-notice-java.sh
 *  compiles it alone. */
final class SweepFailNotice {
    private SweepFailNotice() {}

    /** Beside UnarchiveService.FG_ID (0x0A2D) and OlderCopy.NOTICE_ID (0x0A2E). Its own id, because the sweep's FG_ID
     *  notice is removed when the service stops (STOP_FOREGROUND_REMOVE): an inference, as OlderCopy states. */
    static final int NOTICE_ID = 0x0A2F;

    /** NWP-20261207-04: the "Try again" action's PendingIntent. Its own request code, not FG_ID (0x0A2D), FG_ID + 1 or
     *  FG_ID + 2 (NOTICE_ID); and its own intent action, because Intent.filterEquals ignores extras, so this
     *  PendingIntent can never equal another getService or getForegroundService PendingIntent of UnarchiveService. */
    static final int RETRY_REQUEST = 0x0A30;
    static final String ACTION_RETRY = "com.nowhere.chooser.action.SWEEP_RETRY";

    /** A hard failure: the app ran and did not land. The literals equal SweepOutcome.FETCH_FAILED, INSTALL_FAILED and
     *  ERROR. needs-play and older-copy have their own placeholder story and notice; busy and stopped did not run. */
    static boolean hard(String outcome) {
        return "fetch-failed".equals(outcome) || "install-failed".equals(outcome) || "error".equals(outcome);
    }

    enum Act { POST, CANCEL, KEEP }

    /** POST for any pass with a hard failure (a POST replaces the last notice: the same id). CANCEL when a pass landed
     *  an app and none failed hard. KEEP otherwise: nothing ran, or Pause, Stop, a sign-out or a busy lane cut the pass
     *  before any hard failure, so the last notice is still true. */
    static Act action(int total, int done, int hardFailed) {
        if (total > 0 && hardFailed > 0) return Act.POST;
        if (hardFailed == 0 && done > 0) return Act.CANCEL;
        return Act.KEEP;
    }

    /** NWP-20261207-04 (decision 2026-11-12, answer 4 (2)): the "Try again" action rides only a notice that says apps
     *  failed. */
    static boolean offersRetry(Act act) {
        return act == Act.POST;
    }

    /** The title, null when there is nothing to say. Draft words (Chester's example, 2026-11-12). */
    static String title(int failed, int total) {
        if (failed <= 0 || total <= 0) return null;
        if (total == 1) return "1 app could not be fetched";
        return failed + " of " + total + " apps could not be fetched";
    }

    /** The body, collapsed and expanded. Draft words. */
    static final String TEXT = "Open Your apps and tap Install pending apps now, or tap an app to try it again.";

    /** NWP-20261207-04: the action's label. DRAFT words for Chester's mockup. A tap starts the sweep by hand, as
     *  "Install pending apps now" does. */
    static final String RETRY = "Try again";
}
