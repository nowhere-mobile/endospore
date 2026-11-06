package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/** NWP-20261109-06 (Q116, DECIDED 2026-10-20 "nineteen recommendations accepted — the wallet lag closes on ..."): a
 *  sign-out stops the post-login Auto sweep. ProfileActivity.doLogoffImpl raises it before its captures and its
 *  LOGOUT write, so the sweep starts no new MATERIALIZE-APP (each holds the daemon's session lock for the whole
 *  download, and LOGOUT would wait behind it); UnarchiveService.sweepAuto reads it at the top of each of its two
 *  loops. Only doLogoffImpl's failed-seal branch and its lockLanding branch (LOGOUT answered BUSY COLDLOCK, Q067)
 *  lower it: in both the session stayed signed in, so a later sweep must run.
 *
 *  A process static is right here: ProfileActivity and UnarchiveService run in the chooser's one process in the
 *  roamed user (the manifest declares no android:process for either), so both see the same flag, and it dies with
 *  the user the sign-out removes -- the next login is a new user and a new process, which starts lowered. */
final class SignOutGate {
    private static final AtomicBoolean BEGUN = new AtomicBoolean(false);

    private SignOutGate() {}

    static void begin() { BEGUN.set(true); }

    static void end() { BEGUN.set(false); }

    static boolean begun() { return BEGUN.get(); }

    /** A NEW list of work's members from index next on (empty when next >= size): the apps a stopped sweep never
     *  started, which leave the shared queue so the notification stops counting apps that are not coming. */
    static List<String> rest(List<String> work, int next) {
        int from = Math.max(next, 0);
        if (from >= work.size()) return new ArrayList<>();
        return new ArrayList<>(work.subList(from, work.size()));
    }
}
