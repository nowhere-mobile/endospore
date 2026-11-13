package android.util;

/** Test stub: records each info line as "tag: message" in INFO, so a case can assert what the clear wrote. */
public final class Log {
    public static final java.util.List<String> INFO = new java.util.ArrayList<>();
    private Log() {}
    public static int i(String tag, String msg) { INFO.add(tag + ": " + msg); return 0; }
}
