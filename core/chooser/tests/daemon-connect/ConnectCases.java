package com.nowhere.chooser;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.util.Log;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.BooleanSupplier;

/**
 * NWP-20261022-20, NWP-20261203-06: DaemonSocket.connect()'s bound, run against a stub LocalSocket and, in c7, a real
 * wedged AF_UNIX server. The harness class declares CONNECT_CAP_MS = 200 (the real 8000 is pinned by the suite);
 * MAX_STRANDED keeps its real value. Each case returns null for a pass or a message for a fail, and runs under a
 * timeout, so a hang is a FAIL. "Bounded" is shown by structure, never by a wall-time upper bound: the caller has
 * returned while the connect it started is still pending. Every case starts at STRANDED == 0 and leaves it at 0.
 *
 * These cases pin the NWP-20261203-06 design. On the old watchdog connect() (origin/main before it) case2, case3 and
 * case5 pass; case1 and case4 fail (the caller returned only once its connect had ended), and c6, c7, c8 and c9 hang
 * (a close that does not unblock the connect holds the caller), which the per-case timeout reports. c8 starts all of
 * its callers together: a limit checked only before the cap passes lets every one of them create a socket.
 */
public class ConnectCases {
    static final int CAP = DaemonSocket.CONNECT_CAP_MS;
    static final ExecutorService POOL = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r);
        t.setDaemon(true);
        return t;
    });
    static int fails;

    static void run(String name, long timeoutMs, LocalSocket.Mode mode, Callable<String> body) {
        LocalSocket.created.clear();
        LocalSocket.rearm();
        Log.lines.clear();
        LocalSocket.next = mode;
        String msg;
        int n0 = DaemonSocket.STRANDED.get();
        if (n0 != 0) {
            msg = "STRANDED is " + n0 + " at start";
        } else {
            Future<String> f = POOL.submit(body);
            try {
                msg = f.get(timeoutMs, TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                f.cancel(true);
                msg = "timed out after " + timeoutMs + " ms (a hang)";
            } catch (ExecutionException e) {
                msg = "threw " + e.getCause();
            } catch (InterruptedException e) {
                msg = "interrupted";
            }
        }
        LocalSocket.release(); // whatever the case blocked and did not release (a hang, a FAIL)
        if (msg == null) {
            System.out.println("PASS " + name);
        } else {
            System.out.println("FAIL " + name + ": " + msg);
            fails++;
        }
    }

    static long ms(long fromNanos) { return (System.nanoTime() - fromNanos) / 1_000_000L; }

    /** Polls every 10 ms until c holds; null when it does, else "<what> after <ms> ms". The case timeout bounds it. */
    static String await(BooleanSupplier c, long ms, String what) throws InterruptedException {
        long deadline = System.nanoTime() + ms * 1_000_000L;
        while (!c.getAsBoolean()) {
            if (System.nanoTime() > deadline) return what + " after " + ms + " ms";
            Thread.sleep(10);
        }
        return null;
    }

    static String stranded0() throws InterruptedException {
        return await(() -> DaemonSocket.STRANDED.get() == 0, 5000, "STRANDED is still " + DaemonSocket.STRANDED.get());
    }

    /** k parallel DaemonSocket.connect() calls; returns what each returned, once all have. */
    static LocalSocket[] wave(int k) throws InterruptedException {
        final LocalSocket[] got = new LocalSocket[k];
        final CountDownLatch go = new CountDownLatch(1);
        Thread[] ts = new Thread[k];
        for (int i = 0; i < k; i++) {
            final int j = i;
            ts[i] = new Thread(() -> {
                try { go.await(); } catch (InterruptedException ignore) {}
                got[j] = DaemonSocket.connect();
            });
            ts[i].setDaemon(true);
            ts[i].start();
        }
        go.countDown();
        for (Thread t : ts) t.join();
        return got;
    }

    static int failingFastLines() {
        int n = 0;
        for (String l : Log.lines) if (l.contains("failing fast")) n++;
        return n;
    }

    public static void main(String[] args) {
        if (CAP != 200) {
            System.out.println("FAIL harness: CONNECT_CAP_MS is " + CAP + ", the cases assume 200");
            System.exit(1);
        }
        final int MAX = DaemonSocket.MAX_STRANDED;

        run("case1 a connect that blocks: the caller returns null at the cap, never closing the pending socket", CAP + 10000,
                LocalSocket.Mode.BLOCK_UNTIL_CLOSE, () -> {
            long t0 = System.nanoTime();
            LocalSocket r = DaemonSocket.connect();
            long el = ms(t0);
            LocalSocket s = LocalSocket.created.peek();
            if (r != null) return "returned a socket";
            if (LocalSocket.created.size() != 1 || s == null) return "opened " + LocalSocket.created.size() + " sockets, want 1";
            if (el < CAP - 5) return "returned after " + el + " ms, before the cap";
            int calls = s.closeCalls.get();
            if (!s.pending) return "returned only after its connect ended (closeCalls " + calls + "): the caller waited on the connect";
            if (calls != 0) return "the caller closed the pending socket " + calls + " time(s)";
            s.close(); // the #77 FP3 shape: a close unblocks this stub's connect
            String e = await(() -> !s.pending, 5000, "the connect is still pending");
            if (e != null) return e;
            return stranded0();
        });

        run("case2 an instant connect is handed out open, and stays open", 3L * CAP + 5000,
                LocalSocket.Mode.INSTANT, () -> {
            LocalSocket r = DaemonSocket.connect();
            LocalSocket s = LocalSocket.created.peek();
            if (r == null) return "returned null";
            if (r != s) return "returned a socket other than the one it opened";
            if (r.closed) return "closed on return";
            LocalSocketAddress a = r.addr;
            if (a == null || !"nowhere_login".equals(a.getName()) || a.getNamespace() != LocalSocketAddress.Namespace.RESERVED)
                return "connected to the wrong address";
            Thread.sleep(3L * CAP);
            if (r.closed || r.closeCalls.get() != 0) return "the watchdog closed a healthy connection";
            return null;
        });

        run("case3 a connect that throws returns null and closes the socket", CAP + 5000,
                LocalSocket.Mode.THROW, () -> {
            long t0 = System.nanoTime();
            LocalSocket r = DaemonSocket.connect();
            long el = ms(t0);
            LocalSocket s = LocalSocket.created.peek();
            if (r != null) return "returned a socket";
            if (s == null || !s.closed) return "the socket was not closed";
            if (el >= CAP) return "took " + el + " ms, a refused connect must return at once";
            return null;
        });

        LocalSocket.lateMs = 2L * CAP;
        run("case4 a connect that returns after the cap: null at the cap, and the connector closes it once it returns",
                LocalSocket.lateMs + 10000, LocalSocket.Mode.LATE_IGNORE_CLOSE, () -> {
            long t0 = System.nanoTime();
            LocalSocket r = DaemonSocket.connect();
            long el = ms(t0);
            LocalSocket s = LocalSocket.created.peek();
            if (r != null) return "handed out a socket whose connect outlived the cap";
            if (LocalSocket.created.size() != 1 || s == null) return "opened " + LocalSocket.created.size() + " sockets, want 1";
            if (el < CAP - 5) return "returned after " + el + " ms, before the cap";
            if (!s.pending) return "returned only after its connect ended: the caller waited on the connect";
            String e = await(() -> !s.pending, LocalSocket.lateMs + 5000, "the connect is still pending");
            if (e != null) return e;
            e = await(() -> s.closed, 5000, "the connector did not close the abandoned socket");
            if (e != null) return e;
            return stranded0();
        });

        run("case5 50 parallel instant connects: none closed after 3x the cap", 3L * CAP + 10000,
                LocalSocket.Mode.INSTANT, () -> {
            final int n = 50;
            final LocalSocket[] got = new LocalSocket[n];
            final CountDownLatch go = new CountDownLatch(1);
            Thread[] ts = new Thread[n];
            for (int i = 0; i < n; i++) {
                final int k = i;
                ts[i] = new Thread(() -> {
                    try { go.await(); } catch (InterruptedException ignore) {}
                    got[k] = DaemonSocket.connect();
                });
                ts[i].setDaemon(true);
                ts[i].start();
            }
            go.countDown();
            for (Thread t : ts) t.join();
            if (LocalSocket.created.size() != n) return "opened " + LocalSocket.created.size() + " sockets, want " + n;
            for (int i = 0; i < n; i++) {
                if (got[i] == null) return "connect #" + i + " returned null";
                for (int j = 0; j < i; j++) if (got[i] == got[j]) return "two callers got the same socket";
            }
            Thread.sleep(3L * CAP);
            int closed = 0;
            for (LocalSocket s : got) if (s.closed) closed++;
            if (closed != 0) return closed + " of " + n + " healthy sockets were closed";
            return null;
        });

        run("c6 a connect that ignores close (lynx S8): null while it is pending, closed by the connector after it returns",
                CAP + 10000, LocalSocket.Mode.BLOCK_IGNORE_CLOSE, () -> {
            long t0 = System.nanoTime();
            LocalSocket r = DaemonSocket.connect();
            long el = ms(t0);
            LocalSocket s = LocalSocket.created.peek();
            if (r != null) return "returned a socket";
            if (LocalSocket.created.size() != 1 || s == null) return "opened " + LocalSocket.created.size() + " sockets, want 1";
            if (el < CAP - 5) return "returned after " + el + " ms, before the cap";
            if (!s.pending) return "returned only after its connect ended: the caller waited on the connect";
            if (s.closeCalls.get() != 0) return "the caller closed the pending socket";
            LocalSocket.release();
            String e = await(() -> !s.pending, 5000, "the connect is still pending after release()");
            if (e != null) return e;
            e = await(() -> s.closed, 5000, "the connector did not close the abandoned socket");
            if (e != null) return e;
            return stranded0();
        });

        run("c7 a REAL wedged AF_UNIX server (full backlog, never accepts): null while a bare connect is still blocked",
                10L * CAP + 20000, LocalSocket.Mode.REAL_UNIX, () -> {
            Path p = Paths.get(System.getProperty("java.io.tmpdir"), "w.sock");
            if (p.toString().getBytes(StandardCharsets.UTF_8).length > 100) {
                System.out.println("UNSUPPORTED: c7's socket path is longer than 100 bytes (AF_UNIX allows 108): " + p);
                System.exit(2);
            }
            Files.deleteIfExists(p);
            UnixDomainSocketAddress addr = UnixDomainSocketAddress.of(p);
            ServerSocketChannel srv = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            List<SocketChannel> fills = new ArrayList<>();
            try {
                srv.bind(addr, 1); // backlog 1, and nothing ever accepts
                CountDownLatch control = null;
                for (int i = 0; i < 32 && control == null; i++) {
                    SocketChannel c = SocketChannel.open(StandardProtocolFamily.UNIX);
                    fills.add(c);
                    CountDownLatch l = new CountDownLatch(1);
                    Thread t = new Thread(() -> {
                        try { c.connect(addr); } catch (IOException ignore) {} finally { l.countDown(); }
                    });
                    t.setDaemon(true);
                    t.start();
                    if (!l.await(500, TimeUnit.MILLISECONDS)) control = l;
                }
                if (control == null) return "server not wedged: 32 bare connects all returned";
                if (control.await(2L * CAP, TimeUnit.MILLISECONDS)) return "server not wedged: the control connect returned";
                LocalSocket.unixAddr = addr;
                LocalSocket r = DaemonSocket.connect();
                LocalSocket s = LocalSocket.created.peek();
                if (r != null) return "returned a socket from a server that never accepts";
                if (LocalSocket.created.size() != 1 || s == null) return "opened " + LocalSocket.created.size() + " sockets, want 1";
                if (control.getCount() == 0) return "the control connect returned before connect() did: the wedge ended first";
                if (!s.pending) return "returned only after its connect ended: the caller waited on the connect";
                srv.close(); // the daemon dies: the kernel refuses the queued connects
                String e = await(() -> !s.pending, 5000, "the stranded connect did not return when the server closed");
                if (e != null) return e;
                e = await(() -> s.closed, 5000, "the connector did not close the abandoned socket");
                if (e != null) return e;
                e = stranded0();
                if (e != null) return e;
                LocalSocket.next = LocalSocket.Mode.INSTANT;
                LocalSocket.created.clear();
                LocalSocket ok = DaemonSocket.connect();
                if (ok == null) return "an instant connect after the wedge returned null";
                if (ok.closed || ok != LocalSocket.created.peek()) return "an instant connect after the wedge was not handed out open";
                return null;
            } finally {
                try { srv.close(); } catch (IOException ignore) {}
                for (SocketChannel c : fills) { try { c.close(); } catch (IOException ignore) {} }
                Files.deleteIfExists(p);
            }
        });

        run("c8 a hard limit: MAX_STRANDED+3 callers TOGETHER on a wedged daemon create at most MAX_STRANDED sockets, log one line",
                CAP + 15000, LocalSocket.Mode.BLOCK_IGNORE_CLOSE, () -> {
            for (LocalSocket g : wave(MAX + 3)) if (g != null) return "a stuck connect returned a socket";
            if (LocalSocket.created.size() > MAX)
                return "created " + LocalSocket.created.size() + " sockets for " + (MAX + 3) + " calls, want at most " + MAX;
            for (LocalSocket s : LocalSocket.created) if (!s.pending) return "a stuck connect ended before the extra calls returned";
            if (DaemonSocket.STRANDED.get() > MAX) return "STRANDED is " + DaemonSocket.STRANDED.get() + ", past " + MAX;
            if (failingFastLines() != 1) return failingFastLines() + " fail-fast log line(s), want 1: " + Log.lines;
            for (String l : Log.lines) if (l.contains("nowhere_login") || l.contains("LOGIN") || l.contains("profile"))
                return "the fail-fast line names more than counts: " + l;
            LocalSocket.release();
            String e = stranded0();
            if (e != null) return e;
            for (LocalSocket s : LocalSocket.created) if (!s.closed) return "an abandoned socket was not closed";
            return null;
        });

        run("c9 recovery: once the stuck connects return, an instant connect is handed out open again",
                CAP + 15000, LocalSocket.Mode.BLOCK_IGNORE_CLOSE, () -> {
            for (LocalSocket g : wave(MAX)) if (g != null) return "a stuck connect returned a socket";
            if (DaemonSocket.STRANDED.get() != MAX)
                return "STRANDED is " + DaemonSocket.STRANDED.get() + " after " + MAX + " stuck connects, want " + MAX;
            final LocalSocket[] past = new LocalSocket[1];
            Thread pt = new Thread(() -> past[0] = DaemonSocket.connect());
            pt.setDaemon(true);
            pt.start();
            String w = await(() -> !pt.isAlive() || DaemonSocket.SLOTS.hasQueuedThreads(), 5000,
                    "the call past the limit neither returned nor waited");
            if (w != null) return w;
            if (DaemonSocket.SLOTS.hasQueuedThreads()) return "the call past the limit waited for a slot instead of failing fast";
            pt.join();
            if (past[0] != null) return "a call past the limit returned a socket";
            if (LocalSocket.created.size() != MAX) return "a call past the limit created a socket";
            if (failingFastLines() != 1) return failingFastLines() + " fail-fast log line(s) in a new episode, want 1 (re-armed)";
            LocalSocket.release();
            String e = stranded0();
            if (e != null) return e;
            LocalSocket.next = LocalSocket.Mode.INSTANT;
            LocalSocket.created.clear();
            LocalSocket r = DaemonSocket.connect();
            if (r == null) return "an instant connect after recovery returned null";
            if (r.closed || r != LocalSocket.created.peek()) return "an instant connect after recovery was not handed out open";
            return null;
        });

        System.exit(fails == 0 ? 0 : 1);
    }
}
