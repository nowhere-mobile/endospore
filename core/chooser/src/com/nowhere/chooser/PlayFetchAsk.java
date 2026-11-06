package com.nowhere.chooser;

import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.Predicate;

/**
 * dn-1023 #5 (DECIDED 2026-10-24, docs/product-decisions.md; NWP-20261114-14): the first tap on an on-demand app that
 * needs the Play stack shows the size and asks before the fetch starts. An app set to Auto is not asked: the Auto
 * sweep (#130, {@code quiet}) never reaches the question.
 *
 * Pure: no android.* import, so test-play-fetch-ask-java.sh compiles it with its cases under javac. The dialog is
 * {@link PlayFetchAskActivity}; the call site is UnarchiveService.materializeLocked.
 *
 * ⚠ The words are the recommendation's example, NOT final copy: the building slice shows them to Chester. The minutes
 * assume about 1 MB/s.
 *
 * h49 #9 (DECIDED 2026-10-31, docs/product-decisions.md; NWP-20261119-27): {@link #WHERE} goes between the size and
 * the question on both bodies, so a user who taps Download knows where the download shows. The notification stays the
 * progress; no card covers the download. The sentence is the decision's example, NOT final copy: the PR shows it to
 * Chester.
 */
final class PlayFetchAsk {
    private PlayFetchAsk() {}

    /** The read bound on APP-FETCH-SIZE. A miss shows the size-unknown line; it never blocks the ask. */
    static final int SIZE_READ_MS = 10000;
    /** How long the tap waits for an answer. TIMEOUT counts as Not now. */
    static final long WAIT_MS = 60000;

    /** h49 #9: where the download's progress shows. The decision's example, not final copy. */
    static final String WHERE = "You can keep using the phone; progress shows in your notifications.";

    static final String UNKNOWN =
            "This app needs Google Play services first, a large download. " + WHERE + " Download now?";

    enum Reply { YES, NO, TIMEOUT }

    /** True when a TAP (not the Auto sweep) is about to fetch at least one Play-stack member. */
    static boolean needsAsk(boolean quiet, List<String> fetchDeps, Predicate<String> isStack) {
        if (quiet || fetchDeps == null) return false;
        for (String d : fetchDeps) if (d != null && isStack.test(d)) return true;
        return false;
    }

    /** The question's body. bytes <= 0 means the size is unknown. */
    static String message(long bytes) {
        if (bytes <= 0) return UNKNOWN;
        long mb = Math.max(1, Math.round(bytes / 1048576.0));
        long lo = Math.max(1, mb / 60);
        return "About " + mb + " MB, " + lo + "–" + (lo + 1) + " minutes. " + WHERE + " Download now?";
    }

    /** APP-FETCH-SIZE's reply: "OK <bytes> <files>" gives bytes; NONE, LOCAL, ERR-PKG, ERR, a miss or junk give -1. */
    static long parseSize(String reply) {
        if (reply == null) return -1;
        String[] f = reply.trim().split(" ");
        if (f.length != 3 || !"OK".equals(f[0])) return -1;
        try {
            long bytes = Long.parseLong(f[1]);
            long files = Long.parseLong(f[2]);
            return (bytes < 0 || files < 0) ? -1 : bytes;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** The one live ask. The service and the activity share one process per user, so a static is shared. */
    static final Asker ASKER = new Asker();

    /** A one-shot answer holder. open() starts a new ask and retires the old one, so a stale token (an old
     *  activity's late Back or onDestroy) never answers a newer ask. */
    static final class Asker {
        private long token;
        private CountDownLatch latch = new CountDownLatch(0);
        private Reply answer;

        synchronized long open() {
            token++;
            latch = new CountDownLatch(1);
            answer = null;
            return token;
        }

        /** False when the token is stale or the ask is already answered. */
        synchronized boolean answer(long token, boolean yes) {
            if (token != this.token || answer != null) return false;
            answer = yes ? Reply.YES : Reply.NO;
            latch.countDown();
            return true;
        }

        Reply await(long token, long ms) {
            CountDownLatch l;
            synchronized (this) {
                if (token != this.token) return Reply.TIMEOUT;
                l = latch;
            }
            try {
                if (!l.await(ms, TimeUnit.MILLISECONDS)) return Reply.TIMEOUT;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return Reply.TIMEOUT;
            }
            synchronized (this) {
                return (token == this.token && answer != null) ? answer : Reply.TIMEOUT;
            }
        }
    }
}
