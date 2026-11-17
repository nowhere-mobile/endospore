package android.os;

/** NWP-20261203-07: a stand-in for the one platform call the lifted sweep-thread publication makes, so
 *  test-sweep-snapshot-java.sh compiles SweepSlotHarness without an Android tree. */
public final class SystemClock {
    private SystemClock() {}
    public static long elapsedRealtime() { return System.nanoTime() / 1_000_000L; }
}
