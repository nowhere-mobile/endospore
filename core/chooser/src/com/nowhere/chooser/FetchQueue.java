package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

/** NWP-20261210-20: the download notification's outstanding set and its "(n of m)", as a pure class (java.* only), so a
 *  javac suite (test-fetch-queue-java.sh) can run it off the build host. UnarchiveService's q* helpers wrap one static
 *  instance; NWP-20260822-12's rule stays: ONE set, shared by every producer (the tap worker, a remembered tap, the
 *  Auto sweep), owns the count.
 *
 *  Backlog row 'The download notification's "(n of m)" can count one app twice, and starts without the Play-stack deps
 *  the landing card already counts' (section B). The set this replaces counted any removed member as done and let a
 *  done member join again, so a tap that finished S and a sweep that queued S again read "(2 of 3)" for two apps. It
 *  also lost the done count on a drain, so a Pause and Resume of one sweep counted "2 of 7" against the card's "1 of 8".
 *
 *  A batch is: pending (in order, each member with a holder count: one per producer that queued it), finished, current
 *  (the member that runs now) and a key (the landing card's sweep id; 0 = none). The rules:
 *  - enqueue: a member finished in this batch is ignored (no double count); a pending one gains a holder; a new one is
 *    appended with one holder.
 *  - start: the member becomes current; it is appended (one holder) only when it is neither pending nor finished, so a
 *    finished member is named again but never counted again.
 *  - finish: a pending member moves to finished, whatever its holders; an absent or finished one is a no-op. It clears
 *    current when it is that member.
 *  - release: one holder fewer per member, never below 0; at 0 the member leaves pending UNCOUNTED. An absent or
 *    finished member is a no-op: an exit that ran nothing takes back only its own claim.
 *  - when pending is empty after a finish or a release, the batch ends: finished, current and the key clear, so the next
 *    batch counts from 1. A non-zero key's finished set is first remembered under that key (one is remembered; a key-0
 *    batch never overwrites it).
 *  - batch(k): sets the key. When k is non-zero and equals the remembered key, the remembered members that are not
 *    pending go back into finished and the record is forgotten: a Resume of the same card keeps its total.
 *  - clear: pending, finished, current and the key clear; the remembered batch is kept (the service stops between a
 *    Pause and its Resume). */
final class FetchQueue {

    /** One read of the queue for the notification, taken under the queue's lock. */
    static final class Snapshot {
        /** The member that runs now, or null. */
        final String current;
        /** The member the notification names: current, else the first pending; null when nothing is outstanding. */
        final String named;
        /** finished + 1, capped at total. */
        final int position;
        /** finished + pending. */
        final int total;
        /** The pending members other than named, in order. */
        final List<String> rest;

        Snapshot(String current, String named, int position, int total, List<String> rest) {
            this.current = current;
            this.named = named;
            this.position = position;
            this.total = total;
            this.rest = rest;
        }
    }

    private final LinkedHashMap<String, Integer> pending = new LinkedHashMap<>();
    private final LinkedHashSet<String> finished = new LinkedHashSet<>();
    private String current;
    private long key;
    private long rememberedKey;
    private final LinkedHashSet<String> remembered = new LinkedHashSet<>();

    synchronized void enqueue(Collection<String> pkgs) {
        if (pkgs == null) return;
        for (String p : pkgs) {
            if (p == null || finished.contains(p)) continue;
            Integer h = pending.get(p);
            pending.put(p, h == null ? 1 : h + 1);
        }
    }

    synchronized void start(String pkg) {
        current = pkg;
        if (pkg != null && !pending.containsKey(pkg) && !finished.contains(pkg)) pending.put(pkg, 1);
    }

    synchronized void finish(String pkg) {
        if (pkg != null && pending.remove(pkg) != null) finished.add(pkg);
        if (pkg != null && pkg.equals(current)) current = null;
        endIfDrained();
    }

    synchronized void release(Collection<String> pkgs) {
        if (pkgs != null) {
            for (String p : pkgs) {
                Integer h = p == null ? null : pending.get(p);
                if (h == null) continue;
                if (h <= 1) pending.remove(p);
                else pending.put(p, h - 1);
            }
        }
        endIfDrained();
    }

    synchronized void batch(long k) {
        key = k;
        if (k != 0 && k == rememberedKey) {
            for (String p : remembered) if (!pending.containsKey(p)) finished.add(p);
            remembered.clear();
            rememberedKey = 0;
        }
    }

    synchronized void clear() {
        pending.clear();
        finished.clear();
        current = null;
        key = 0;
    }

    synchronized String current() {
        return current;
    }

    synchronized int pendingSize() {
        return pending.size();
    }

    synchronized Snapshot snapshot() {
        String named = current;
        if (named == null) {
            for (String p : pending.keySet()) { named = p; break; }
        }
        int total = finished.size() + pending.size();
        int position = Math.min(finished.size() + 1, total);
        List<String> rest = new ArrayList<>();
        for (String p : pending.keySet()) if (!p.equals(named)) rest.add(p);
        return new Snapshot(current, named, position, total, Collections.unmodifiableList(rest));
    }

    /** The batch ends when nothing is pending; a keyed batch's finished set is remembered for its Resume. */
    private void endIfDrained() {
        if (!pending.isEmpty()) return;
        if (key != 0) {
            rememberedKey = key;
            remembered.clear();
            remembered.addAll(finished);
        }
        finished.clear();
        current = null;
        key = 0;
    }
}
