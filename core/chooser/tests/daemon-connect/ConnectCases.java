package com.nowhere.chooser;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * NWP-20261022-20: DaemonSocket.connect()'s bound, run against a stub LocalSocket. The harness class declares
 * CONNECT_CAP_MS = 200 (the real 8000 is pinned by the suite). Each case returns null for a pass or a message for a
 * fail, and runs under a timeout, so a hang is a FAIL. This pins SHIPPED behaviour: every case passes on main.
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
        LocalSocket.next = mode;
        String msg;
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
        if (msg == null) {
            System.out.println("PASS " + name);
        } else {
            System.out.println("FAIL " + name + ": " + msg);
            fails++;
        }
    }

    static long ms(long fromNanos) { return (System.nanoTime() - fromNanos) / 1_000_000L; }

    public static void main(String[] args) {
        if (CAP != 200) {
            System.out.println("FAIL harness: CONNECT_CAP_MS is " + CAP + ", the cases assume 200");
            System.exit(1);
        }

        run("case1 a connect that blocks returns null at the cap and closes the socket", CAP + 5000,
                LocalSocket.Mode.BLOCK_UNTIL_CLOSE, () -> {
            long t0 = System.nanoTime();
            LocalSocket r = DaemonSocket.connect();
            long el = ms(t0);
            LocalSocket s = LocalSocket.created.peek();
            if (r != null) return "returned a socket";
            if (LocalSocket.created.size() != 1 || s == null || !s.closed) return "the socket was not closed";
            if (el < CAP - 5 || el > CAP + 2000) return "returned after " + el + " ms, want [" + CAP + ", " + (CAP + 2000) + "]";
            return null;
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
        run("case4 a connect that returns after the cap is never handed out closed", LocalSocket.lateMs + 5000,
                LocalSocket.Mode.LATE_IGNORE_CLOSE, () -> {
            long t0 = System.nanoTime();
            LocalSocket r = DaemonSocket.connect();
            long el = ms(t0);
            LocalSocket s = LocalSocket.created.peek();
            if (r != null) return "handed out a socket the watchdog closed";
            if (s == null || !s.closed) return "the socket was not closed";
            if (el < LocalSocket.lateMs - 5) return "returned after " + el + " ms, before the connect did";
            return null;
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

        System.exit(fails == 0 ? 0 : 1);
    }
}
