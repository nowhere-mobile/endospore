package android.util;

import java.util.concurrent.ConcurrentLinkedQueue;

/** Test stub of android.util.Log: DaemonSocket.connect's fail-fast line. Each line is kept in {@link #lines} as
 *  "tag: msg", so a case can read what was logged. */
public final class Log {
    public static final ConcurrentLinkedQueue<String> lines = new ConcurrentLinkedQueue<>();

    private Log() {}

    public static int w(String tag, String msg) {
        lines.add(tag + ": " + msg);
        return 0;
    }
}
