package com.nowhere.chooser;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Bounded round-trips to the login daemon's LocalSocket (#77). {@link LocalSocket} has NO connect timeout
 * ({@code setSoTimeout} is the READ timeout only), so a wedged daemon -- its accept loop stuck in a store
 * retry, or the process stopped -- blocks {@code connect()} for as long as the daemon does not accept. On the
 * idle/wipe alarm that reached the 60s background-broadcast ANR and KILLED the persistent gate process (bounded
 * separately in {@link IdleLogoffReceiver}); on every other path it silently hung the caller's worker thread: a
 * stalled reap poll (a queued logoff never reaps), a skipped 12h hard-wipe (a security backstop that never fires),
 * or a UI action that spins with no error.
 *
 * {@link #connect} runs the connect on a helper thread and the CALLER waits at most {@link #CONNECT_CAP_MS}, so the
 * caller's bound does not depend on anything unblocking the connect (NWP-20261203-06). The old bound closed the
 * socket from a watchdog at the cap; that unblocked the connect on the FP3 (#77), but on lynx (S8, build
 * 2026111001, 2026-11-11) a connect pending on a stopped daemon's FULL listen backlog ignored the close, and chooser
 * calls hung for minutes. A wedged connect now strands one daemon thread until the daemon accepts or dies; its
 * socket is closed when that connect returns. A connect takes one of {@link #MAX_STRANDED} slots for as long as it is
 * pending, so at most MAX_STRANDED connects (and threads) are ever pending, however many callers arrive together.
 * Once MAX_STRANDED abandoned connects are still pending, connect() returns null at once. A wedged daemon yields a
 * "" reply / empty list and the caller retries. All callers already run off the main thread, so the bounded
 * blocking here is safe.
 */
final class DaemonSocket {
    static final String SOCKET = "nowhere_login";
    static final int CONNECT_CAP_MS = 8000; // healthy connect is instant; this only bites a wedged daemon
    static final int MAX_STRANDED = 4; // abandoned connects still pending, past which connect() fails fast
    static final AtomicInteger STRANDED = new AtomicInteger(); // abandoned connects whose helper thread still waits
    static final Semaphore SLOTS = new Semaphore(MAX_STRANDED); // one per pending connect, abandoned or not
    private static final AtomicBoolean STRANDED_WARNED = new AtomicBoolean(false); // one fail-fast log line per episode
    private static final int PENDING = 0;
    private static final int CONNECTED = 1;
    private static final int FAILED = 2;
    private static final int ABANDONED = 3;

    private DaemonSocket() {}

    /** Connect with a bounded wait. Returns a connected socket (the caller sets its own read timeout and does its
     *  own I/O), or null if the daemon did not accept within {@link #CONNECT_CAP_MS}, refused, or the connect could
     *  not start: {@link #MAX_STRANDED} earlier connects are still stuck (then it returns null at once, with no socket
     *  and no thread), or all MAX_STRANDED slots stayed taken for the whole cap. A connect holds one slot from before
     *  its socket exists until it returns, so at most MAX_STRANDED are pending, however many callers arrive together.
     *  The connect runs on a "nowhere-daemon-connect" daemon thread; one {@code state}, moved only by compareAndSet,
     *  decides who owns the socket. The caller NEVER closes a socket whose connect is pending (on a real LocalSocket
     *  the close can wait on the lock the connect holds): the helper thread closes it when its connect returns. */
    static LocalSocket connect() {
        int n = STRANDED.get();
        if (n >= MAX_STRANDED) return refuse(n); // fail fast while wedged
        final long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(CONNECT_CAP_MS);
        boolean slot;
        try {
            slot = SLOTS.tryAcquire(CONNECT_CAP_MS, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) { // counts as the cap passing
            Thread.currentThread().interrupt();
            return null;
        }
        if (!slot) return refuse(MAX_STRANDED); // every slot held by a connect pending for the whole cap
        final LocalSocket s;
        try {
            s = new LocalSocket();
        } catch (Throwable e) {
            SLOTS.release();
            return null;
        }
        final AtomicInteger state = new AtomicInteger(PENDING);
        final CountDownLatch done = new CountDownLatch(1);
        Thread t = new Thread(() -> {
            boolean ok = false;
            try {
                s.connect(new LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.RESERVED));
                ok = true;
            } catch (Throwable e) {
                // FAILED, or the caller has already abandoned it
            }
            if (state.compareAndSet(PENDING, ok ? CONNECTED : FAILED)) {
                if (!ok) { try { s.close(); } catch (Throwable ignore) {} } // the connect threw
                SLOTS.release(); // the connect is no longer pending
                done.countDown();
                return;
            }
            try { s.close(); } catch (Throwable ignore) {} // abandoned: the caller has gone, close it now
            SLOTS.release();
            if (STRANDED.decrementAndGet() < MAX_STRANDED) STRANDED_WARNED.set(false); // a stranded connect returned
        }, "nowhere-daemon-connect");
        t.setDaemon(true);
        try {
            t.start();
        } catch (Throwable e) { // no thread: no connect is pending, so closing here cannot wait on it
            try { s.close(); } catch (Throwable ignore) {}
            SLOTS.release();
            return null;
        }
        boolean in;
        try {
            in = done.await(Math.max(0L, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
        } catch (InterruptedException e) { // counts as the cap passing
            Thread.currentThread().interrupt();
            in = false;
        }
        if (!in) {
            STRANDED.incrementAndGet(); // before the CAS, so the helper never decrements a count not yet raised
            if (state.compareAndSet(PENDING, ABANDONED)) return null; // the cap passed: never close s here
            STRANDED.decrementAndGet(); // the helper settled first
        }
        return state.get() == CONNECTED ? s : null;
    }

    /** connect()'s refusal: null, and the episode's one count-only log line (no verb, no profile). */
    private static LocalSocket refuse(int n) {
        if (STRANDED_WARNED.compareAndSet(false, true)) // "connect" + "(s)": test-daemon-verb-readers.sh reads connect( as a call
            android.util.Log.w("NowhereChooser", "daemon connect: " + n + " connect" + "(s) stuck past the "
                    + CONNECT_CAP_MS + " ms cap -- failing fast until one returns (NWP-20261203-06)");
        return null;
    }

    /** NWP-20260904-07: a LENGTH-FRAMED reply -- "OK <n>" then n bytes -- for SEAL-DELTA and friends. This is
     *  the static twin of ProfileActivity.daemonLenReply: the post-login sweep runs in UnarchiveService with
     *  no activity to call an instance method on. Returns {header, body-or-null}; a non-OK header, a bad
     *  length, or a short read all yield a null body, which every caller must treat as "unknown", never as
     *  "empty". Uses connect() so a wedged daemon cannot hang the caller past CONNECT_CAP_MS. */
    static String[] lenReply(String msg, int readCapMs) {
        LocalSocket s = connect();
        if (s == null) return new String[]{"", null};
        try {
            s.setSoTimeout(readCapMs);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            java.io.InputStream in = s.getInputStream();
            StringBuilder head = new StringBuilder();
            int c;
            while ((c = in.read()) != -1 && c != '\n') head.append((char) c);
            String hl = head.toString().trim();
            String[] h = hl.split(" ");
            if (h.length < 2 || !"OK".equals(h[0])) return new String[]{hl, null};
            int n;
            try { n = Integer.parseInt(h[1]); } catch (NumberFormatException nfe) { return new String[]{hl, null}; }
            if (n < 0 || n > (8 << 20)) return new String[]{hl, null}; // sanity cap, same as the instance twin
            byte[] buf = new byte[n];
            int off = 0, rd;
            while (off < n && (rd = in.read(buf, off, n - off)) >= 0) off += rd;
            if (off < n) return new String[]{hl, null};
            return new String[]{hl, new String(buf, 0, n, "UTF-8")};
        } catch (Throwable t) {
            return new String[]{"", null};
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** Bounded request -> first reply line ("" on any error or a wedged daemon). {@code readCapMs} is the read
     *  timeout for the reply (per caller: a local probe is quick; a store-touching command needs longer). */
    static String roundTrip(String msg, int readCapMs) {
        LocalSocket s = connect();
        if (s == null) return "";
        try {
            s.setSoTimeout(readCapMs);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            String line = br.readLine();
            if (moreBuffered(br)) // NWP-20261011-63: a multi-line reply read here is a bug -- say so (see moreBuffered)
                android.util.Log.e("NowhereChooser", "roundTrip(" + verbOf(msg) + "): the reply has more than one line "
                        + "and only the first was read -- use DaemonSocket.roundTripLines");
            return line == null ? "" : line.trim();
        } catch (Throwable t) {
            return "";
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** NWP-20261011-63: the request's VERB -- its first line, trimmed; "?" for null. The only part of a request that
     *  may be logged: later lines carry profile names and passphrases (TEL-OWNER, LOGIN, SET-PIN ...). */
    static String verbOf(String msg) {
        return msg == null ? "?" : msg.split("\n", 2)[0].trim();
    }

    /** NWP-20261011-63: after a caller read ONE reply line, is more of the reply already waiting? {@code ready()} never
     *  blocks and this reads nothing, so the caller's return value is unchanged. It exists because a one-line read of a
     *  multi-line reply drops the rest with no signal, which has shipped twice: every SIM showing "not bound", and the
     *  #176 outbound lock as a total no-op that logged success.
     *  ⚠ BEST-EFFORT, NOT A FIX: it sees only lines already buffered when the first line is read. The daemon writes a
     *  reply in one Fprint, so a multi-line reply is normally all there; a reply whose later lines arrive after that
     *  read is still silent. Making every multi-line reply return fully or raise needs a framed reply, or
     *  roundTripLines at every multi-line call site (docs/backlog.md). False on any error. */
    static boolean moreBuffered(BufferedReader br) {
        try {
            return br.ready();
        } catch (Throwable t) {
            return false;
        }
    }

    /** Bounded request -> ALL non-empty reply lines (the daemon writes the payload then closes). Empty on error. */
    static List<String> roundTripLines(String msg, int readCapMs) {
        ArrayList<String> lines = new ArrayList<>();
        LocalSocket s = connect();
        if (s == null) return lines;
        try {
            s.setSoTimeout(readCapMs);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            String line;
            while ((line = br.readLine()) != null) { line = line.trim(); if (!line.isEmpty()) lines.add(line); }
        } catch (Throwable t) {
            // return whatever lines arrived before the error
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
        return lines;
    }

    /** NWP-20261020-20: roundTripLines that keeps each non-blank line AS READ (the terminator is already gone). For a
     *  caller whose lines are tab-separated records: trim() removes a trailing TAB (an open network with no MAC
     *  field) and a passphrase's edge spaces. Empty on error. */
    static List<String> roundTripLinesRaw(String msg, int readCapMs) {
        ArrayList<String> lines = new ArrayList<>();
        LocalSocket s = connect();
        if (s == null) return lines;
        try {
            s.setSoTimeout(readCapMs);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            String line;
            while ((line = br.readLine()) != null) { if (!line.trim().isEmpty()) lines.add(line); }
        } catch (Throwable t) {
            // return whatever lines arrived before the error
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
        return lines;
    }

    /** NWP-20261002-03: roundTripLines that tells a FAILED read from an EMPTY reply -- null when the socket cannot be
     *  reached or any I/O error or read timeout happens; a (possibly empty) list only on a clean end of stream. For a
     *  caller whose next step would seal the answer: roundTripLines' "whatever arrived" reads a failure as "none". */
    static List<String> roundTripLinesOrNull(String msg, int readCapMs) {
        ArrayList<String> lines = new ArrayList<>();
        LocalSocket s = connect();
        if (s == null) return null;
        try {
            s.setSoTimeout(readCapMs);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            String line;
            while ((line = br.readLine()) != null) { line = line.trim(); if (!line.isEmpty()) lines.add(line); }
            return lines;
        } catch (Throwable t) {
            return null;
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
    }
}
