package android.net;

import java.io.IOException;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/** Test stub of the part of LocalSocket DaemonSocket.connect touches. {@link #next} picks how the NEXT socket's
 *  connect() behaves; every socket records whether and when close() ran. close() throws IOException, as the real
 *  one does. */
public class LocalSocket {
    public enum Mode {
        BLOCK_UNTIL_CLOSE, // blocks until close(), then throws IOException -- what a real LocalSocket does
        INSTANT,           // returns at once
        THROW,             // throws IOException at once
        LATE_IGNORE_CLOSE  // returns normally after lateMs, whatever close() did meanwhile
    }

    public static volatile Mode next = Mode.INSTANT;
    public static volatile long lateMs;
    public static final ConcurrentLinkedQueue<LocalSocket> created = new ConcurrentLinkedQueue<>();

    private final Mode mode = next;
    private final CountDownLatch closedLatch = new CountDownLatch(1);
    public volatile boolean closed;
    public volatile long closedAtNanos;
    public final AtomicInteger closeCalls = new AtomicInteger();
    public volatile LocalSocketAddress addr;

    public LocalSocket() { created.add(this); }

    public void connect(LocalSocketAddress a) throws IOException {
        addr = a;
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
            default:
                return;
        }
    }

    public void close() throws IOException {
        if (closeCalls.getAndIncrement() == 0) {
            closedAtNanos = System.nanoTime();
            closed = true;
        }
        closedLatch.countDown();
    }
}
