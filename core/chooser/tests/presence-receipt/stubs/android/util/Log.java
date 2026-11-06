package android.util;

/** Test stub: records each warning as "tag: message" in LINES and each info line in INFO, so a case can assert what
 *  was logged and that no line names a package. */
public final class Log {
    public static final java.util.List<String> LINES = new java.util.ArrayList<>();
    public static final java.util.List<String> INFO = new java.util.ArrayList<>();
    private Log() {}
    public static int w(String tag, String msg, Throwable t) { LINES.add(tag + ": " + msg); return 0; }
    public static int w(String tag, String msg) { LINES.add(tag + ": " + msg); return 0; }
    public static int i(String tag, String msg) { INFO.add(tag + ": " + msg); return 0; }
}
