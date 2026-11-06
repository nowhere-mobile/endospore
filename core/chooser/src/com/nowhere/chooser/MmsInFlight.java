package com.nowhere.chooser;

import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

/**
 * Bookkeeping for gate MMS downloads (#150): which downloads are live, how many are live PER SIM, and which
 * carrier transaction ids were already claimed. java.* only, so a javac suite can run it off the device.
 *
 * <p>The MMS data policy (a persistent per-subscription setting) is switched by the {@link Policy} handed to
 * {@link #register}, {@link #finish} and {@link #resetIdle}. That call is made INSIDE the lock: with it outside,
 * download A's "off" could land after download B's "on" on the same SIM, and B would run with the policy off (a
 * silent download timeout). A Policy must not call back into MmsInFlight.
 */
final class MmsInFlight {
    private MmsInFlight() {}

    /** Switches the MMS data policy of one SIM. Called with MmsInFlight's lock held. */
    interface Policy { void set(int subId, boolean on); }

    static final long TXN_WINDOW_MS = 12 * 60 * 60_000L; // dedup horizon; re-pushes span hours, < a session

    private static final Object LOCK = new Object();
    private static final Map<String, Integer> IN_FLIGHT = new HashMap<>();  // download name -> subId it registered with
    private static final Map<Integer, Integer> REFS = new HashMap<>();      // subId -> live downloads
    private static final Map<String, Long> TXN_SEEN = new HashMap<>();      // txn -> ms of the claim

    /** Claim a transaction-id for this download attempt. True if newly claimed (proceed), false if it is
     *  already in flight or was recently delivered (a duplicate re-push to skip). Prunes stale entries.
     *  A null or empty id cannot be de-duplicated: true, nothing stored. */
    static boolean claimTxn(String txn, long nowMs) {
        if (txn == null || txn.isEmpty()) return true;
        synchronized (LOCK) {
            for (Iterator<Long> it = TXN_SEEN.values().iterator(); it.hasNext(); ) {
                if (nowMs - it.next() > TXN_WINDOW_MS) it.remove();
            }
            return TXN_SEEN.putIfAbsent(txn, nowMs) == null;
        }
    }

    /** Release a transaction-id after a FAILED download so the carrier's next re-push retries it. */
    static void releaseTxn(String txn) {
        if (txn == null || txn.isEmpty()) return;
        synchronized (LOCK) { TXN_SEEN.remove(txn); }
    }

    /** Record a live download on {@code subId}; the SIM's first one switches its policy on. */
    static void register(String name, int subId, Policy p) {
        synchronized (LOCK) {
            IN_FLIGHT.put(name, subId);
            int n = REFS.merge(subId, 1, Integer::sum);
            if (n == 1) p.set(subId, true);
        }
    }

    /** End a download exactly once. False when {@code name} was not registered (already finished, or never
     *  was); otherwise true, and the last download of the SIM it registered with switches that SIM's policy off. */
    static boolean finish(String name, Policy p) {
        synchronized (LOCK) {
            Integer subId = IN_FLIGHT.remove(name);
            if (subId == null) return false;
            int left = REFS.merge(subId, -1, Integer::sum);
            if (left <= 0) {
                REFS.remove(subId);
                p.set(subId, false);
            }
            return true;
        }
    }

    /** Switch the MMS data policy OFF on every SIM in {@code subIds} that has no download registered; returns how
     *  many it switched. Called at process start: the policy is a persistent per-subscription setting and outlives
     *  the process, the count does not, so a process that died inside a download (a crash, a low-memory kill, power
     *  loss) left the policy on with nothing left to turn it off. A SIM with a download registered is skipped: its
     *  own finish turns it off. Holding LOCK orders this against a register that races the process start, either
     *  way round: a register before it is counted here and skipped, a register after it switches the policy back on. */
    static int resetIdle(Iterable<Integer> subIds, Policy p) {
        synchronized (LOCK) {
            int n = 0;
            for (Integer subId : subIds) {
                if (subId == null || REFS.getOrDefault(subId, 0) != 0) continue;
                p.set(subId, false);
                n++;
            }
            return n;
        }
    }

    static boolean inFlight(String name) {
        synchronized (LOCK) { return IN_FLIGHT.containsKey(name); }
    }

    static int refs(int subId) {
        synchronized (LOCK) { return REFS.getOrDefault(subId, 0); }
    }

    /** Tests only: forget every download and claim. */
    static void reset() {
        synchronized (LOCK) { IN_FLIGHT.clear(); REFS.clear(); TXN_SEEN.clear(); }
    }
}
