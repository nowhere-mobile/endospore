package com.nowhere.chooser;

/**
 * NWP-20261203-05: free a session's CredentialService that ActivityManager left restarting with the gate's starts
 * pending (docs/backlog.md §B, "At every sign-in the session's chooser process is killed for "permissions revoked"
 * and its CredentialService is left restarting with the sign-in's starts pending ...").
 *
 * WHY THIS EXISTS. At every sign-in AM kills the session user's chooser process ("permissions revoked"). When a
 * CredentialService start is in flight at that instant, its ServiceRecord goes to the restart list with app=null and
 * can stay there for minutes (5 min 22 s on lynx, 2026-11-11) while the user's chooser process runs again. Every
 * branch of CredentialService.onStartCommand returns START_NOT_STICKY, so nothing re-sends the work, and the web-import
 * ingest, the claim apply, the GrapheneOS flags, the SMS role, the telephony ingest and RestartRearm's relayprefs ask
 * all wait in that queue.
 *
 * WHY A RE-KICK CANNOT HELP. While a ServiceRecord is in ActiveServices.mRestartingServices, bringUpServiceLocked
 * returns at once for a start that is not the restart itself, so a new startServiceAsUser only adds one more pending
 * start to the same dead record (the §B row of 2026-09-17 saw ten). A stopService brings that record down with its
 * pending starts and unschedules the restart; the next startServiceAsUser makes a new record and binds it to the
 * running process at once. A hand kill of the session chooser process freed the queue the same way.
 *
 * SO: after a sign-in (roamLogin) and after a gate restart's relayprefs ask (RestartRearm.atProcessBirth), user 0 reads
 * the session's CredentialService twice, Rule.FIRST_MS then Rule.CONFIRM_MS later. Only when both reads see it
 * restarting with no process (Rule.stuck) does it stop it and re-send each kind this gate process sent that session
 * (Rule.Sent, keyed by the user serial so a reused user id starts empty). It never stops a service with a pid: that
 * one runs work. It rides on the existing CredentialService and adds no component, because a NEW manifest component
 * does not register over a pinned-fingerprint reflash without a data wipe (the B4 lesson, 2026-07-11).
 *
 * A stop does not end a worker thread, and the service can come up between the second read and the stop, so a re-sent
 * start can overlap a first run. Every re-sent kind is safe to run twice, but Ingest.run is not safe to run twice AT
 * ONCE (two workers pass the same receipt and exists checks), so CredentialService runs it through runOnce.
 *
 * NOT CLOSED HERE: the kill itself. One login.log line per watch (credsvc-watch, through ChooserActivity.idleTrace)
 * says what the watch saw and how many starts it re-sent; it carries integers and closed words only.
 */
final class CredSvcWatch {
    private CredSvcWatch() {}

    private static final String TAG = "NowhereChooser";

    // The CredentialService extras the watch may re-send. Each is a constant so that a caller never repeats the word
    // as a literal (test-claims-login-apply.sh P1 counts the claims-login extra in ChooserActivity).
    static final String CLAIMS_LOGIN = "claimsLogin";
    static final String RELAYPREFS = "relayprefs";
    static final String GOSSTATE = "gosstate";
    static final String INGEST = "ingest";
    static final String SMSROLE = "smsrole";
    static final String TELINGEST = "telingest";

    /** The pure decision. java.lang and java.util only, so a javac suite compiles it off the build host
     *  (core/vendor-common/bin/test-credsvc-watch-java.sh). */
    static final class Rule {
        private Rule() {}

        /** How long the watch waits before its first read: a normal restart completes in seconds. */
        static final long FIRST_MS = 20_000L;
        /** How long it waits between the first read and the confirming one. */
        static final long CONFIRM_MS = 15_000L;

        /** The kinds the watch re-sends, in the order of CredentialService.onStartCommand's branches. */
        static final String[] ORDER = { CLAIMS_LOGIN, RELAYPREFS, GOSSTATE, INGEST, SMSROLE, TELINGEST };

        /** Stuck = the service is known, has no process and has a restart scheduled. */
        static boolean stuck(boolean found, int pid, long restartingAt) {
            return found && pid == 0 && restartingAt != 0;
        }

        /** Recover only when both reads saw it stuck. */
        static boolean recover(boolean firstStuck, boolean secondStuck) {
            return firstStuck && secondStuck;
        }

        /** Seconds to the scheduled restart, 0 when it is past, -1 when none is scheduled. */
        static long nextSeconds(long restartingAt, long nowUptime) {
            if (restartingAt == 0) return -1;
            return Math.max(0, (restartingAt - nowUptime) / 1000);
        }

        /** True only for a word of ORDER. */
        static boolean accepted(String kind) {
            if (kind == null) return false;
            for (String k : ORDER) if (k.equals(kind)) return true;
            return false;
        }

        /** True when the serial read before the watch is a real one and the user still has it now. A serial that
         *  cannot be read (-1) is never a match, even against another -1: resendList is empty for it, so a stop would
         *  drop the pending starts and send none back. */
        static boolean sameSession(long before, long now) {
            return before >= 0 && before == now;
        }

        /** One read of user uid's CredentialService. getRunningServices can list one record twice: ActiveServices
         *  lists the service map first (restarting = 0) and then the restart list (restarting = the scheduled time).
         *  So every matching entry is added: a pid from any entry marks it running, a restart time from any entry
         *  marks it scheduled. */
        static final class Seen {
            boolean found;
            int pid;
            long restartingAt;

            void add(int entryPid, long entryRestarting) {
                found = true;
                if (entryPid != 0) pid = entryPid;
                if (entryRestarting != 0) restartingAt = entryRestarting;
            }
        }

        /** The stop and the re-sends, so that the trace can count them when one throws. */
        interface Ops {
            void stop() throws Exception;
            boolean start(String kind) throws Exception;
        }

        /** Stop the service, then start each kind. Counts each start that returned a component into t.resent. A throw
         *  ends the recovery: t.tail becomes " err", the starts done so far stay counted, and the throw is returned
         *  (null when none). */
        static Throwable resend(Ops ops, String[] kinds, Trace t) {
            try {
                ops.stop();
                for (String kind : kinds) if (ops.start(kind)) t.resent++;
                return null;
            } catch (Throwable e) {
                t.tail = " err";
                return e;
            }
        }

        /** What one watch saw and did: the one login.log line. Integers and closed words only. */
        static final class Trace {
            boolean found;
            boolean stuck;
            long next = -1;
            int resent;
            String tail = "";

            void saw(Seen s, boolean isStuck, long nowUptime) {
                found = s != null && s.found;
                stuck = isStuck;
                next = s == null ? -1 : nextSeconds(s.restartingAt, nowUptime);
            }

            String line(int uid) {
                return "credsvc-watch u=" + uid + " found=" + (found ? 1 : 0) + " stuck=" + (stuck ? 1 : 0)
                        + " next=" + next + " resent=" + resent + tail;
            }
        }

        /** One run of a kind at a time in this process. The watch can re-send a start while the first run still
         *  works (the service came up between the watch's second read and its stop, and a stop does not end a worker
         *  thread). Two Ingest.run workers would pass the same receipt and exists checks and insert each row twice. */
        static final class Flight {
            private final java.util.Set<String> running = new java.util.HashSet<>();

            synchronized boolean begin(String kind) {
                return running.add(kind);
            }

            synchronized void end(String kind) {
                running.remove(kind);
            }

            /** Run r unless a run of kind is in progress here; true when r ran. */
            boolean runOnce(String kind, Runnable r) {
                if (!begin(kind)) return false;
                try {
                    r.run();
                } finally {
                    end(kind);
                }
                return true;
            }
        }

        /** What this gate process started in each session user, keyed by (uid, serial). */
        static final class Sent {
            private final java.util.Map<Integer, Long> serials = new java.util.HashMap<>();
            private final java.util.Map<Integer, java.util.Set<String>> kinds = new java.util.HashMap<>();
            private final java.util.Set<Integer> watching = new java.util.HashSet<>();

            /** Record kind for uid. A new serial (a new session on a reused id) starts the set again. */
            synchronized boolean sent(int uid, long serial, String kind) {
                if (!accepted(kind)) return false;
                final Long s = serials.get(uid);
                if (s == null || s != serial) {
                    kinds.remove(uid);
                    serials.put(uid, serial);
                }
                kinds.computeIfAbsent(uid, k -> new java.util.HashSet<>()).add(kind);
                return true;
            }

            /** The recorded kinds in ORDER, each once; empty for an unknown uid or a serial that is not the stored one. */
            synchronized String[] resendList(int uid, long serial) {
                final Long s = serials.get(uid);
                final java.util.Set<String> k = kinds.get(uid);
                if (serial < 0 || s == null || s != serial || k == null) return new String[0];
                final java.util.List<String> out = new java.util.ArrayList<>();
                for (String w : ORDER) if (k.contains(w)) out.add(w);
                return out.toArray(new String[0]);
            }

            /** Single flight: false when a watch for uid already runs. */
            synchronized boolean begin(int uid) {
                return watching.add(uid);
            }

            synchronized void end(int uid) {
                watching.remove(uid);
            }
        }
    }

    private static final Rule.Sent SENT = new Rule.Sent();
    private static final Rule.Flight IN_PROCESS = new Rule.Flight();

    /** User uid's serial number, or -1 when it cannot be read (or the user is gone). ChooserActivity.userSerial is a
     *  private instance method; kickGosState and RestartRearm are static. */
    static long serial(final android.content.Context ctx, final int uid) {
        try {
            return ctx.getSystemService(android.os.UserManager.class).getSerialNumberForUser(android.os.UserHandle.of(uid));
        } catch (Throwable t) {
            return -1;
        }
    }

    /** Record that this gate process started CredentialService with kind in user uid. Never throws. */
    static void record(final android.content.Context app, final int uid, final String kind) {
        try {
            SENT.sent(uid, serial(app, uid), kind);
        } catch (Throwable t) {
            android.util.Log.w(TAG, "credsvc-watch: record for user " + uid, t);
        }
    }

    /** CredentialService's side: run r for kind unless a run of kind is already in progress in this process. */
    static void runOnce(final String kind, final Runnable r) {
        if (!IN_PROCESS.runOnce(kind, r)) {
            android.util.Log.i(TAG, "credsvc-watch: " + kind + " already runs in this process, this start skips it"
                    + " (NWP-20261203-05)");
        }
    }

    /** Read user uid's CredentialService from ActivityManager (the gate holds INTERACT_ACROSS_USERS_FULL, so it sees
     *  every user's services, the restarting ones included). RunningServiceInfo.restarting is the scheduled restart
     *  time in uptime millis, 0 when none. Every matching entry counts (Rule.Seen). Throws when the read fails. */
    private static Rule.Seen read(final android.content.Context app, final int uid) {
        final android.app.ActivityManager am = app.getSystemService(android.app.ActivityManager.class);
        final String pkg = app.getPackageName();
        final android.content.ComponentName cn = new android.content.ComponentName(pkg, pkg + ".CredentialService");
        final Rule.Seen seen = new Rule.Seen();
        for (android.app.ActivityManager.RunningServiceInfo info : am.getRunningServices(500)) {
            if (cn.equals(info.service) && android.os.UserHandle.getUserId(info.uid) == uid) {
                seen.add(info.pid, info.restarting);
            }
        }
        return seen;
    }

    /** Watch user uid's CredentialService once, on one thread, and free it when both reads see it stuck. why goes to
     *  logcat only. Every watch that starts its thread writes one login.log line, whatever throws. */
    static void watch(final android.content.Context app, final int uid, final String why) {
        if (uid < 10 || !SENT.begin(uid)) return;
        final long s0 = serial(app, uid);
        new Thread(() -> {
            final Rule.Trace tr = new Rule.Trace();
            try {
                Thread.sleep(Rule.FIRST_MS);
                Rule.Seen last = null;
                try { last = read(app, uid); } catch (Throwable t) {
                    tr.tail = " err";
                    android.util.Log.w(TAG, "credsvc-watch (" + why + "): first read for user " + uid, t);
                }
                final boolean stuck1 = last != null && Rule.stuck(last.found, last.pid, last.restartingAt);
                tr.saw(last, stuck1, android.os.SystemClock.uptimeMillis());
                if (stuck1) {
                    Thread.sleep(Rule.CONFIRM_MS);
                    if (!Rule.sameSession(s0, serial(app, uid))) {
                        tr.tail = " skip"; // the session ended, its id was reused, or its serial cannot be read
                    } else {
                        try { last = read(app, uid); } catch (Throwable t) {
                            last = null;
                            tr.tail = " err";
                            android.util.Log.w(TAG, "credsvc-watch (" + why + "): second read for user " + uid, t);
                        }
                        final boolean stuck2 = last != null && Rule.stuck(last.found, last.pid, last.restartingAt);
                        tr.saw(last, stuck2, android.os.SystemClock.uptimeMillis());
                        // Nothing but this test sits between the second read and the stop.
                        if (Rule.recover(stuck1, stuck2)) {
                            final Throwable bad = Rule.resend(new Rule.Ops() {
                                @Override public void stop() {
                                    app.createContextAsUser(android.os.UserHandle.of(uid), 0)
                                            .stopService(new android.content.Intent(app, CredentialService.class));
                                }

                                @Override public boolean start(String kind) {
                                    return app.startServiceAsUser(new android.content.Intent(app, CredentialService.class)
                                            .putExtra(kind, true), android.os.UserHandle.of(uid)) != null;
                                }
                            }, SENT.resendList(uid, s0), tr);
                            if (bad != null) {
                                android.util.Log.w(TAG, "credsvc-watch (" + why + "): recover for user " + uid, bad);
                            }
                        }
                    }
                }
            } catch (Throwable t) {
                tr.tail = " err";
                android.util.Log.w(TAG, "credsvc-watch (" + why + ") user " + uid, t);
            } finally {
                try {
                    android.util.Log.i(TAG, "credsvc-watch (" + why + ") user " + uid + " stuck=" + tr.stuck
                            + " resent=" + tr.resent + tr.tail + " (NWP-20261203-05)");
                    ChooserActivity.idleTrace(tr.line(uid));
                } catch (Throwable t) {
                    android.util.Log.w(TAG, "credsvc-watch: trace for user " + uid, t);
                }
                SENT.end(uid);
            }
        }, "nowhere-credsvc-watch").start();
    }
}
