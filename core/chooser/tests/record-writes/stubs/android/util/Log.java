package android.util;

/** Test stub: records each warning as "tag: message" so a case can assert a failed write was logged. */
public final class Log {
    public static final java.util.List<String> LINES = new java.util.ArrayList<>();
    private Log() {}
    public static int w(String tag, String msg, Throwable t) { LINES.add(tag + ": " + msg); return 0; }
    public static int w(String tag, String msg) { LINES.add(tag + ": " + msg); return 0; }
}
