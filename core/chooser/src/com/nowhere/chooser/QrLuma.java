package com.nowhere.chooser;

import java.nio.ByteBuffer;

/** QrScanActivity's Y-plane copy (NWP-20261113-29). A Y plane with row padding holds rowStride*(h-1)+w bytes, because
 *  the last row carries no padding, so the old copy's `remaining < rowStride` break skipped the last row and left it
 *  zero. Each row copies min(w, what is left) bytes from its own offset, a short final row included; rows past the end
 *  stay zero. Reads a duplicate, so the caller's buffer position does not move. */
final class QrLuma {
    private QrLuma() {}

    static byte[] luminance(ByteBuffer buf, int w, int h, int rowStride) {
        byte[] y = new byte[w * h];
        ByteBuffer b = buf.duplicate();
        if (rowStride == w) {
            b.get(y, 0, Math.min(b.remaining(), y.length));
            return y;
        }
        int base = b.position(), end = b.limit();
        for (int r = 0; r < h; r++) {
            long at = base + (long) r * rowStride;
            if (at >= end) break;
            int n = (int) Math.min(w, end - at);
            b.position((int) at);
            b.get(y, r * w, n);
        }
        return y;
    }
}
