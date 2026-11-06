package android.os;

/** Test stand-in for android.os.SystemClock: a clock the cases set and advance. */
public final class SystemClock {
    private static long now = 1_000_000L;

    private SystemClock() {}

    public static long elapsedRealtime() { return now; }

    public static void set(long ms) { now = ms; }

    public static void advance(long ms) { now += ms; }
}
