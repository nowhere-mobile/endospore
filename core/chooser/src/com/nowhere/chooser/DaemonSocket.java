package com.nowhere.chooser;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Bounded round-trips to the login daemon's LocalSocket (#77). {@link LocalSocket} has NO connect timeout
 * ({@code setSoTimeout} is the READ timeout only), so a wedged daemon -- its accept loop stuck in a store
 * retry -- blocks {@code connect()} FOREVER. On the idle/wipe alarm that reached the 60s background-broadcast
 * ANR and KILLED the persistent gate process (bounded separately in {@link IdleLogoffReceiver}); on every other
 * path it silently hung the caller's worker thread: a stalled reap poll (a queued logoff never reaps), a skipped
 * 12h hard-wipe (a security backstop that never fires), or a UI action that spins with no error.
 *
 * {@link #connect} bounds the connect with a watchdog that closes the socket at the cap -- closing an in-flight
 * LocalSocket unblocks a stuck {@code connect()} (proven on FP3, #77) -- so no daemon call can hang forever. A
 * wedged daemon yields a "" reply / empty list and the caller retries. All callers already run off the main
 * thread, so the bounded blocking here is safe.
 */
final class DaemonSocket {
    static final String SOCKET = "nowhere_login";
    static final int CONNECT_CAP_MS = 8000; // healthy connect is instant; this only bites a wedged daemon

    private DaemonSocket() {}

    /** Connect with a bounded connect. Returns a connected socket (the caller sets its own read timeout and does
     *  its own I/O), or null if the daemon did not accept within {@link #CONNECT_CAP_MS}. */
    static LocalSocket connect() {
        final LocalSocket s = new LocalSocket();
        final AtomicBoolean settled = new AtomicBoolean(false); // whoever CAS-wins decides the socket's fate
        Thread wd = new Thread(() -> {
            try { Thread.sleep(CONNECT_CAP_MS); } catch (InterruptedException ignore) {}
            if (settled.compareAndSet(false, true)) { // watchdog won -> connect still pending -> unblock it
                try { s.close(); } catch (Throwable ignore) {}
            }
        });
        wd.setDaemon(true);
        wd.start();
        try {
            s.connect(new LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.RESERVED));
            if (!settled.compareAndSet(false, true)) { // watchdog already fired + closed the socket -> treat as fail
                try { s.close(); } catch (Throwable ignore) {}
                return null;
            }
            wd.interrupt(); // connect returned in time -> stop the (sleeping) watchdog
            return s;
        } catch (Throwable t) {
            settled.set(true);
            try { s.close(); } catch (Throwable ignore) {}
            return null;
        }
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
