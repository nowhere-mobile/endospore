package android.net;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.SocketChannel;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/** Test stub of the part of LocalSocket DaemonSocket.connect touches. {@link #next} picks how the NEXT socket's
 *  connect() behaves; every socket records whether and when close() ran, and {@link #pending} is true while its
 *  connect() runs. close() throws IOException, as the real one does. */
public class LocalSocket {
    public enum Mode {
        BLOCK_UNTIL_CLOSE,  // blocks until close(), then throws IOException -- the #77 FP3 shape
        INSTANT,            // returns at once
        THROW,              // throws IOException at once
        LATE_IGNORE_CLOSE,  // returns normally after lateMs, whatever close() did meanwhile
        BLOCK_IGNORE_CLOSE, // blocks until release(), whatever close() did meanwhile -- what S8 measured on lynx
        REAL_UNIX           // a BLOCKING java.nio connect to unixAddr; close() leaves the channel alone while it is pending
    }

    public static volatile Mode next = Mode.INSTANT;
    public static volatile long lateMs;
    public static volatile UnixDomainSocketAddress unixAddr;
    public static volatile CountDownLatch gate = new CountDownLatch(1);
    public static final ConcurrentLinkedQueue<LocalSocket> created = new ConcurrentLinkedQueue<>();

    /** Unblocks every BLOCK_IGNORE_CLOSE connect made since the last {@link #rearm}. */
    public static void release() { gate.countDown(); }
    public static void rearm() { gate = new CountDownLatch(1); }

    private final Mode mode = next;
    private final CountDownLatch myGate = gate;
    private final CountDownLatch closedLatch = new CountDownLatch(1);
    private final Object chLock = new Object();
    private SocketChannel ch; // REAL_UNIX only; guarded by chLock
    public volatile boolean closed;
    public volatile boolean pending;
    public volatile long closedAtNanos;
    public final AtomicInteger closeCalls = new AtomicInteger();
    public volatile LocalSocketAddress addr;

    public LocalSocket() { created.add(this); }

    public void connect(LocalSocketAddress a) throws IOException {
        addr = a;
        pending = true;
        try {
            switch (mode) {
                case BLOCK_UNTIL_CLOSE:
                    for (;;) {
                        try { closedLatch.await(); break; } catch (InterruptedException ignore) {}
                    }
                    throw new IOException("socket closed");
                case THROW:
                    throw new IOException("connect refused");
                case LATE_IGNORE_CLOSE: {
                    long deadline = System.nanoTime() + lateMs * 1_000_000L;
                    for (long left; (left = deadline - System.nanoTime()) > 0; ) {
                        try { Thread.sleep(left / 1_000_000L, (int) (left % 1_000_000L)); } catch (InterruptedException ignore) {}
                    }
                    return;
                }
                case BLOCK_IGNORE_CLOSE:
                    for (;;) {
                        try { myGate.await(); break; } catch (InterruptedException ignore) {}
                    }
                    return;
                case REAL_UNIX: {
                    SocketChannel c = SocketChannel.open(StandardProtocolFamily.UNIX);
                    synchronized (chLock) { ch = c; }
                    try {
                        c.connect(unixAddr); // blocking
                    } finally {
                        synchronized (chLock) {
                            pending = false;
                            if (closed) { try { c.close(); } catch (IOException ignore) {} }
                        }
                    }
                    return;
                }
                default:
                    return;
            }
        } finally {
            pending = false;
        }
    }

    public void close() throws IOException {
        if (closeCalls.getAndIncrement() == 0) {
            closedAtNanos = System.nanoTime();
            closed = true;
        }
        closedLatch.countDown();
        // A NIO close from another thread WOULD release a pending NIO connect; a real LocalSocket's does not
        // (S8), so the channel is closed here only once no connect is pending, else by connect() when it returns.
        synchronized (chLock) {
            if (ch != null && !pending) { try { ch.close(); } catch (IOException ignore) {} }
        }
    }
}
