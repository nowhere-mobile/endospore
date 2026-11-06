package com.nowhere.chooser;

import java.nio.ByteBuffer;
import java.util.Arrays;

/** NWP-20261113-29: QrOpenGate (one camera open at a time) and QrLuma (every Y row, the unpadded last one included),
 *  compiled unchanged with this file by tests/qrscan/run.sh. Exit 0 all pass, 1 a case failed. */
public final class QrScanCases {
    private static int fails = 0;

    private static void check(String name, boolean ok, String detail) {
        if (ok) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + " (" + detail + ")"); fails++; }
    }

    private static ByteBuffer seq(int n) {
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) b[i] = (byte) (i + 1);
        return ByteBuffer.wrap(b);
    }

    private static byte[] row(byte[] y, int w, int r) { return Arrays.copyOfRange(y, r * w, r * w + w); }

    public static void main(String[] a) {
        Object d0 = new Object(), d1 = new Object();

        // G1: the permission callback and onResume both call openCamera before the first open lands.
        QrOpenGate g = new QrOpenGate();
        check("G1 first begin() admits the open", g.begin(), "begin() on a fresh gate returned false");
        check("G1 second begin() refused while the first open is in flight", !g.begin(),
                "begin() returned true with an open in flight: the second openCamera evicts the first");
        check("G1 opened() records the in-flight attempt", g.opened(g.attempt(), d1), "opened() returned false");
        check("G1 begin() refused while a device is held", !g.begin(), "begin() returned true with a device held");
        g.reset();
        check("G1 begin() admits again after reset()", g.begin(), "begin() returned false after reset()");

        // G2: a refused or throwing open clears the in-flight mark.
        g = new QrOpenGate();
        g.begin();
        g.failed();
        check("G2 begin() admits after failed()", g.begin(),
                "begin() returned false after failed(): the gate is stuck");

        // G3: only the device the gate recorded is current.
        g = new QrOpenGate();
        g.begin();
        g.opened(g.attempt(), d1);
        check("G3 isCurrent(d1) after opened(d1)", g.isCurrent(d1), "isCurrent(d1) false");
        check("G3 isCurrent(d0) false for another device", !g.isCurrent(d0), "isCurrent(d0) true");
        check("G3 isCurrent(null) false", !g.isCurrent(null), "isCurrent(null) true");
        g.reset();
        check("G3 isCurrent(d1) false after reset()", !g.isCurrent(d1), "isCurrent(d1) still true after reset()");
        check("G3 isCurrent(d0) false after reset()", !g.isCurrent(d0), "isCurrent(d0) true after reset()");

        // G4: a callback of the in-flight attempt for a device never recorded clears that open, and only that.
        g = new QrOpenGate();
        g.begin();
        check("G4 openRefused() true for the attempt in flight", g.openRefused(g.attempt()),
                "openRefused() returned false");
        check("G4 begin() admits after openRefused()", g.begin(), "begin() returned false: the gate is stuck");
        int held = g.attempt();
        g.opened(held, d1);
        check("G4 openRefused() false while a device is held", !g.openRefused(held), "openRefused() returned true");
        check("G4 the held device stays current", g.isCurrent(d1), "isCurrent(d1) false after openRefused()");
        QrOpenGate fresh = new QrOpenGate();
        check("G4 openRefused() false on a fresh gate", !fresh.openRefused(fresh.attempt()),
                "openRefused() returned true");

        // G5: open A is pending, onPause resets the gate, onResume begins open B, then A's queued callback runs
        // (quitSafely still delivers it). A's onError must not cancel B, and must not clear B's in-flight mark.
        g = new QrOpenGate();
        g.begin();
        int a1 = g.attempt();
        g.reset();
        check("G5 begin() admits open B after reset()", g.begin(), "begin() returned false after reset()");
        int b1 = g.attempt();
        check("G5 open B is a new attempt", b1 != a1, "attempt() did not change: " + a1);
        boolean cancel = !g.isCurrent(d0) && g.openRefused(a1);
        check("G5 stale A's onError does not cancel B", !cancel, "openRefused(A) returned true with B in flight");
        check("G5 stale A's callback leaves B in flight", !g.begin(),
                "begin() returned true: a third open would evict B and replace the shared reader");
        check("G5 B's own refusal still clears B", g.openRefused(b1), "openRefused(B) returned false");

        // G6: a stale attempt's device landing (onOpened) after reset + a new begin is not recorded.
        g = new QrOpenGate();
        g.begin();
        int a2 = g.attempt();
        g.reset();
        check("G6 stale A's onOpened after reset() is not recorded", !g.opened(a2, d0),
                "opened(A) returned true with nothing in flight");
        g.begin();
        int b2 = g.attempt();
        check("G6 stale A's onOpened during B is not recorded", !g.opened(a2, d0),
                "opened(A) returned true with B in flight");
        check("G6 stale A's device is not current", !g.isCurrent(d0), "isCurrent(A's device) true");
        check("G6 B stays in flight", !g.begin(), "begin() returned true after A's stale onOpened");
        check("G6 B's own device lands", g.opened(b2, d1) && g.isCurrent(d1), "opened(B) did not record B's device");

        // L1: rowStride == w copies the bytes as given.
        try {
            byte[] y = QrLuma.luminance(seq(8), 4, 2, 4);
            check("L1 rowStride == w: bytes as given", Arrays.equals(y, new byte[]{1, 2, 3, 4, 5, 6, 7, 8}),
                    Arrays.toString(y));
        } catch (Throwable t) { check("L1 rowStride == w: bytes as given", false, t.toString()); }

        // L2: w=4 h=3 rowStride=6, 6*2+4 = 16 bytes (the last row carries no padding).
        try {
            ByteBuffer in = seq(16);
            byte[] y = QrLuma.luminance(in, 4, 3, 6);
            byte[] src = in.array();
            for (int r = 0; r < 3; r++) {
                byte[] want = Arrays.copyOfRange(src, r * 6, r * 6 + 4);
                check("L2 row " + r + " copied from offset " + (r * 6), Arrays.equals(row(y, 4, r), want),
                        "got " + Arrays.toString(row(y, 4, r)) + " want " + Arrays.toString(want));
            }
            check("L2 last row copied, not zero", !Arrays.equals(row(y, 4, 2), new byte[4]),
                    "the last row is all zero: the unpadded last row was skipped");
            check("L2 the caller's buffer position did not move", in.position() == 0, "position " + in.position());
        } catch (Throwable t) { check("L2 padded rows", false, t.toString()); }

        // L3: a buffer shorter than a full first row: no exception, missing bytes zero.
        try {
            byte[] y = QrLuma.luminance(seq(3), 4, 2, 6);
            check("L3 short buffer, padded rows", Arrays.equals(y, new byte[]{1, 2, 3, 0, 0, 0, 0, 0}),
                    Arrays.toString(y));
        } catch (Throwable t) { check("L3 short buffer, padded rows", false, t.toString()); }
        try {
            byte[] y = QrLuma.luminance(seq(3), 4, 2, 4);
            check("L3 short buffer, rowStride == w", Arrays.equals(y, new byte[]{1, 2, 3, 0, 0, 0, 0, 0}),
                    Arrays.toString(y));
        } catch (Throwable t) { check("L3 short buffer, rowStride == w", false, t.toString()); }

        System.out.println(fails == 0 ? "PASS" : "FAIL: " + fails + " case(s)");
        System.exit(fails == 0 ? 0 : 1);
    }
}
