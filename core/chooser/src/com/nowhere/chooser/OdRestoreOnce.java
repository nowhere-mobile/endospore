package com.nowhere.chooser;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** NWP-20261202-38: one restore per install of a package.
 *
 *  After installApks, UnarchiveService.materializeLocked sends RESTORE-ODDATA, and the same install's PACKAGE_ADDED
 *  makes AppInstallReceiver.heal send another one at the same time. Only the first does any work. Each later one
 *  answers `OK NOSRC`, but roamd's odrestore op still runs grant_perms_for, keystore_register and the reown for it.
 *
 *  THE RULE: a package gets one restore per install, per session chooser process. An install is identified by its
 *  PackageInfo.lastUpdateTime, which is the moment of the materialise (UnarchiveService.installStamp; ReArchiveReceiver
 *  reads the same field). A sender that comes later finds the restore landed or in flight, sends nothing and gets that
 *  restore's reply. A non-OK reply records nothing, so HealRetry and the sweep's retries still send. A new install or
 *  an update has a new stamp and gets its own restore, so the heal's INTERNET grant on a Play update is kept. If the
 *  stamp cannot be read (-1), the restore is always sent.
 *
 *  sendShared is the one exception, for the launch barrier's retry (NOWHERE-1687): it runs only while the daemon says
 *  the app's data is still out, so a landed OK must not hold for it, and it only shares an in-flight send. With send,
 *  an app that answered OK while its data was still out would stay suspended for the whole process.
 *
 *  ChooserActivity.installRoamedAppCode is NOT wrapped: it is the user-0 gate's sign-in restore, which runs in another
 *  process (the gate's chooser, not the roamed user's), so these maps cannot see it, and it sends before any session
 *  sender exists.
 *
 *  The record lives in this process only: a process death forgets it, and the next sender just sends. Pure java.util so
 *  test-od-restore-once-java.sh compiles it alone. The log lines name no package. */
final class OdRestoreOnce {
    private OdRestoreOnce() {}

    /** How long a later sender waits for an in-flight send: the heal's own 130 s round trip. A timeout returns "". */
    static long waitMs = 130_000L;

    private static final Object LOCK = new Object();
    private static final Map<String, Landed> LANDED = new HashMap<>();
    private static final Map<String, Flight> FLIGHT = new HashMap<>();
    private static final Map<String, Integer> WAITING = new HashMap<>();

    private static final class Landed {
        final long stamp;
        final String reply;
        Landed(long stamp, String reply) { this.stamp = stamp; this.reply = reply; }
    }

    private static final class Flight {
        final long stamp;
        final CompletableFuture<String> done = new CompletableFuture<>();
        Flight(long stamp) { this.stamp = stamp; }
    }

    /** One restore of pkg for this install: a landed OK of the same stamp, or a send of it in flight, is returned
     *  and the sender is not called. The reply is trimmed; no reply is "". */
    static String send(String pkg, long stamp, Supplier<String> sender, Consumer<String> log) {
        return run(pkg, stamp, sender, log, true);
    }

    /** As send, minus the landed check: it joins an in-flight send, else sends. For a sender that runs only while the
     *  daemon says the data is out (the barrier's retry): a landed OK must not stop it. */
    static String sendShared(String pkg, long stamp, Supplier<String> sender, Consumer<String> log) {
        return run(pkg, stamp, sender, log, false);
    }

    /** The list path's reply for one package: recorded only when it is OK and the stamp was read. */
    static void record(String pkg, long stamp, String reply) {
        String r = trim(reply);
        synchronized (LOCK) {
            if (stamp >= 0 && landsOk(r)) LANDED.put(pkg, new Landed(stamp, r));
        }
    }

    static void resetForTest() {
        synchronized (LOCK) {
            LANDED.clear();
            FLIGHT.clear();
            WAITING.clear();
        }
        waitMs = 130_000L;
    }

    /** The later senders now waiting on pkg's in-flight send (a test hook). */
    static int waiting(String pkg) {
        synchronized (LOCK) {
            return WAITING.getOrDefault(pkg, 0);
        }
    }

    private static String trim(String s) {
        return s == null ? "" : s.trim();
    }

    /** Only an OK reply is a landed restore: anything else records nothing, so every retry still sends. */
    private static boolean landsOk(String r) {
        return r.startsWith("OK");
    }

    private static void say(Consumer<String> log, String m) {
        if (log != null) log.accept(m);
    }

    private static String run(String pkg, long stamp, Supplier<String> sender, Consumer<String> log, boolean landedHolds) {
        if (stamp < 0) return trim(sender.get()); // no stamp: always sent, never claimed, never recorded
        Flight mine;
        while (true) {
            Flight other;
            String landedReply = null;
            synchronized (LOCK) {
                Landed l = LANDED.get(pkg);
                if (landedHolds && l != null && l.stamp == stamp) landedReply = l.reply;
                other = landedReply != null ? null : FLIGHT.get(pkg);
                if (landedReply == null && other == null) {
                    mine = new Flight(stamp);
                    FLIGHT.put(pkg, mine);
                    break;
                }
                if (other != null) WAITING.merge(pkg, 1, Integer::sum);
            }
            if (landedReply != null) {
                say(log, "od-restore-once: this install's restore already landed -- not sent again (NWP-20261202-38)");
                return landedReply;
            }
            if (other.stamp == stamp)
                say(log, "od-restore-once: another sender's restore of this app is in flight -- sharing its reply (NWP-20261202-38)");
            String r;
            try {
                r = other.done.get(waitMs, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return "";
            } catch (Exception e) { // the timeout: "" unsent
                return "";
            } finally {
                synchronized (LOCK) {
                    WAITING.computeIfPresent(pkg, (k, n) -> n <= 1 ? null : n - 1);
                }
            }
            if (other.stamp == stamp) return r;
            // another install's restore: loop, re-check landed, then claim and send this one. Its sender has answered,
            // so a claim it left behind is stale and must not make this loop spin.
            synchronized (LOCK) {
                FLIGHT.remove(pkg, other);
            }
        }
        String reply = "";
        try {
            reply = trim(sender.get());
            return reply;
        } finally {
            synchronized (LOCK) {
                if (landsOk(reply)) LANDED.put(pkg, new Landed(stamp, reply));
                if (FLIGHT.get(pkg) == mine) FLIGHT.remove(pkg);
            }
            mine.done.complete(reply);
        }
    }
}
