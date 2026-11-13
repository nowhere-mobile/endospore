package com.nowhere.chooser;

import java.util.Collection;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Consumer;

/** NWP-20261130-03 (2b, maintainer decision 2026-11-08: "chooser change to block the app until data lands"): the launch
 *  barrier of an installed app whose data is still out. Since the sign-in stopped fetching the data of On-demand and Auto
 *  apps, Play, Aurora, a sideload or a nApps Get can put such an app on the phone with its data still in the store.
 *
 *  THE RULE: the chooser suspends the app at its package-added event, and lifts that only when the daemon's
 *  OD-DATA-PENDING answers NO after an OK reply from RESTORE-ODDATA. Everything except NO counts as data out: an unknown
 *  answer never leaves an app launchable. The worker lanes play no part in the hold, so a seal on the RW lane and a storage
 *  walk on the RO lane cannot delay it.
 *
 *  RF-013: THE EVENT MUST NOT DEPEND ON THE SESSION CHOOSER BEING ALIVE. Android can kill that process, and its runtime
 *  receiver dies with it, so the persistent user-0 process hears every session install too (OdDataInstallWatch) and relays
 *  it by name to a manifest receiver, which starts the dead process (OdDataAddedReceiver). See {@link Watch}.
 *
 *  Pure (java only) so test-od-data-barrier-java.sh runs it under javac alone; OdDataBarrierHost is the Android side. */
final class OdDataBarrier {
    private OdDataBarrier() {}

    /** The platform and daemon calls, replaced by the test's fake. */
    interface Seam {
        /** The trimmed OD-DATA-PENDING reply, "" when there was none. */
        String ask(String pkg);
        /** Suspend pkg. true only when the framework accepted it. failed selects the failed-fetch dialog. */
        boolean suspend(String pkg, boolean failed);
        /** Lift the chooser's suspension of pkg. true only when the framework accepted it. */
        boolean unsuspend(String pkg);
        /** Record, durably for the session, that this barrier holds pkg. */
        void mark(String pkg);
        /** The framework accepted the suspension: tell roamd, which then adds no suspension of its own (RF-012). */
        void confirm(String pkg);
        void unmark(String pkg);
        boolean marked(String pkg);
        /** true when another hold of the chooser (AppClaim) also needs pkg suspended, or that cannot be read. */
        boolean claimedElsewhere(String pkg);
        void log(String line);
    }

    /** The packages whose failed fetch was logged, so a retry loop logs it once. In memory: a new process may log it again. */
    private static final Set<String> FAILED = ConcurrentHashMap.newKeySet();

    static boolean dataOut(String reply) {
        return !"NO".equals(reply == null ? "" : reply.trim());
    }

    /** pkg was installed: suspend it when its data is out. Returns true when this barrier holds it now. The mark is written
     *  first: a process death after it costs one no-op at reconcile, and a suspension with no mark would have no owner. */
    static boolean onAdded(Seam s, String pkg) {
        if (!dataOut(s.ask(pkg))) return false;
        s.mark(pkg);
        if (!s.suspend(pkg, false)) {
            s.unmark(pkg);
            s.log("od-barrier: could not suspend " + pkg + " -- roamd's own block is the backstop (NWP-20261130-03)");
            return false;
        }
        s.confirm(pkg);
        s.log("od-barrier: suspended " + pkg + " until its data is back (NWP-20261130-03)");
        // The restore can have landed between the question and the suspension. Nothing would lift this hold then.
        if (!dataOut(s.ask(pkg))) {
            release(s, pkg);
            return false;
        }
        return true;
    }

    /** pkg's package-added event, relayed by the user-0 watcher to a process that may have just started. A held package has
     *  no install-heal behind it on this path, so this path asks for the restore, and only after the hold stands. */
    static void onRelayed(Seam s, String pkg, Consumer<String> retry) {
        if (onAdded(s, pkg)) retry.accept(pkg);
    }

    /** A RESTORE-ODDATA reply for pkg. OK and a confirmed NO lift the hold. ERR-NOTREADY is a failed fetch: pkg stays
     *  suspended, the dialog says so, and the first failure is logged. Every other reply leaves the hold as it stands. */
    static void afterReply(Seam s, String pkg, String reply) {
        if (!s.marked(pkg)) return;
        String r = reply == null ? "" : reply.trim();
        if (r.startsWith("OK")) {
            if (!dataOut(s.ask(pkg))) release(s, pkg);
            else s.log("od-barrier: " + pkg + " answered OK but its data is still out -- it stays suspended (NWP-20261130-03)");
            return;
        }
        if (r.equals("ERR-NOTREADY") || r.startsWith("ERR-NOTREADY ")) {
            if (FAILED.add(pkg)) {
                s.suspend(pkg, true);
                s.log("od-barrier: the data of " + pkg + " did not arrive -- it stays suspended, the next tap retries (NWP-20261130-03)");
            }
        }
    }

    /** At a chooser process start. A held app whose data came back in the meantime is released, one still out is held and
     *  retried, an app no longer installed loses its mark, and an installed app the dead process never saw is held. */
    static void reconcile(Seam s, Collection<String> marks, Collection<String> installed, Consumer<String> retry) {
        for (String m : marks) {
            if (!installed.contains(m)) {
                s.unmark(m);
                continue;
            }
            if (!dataOut(s.ask(m))) {
                release(s, m);
                continue;
            }
            if (s.suspend(m, false)) s.confirm(m);
            else s.log("od-barrier: could not suspend " + m + " at reconcile (NWP-20261130-03)");
            retry.accept(m);
        }
        for (String p : installed) {
            if (marks.contains(p)) continue;
            if (onAdded(s, p)) retry.accept(p);
        }
    }

    /** RF-013: the rules of the user-0 watcher (OdDataInstallWatch is its Android side). An event for the current, unlocked
     *  session goes on at once, by name. Any other session event waits: `in` installs before the switch, and starting the
     *  session's chooser then would run it against files the restore is still writing. A session that later becomes current
     *  and unlocked gets one sweep, which holds whatever that wait covered. Process memory only: a persistent process that
     *  restarts loses the wait, and the session chooser's reconcile at its own birth remains the backstop. */
    static final class Watch {
        /** The platform calls, replaced by the test's fake. */
        interface Platform {
            int currentUser();
            boolean unlocked(int user);
            /** Deliver pkg's event to user's chooser by name, starting its process when it is dead. */
            void relay(int user, String pkg);
            /** Ask user's chooser to reconcile, starting its process when it is dead. */
            void sweep(int user);
        }

        private int waiting = -1; // the session with an event not yet relayed

        synchronized void onAdded(Platform p, int user, String pkg, String self) {
            if (user <= 0 || pkg == null || pkg.isEmpty() || pkg.equals(self)) return;
            if (user == p.currentUser() && p.unlocked(user)) p.relay(user, pkg);
            else waiting = user;
        }

        /** A user switch or unlock. */
        synchronized void onUserChange(Platform p) {
            if (waiting <= 0 || waiting != p.currentUser() || !p.unlocked(waiting)) return;
            p.sweep(waiting);
            waiting = -1;
        }
    }

    private static void release(Seam s, String pkg) {
        if (s.claimedElsewhere(pkg)) {
            s.unmark(pkg);
            FAILED.remove(pkg);
            s.log("od-barrier: " + pkg + " stays suspended for another handset's claim (NWP-20261130-03)");
            return;
        }
        if (s.unsuspend(pkg)) {
            s.unmark(pkg);
            FAILED.remove(pkg);
            s.log("od-barrier: released " + pkg + ": its data is back (NWP-20261130-03)");
        } else {
            s.log("od-barrier: could not release " + pkg + " -- the next tap retries (NWP-20261130-03)");
        }
    }
}
