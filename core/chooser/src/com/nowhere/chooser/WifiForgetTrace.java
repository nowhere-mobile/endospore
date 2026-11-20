package com.nowhere.chooser;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.IntPredicate;

/** NWP-20261205-17: evidence for Q027's lynx repro (docs/product-decisions.md, 2026-10-20). A Wi-Fi network forgotten
 *  at the gate can come back, and Q027 names three paths that can re-add it: an adopt pass still running, an
 *  in-session capture that landed after the gate collected the queue, or a parked session that captured its own copy
 *  again. This class lets the gate's Forget and maybeMirrorWifi name which path ran, through gate.log's closed verbs
 *  (core/agent/gate_log.go). Pure java.util so it runs under plain javac
 *  (core/vendor-common/bin/test-wifi-forget-trace-java.sh).
 *
 *  <p>⚠ Q027 FORBIDS A DURABLE RECORD OF A FORGOTTEN NETWORK, so the set lives in RAM and dies with the chooser
 *  process. Nothing here is written, logged or sent: only a verb from the pickers below and one clamped count leave
 *  it, through GateTrace. No SSID ever reaches gate.log, logcat or a report.
 *
 *  <p>Known limit: a network the owner forgets and then joins again at the gate stays in the set, so a later mirror
 *  re-add of it counts as a re-add. The repro does not join again. */
final class WifiForgetTrace {
    private WifiForgetTrace() {}

    /** The largest count a line carries (gate_log.go's `n`, 0..32). */
    static final int MAX_COUNT = 32;

    private static final Set<String> FORGOTTEN = ConcurrentHashMap.newKeySet();
    private static final AtomicInteger IN_FLIGHT = new AtomicInteger();

    /** Record an SSID (unquoted) the gate forgot in this chooser process. A null or empty SSID is ignored. */
    static void forgot(String ssid) {
        if (ssid == null || ssid.isEmpty()) return;
        FORGOTTEN.add(ssid);
    }

    /** How many DISTINCT SSIDs in {@code added} the gate forgot. One network added twice is one network. */
    static int readdCount(List<String> added) {
        if (added == null) return 0;
        HashSet<String> seen = new HashSet<>();
        for (String s : added) {
            if (s != null && FORGOTTEN.contains(s)) seen.add(s);
        }
        return seen.size();
    }

    /** The SSID (unquoted) of a configured network id, or null. forgetWifi reads the configured-network list. */
    interface SsidLookup {
        String ssidOf(int netId);
    }

    /** forgetWifi's WifiForget.Ops.remove: looks the SSID up by the very id WifiForget.run passes to remove, just
     *  before the removal (a removed network is no longer in the configured list), then removes it. The connection
     *  can change between two reads of the connected id, so the SSID is never read by an id of its own.
     *  {@code removed[0]} holds the SSID only when this removal succeeded; a lookup that throws leaves it null and
     *  does not change the Forget. Returns the removal's own result. */
    static boolean removeAndLookup(int netId, IntPredicate remove, SsidLookup lookup, String[] removed) {
        removed[0] = null;
        String ssid = null;
        try {
            ssid = lookup.ssidOf(netId);
        } catch (RuntimeException e) {
            // the trace is evidence only: a failed lookup records nothing
        }
        boolean ok = remove.test(netId);
        removed[0] = ok ? ssid : null;
        return ok;
    }

    static void adoptStarted() { IN_FLIGHT.incrementAndGet(); }

    /** Never below 0: a finish without a start does not go negative. */
    static void adoptFinished() { IN_FLIGHT.updateAndGet(v -> v > 0 ? v - 1 : 0); }

    /** The number of maybeMirrorWifi adopt runs in flight. */
    static int inFlight() { return IN_FLIGHT.get(); }

    /** A Forget the framework refused, a Forget while an adopt run is in flight (Q027 path 1), or a plain Forget. */
    static String forgetVerb(boolean ok, int inFlight) {
        if (!ok) return "wifi-forget-err";
        if (inFlight > 0) return "wifi-forget-midadopt";
        return "wifi-forget";
    }

    /** A queue collected while a session is cold-locked (path 3), or with none parked (path 2). */
    static String collectVerb(boolean parked) {
        return parked ? "wifi-collect-parked" : "wifi-collect";
    }

    /** Pass 0 re-adds from a freshly collected queue (paths 2 and 3); passes 1 and 2 are a run still going (path 1). */
    static String readdVerb(int pass) {
        return pass <= 0 ? "wifi-readd" : "wifi-readd-late";
    }

    static int clampCount(int n) {
        return n < 0 ? 0 : n > MAX_COUNT ? MAX_COUNT : n;
    }
}
