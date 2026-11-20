package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * NWP-20261210-14: the read cap of one daemon request, chosen by its verb. The chooser's socket helper bounds only
 * the connect: a connect that lands in a wedged daemon's listen backlog (not yet full) succeeds, and the caller's
 * read then waits out the whole read cap. With one 90 s cap for every verb, the Your data screen waited 90 s per
 * poll read on a stopped daemon before it could show its failure copy.
 *
 * A verb is QUICK only when both hold, checked in core/agent/main.go:
 *   (a) concurrentSafeCmd lists it, so its handler never waits on sessionMu behind a seal or a delete;
 *   (b) its handler does no store, gateway or network I/O, starts no worker op, and has no internal wait near the cap.
 * A QUICK verb's read waits {@link #SHORT_MS}. Every other request -- an unknown verb, null, "", and every store or
 * session verb -- keeps {@link #LONG_MS}: a verb that can wait behind a seal for minutes must keep the long cap, or a
 * slow answer becomes a wrong one (the DaemonReply comment in ProfileActivity).
 *
 * QUICK, with each handler's place in main.go (the `if name == "VERB"` arm in handleLogin):
 *   SEAL-STATUS       (handler ~:13225) composeSealStatus copies RAM seal state under pendingReapMu and reads the
 *                     roam.progress file in the session's tmpfs dir; nothing else.
 *   GET-SYNC-INTERVAL (handler ~:13581) syncIntervalGet reads one local file and an environment fallback.
 *   GET-SEAL-LANDED   (handler ~:13634) writes the atomic lastLandedSealStartedAt.
 * Add a verb only with the same two checks and a line here; the suite core/chooser/test-daemon-read-cap-java.sh
 * refuses a QUICK verb that concurrentSafeCmd does not list.
 *
 * The cap is per read: a streamed reply restarts it on every line. java.* only, so a plain javac can test it.
 */
final class DaemonReadCap {
    static final int SHORT_MS = 10000; // a lock-free, store-free local answer; this only bites a wedged daemon
    static final int LONG_MS = 90000; // the cap every daemon read had before NWP-20261210-14

    static final Set<String> QUICK = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            "SEAL-STATUS",
            "GET-SYNC-INTERVAL",
            "GET-SEAL-LANDED")));

    private DaemonReadCap() {}

    /** The read cap, in ms, for request {@code msg}: SHORT_MS when its verb (the first line, trimmed -- the socket
     *  helper's verbOf rule) is exactly a QUICK verb, case-sensitive; LONG_MS for everything else. */
    static int forRequest(String msg) {
        if (msg == null) return LONG_MS;
        String verb = msg.split("\n", 2)[0].trim();
        return QUICK.contains(verb) ? SHORT_MS : LONG_MS;
    }
}
