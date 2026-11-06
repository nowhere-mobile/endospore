package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.OutputStream;

/**
 * NWP-20261020-22: the loop of {@link NfcFido2}'s APDU shuttle, lifted out with java.* imports only so a
 * javac suite can execute it (core/chooser/tests/nfc-shuttle). The daemon writes "APDU &lt;hex&gt;"; we
 * transceive over the tap and write back "RESP &lt;hex&gt;" or "NFCERR ...", until it replies OK/ERR.
 */
final class NfcShuttle {
    private NfcShuttle() {}

    /** The tag, as the shuttle needs it (NfcFido2 wraps IsoDep). */
    interface Tap {
        boolean isConnected();
        void connect() throws IOException;
        void setTimeout(int ms);
        byte[] transceive(byte[] apdu) throws IOException;
    }

    interface Clock { long ms(); }

    interface Log {
        void info(String m);
        void warn(String m, Throwable t);
    }

    /**
     * NWP-20261109-05: the detail {@link #run} returns when the tag dropped inside the exchange and the daemon then
     * gave up. The daemon answers a bare "ERR" whatever went wrong (a dead link, a CTAP rejection, a wrong secret),
     * so only this side, which saw its own transceive throw, can tell the gate that the key was lost.
     */
    static final String LINK_LOST = "nfc-link-lost";

    /**
     * Returns {"OK"|"ERR", detail-line}. When the daemon's final line is not OK (an ERR line or EOF) and a
     * connect/transceive threw on the way, the detail is {@link #LINK_LOST}; an OK after a failed exchange stays
     * OK, because the daemon's verdict wins.
     */
    static String[] run(BufferedReader in, OutputStream out, Tap tap, int apduTimeoutMs, Clock clock, Log log)
            throws IOException {
        final long t0 = clock.ms();
        boolean connected = false;
        boolean linkDead = false;
        boolean tagFailed = false;
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.startsWith("APDU ")) {
                byte[] resp;
                if (linkDead) {
                    // ⚠ NWP-20260825-01: FAIL FAST. Once one exchange has failed, the tag has stopped
                    // answering and every further APDU just buys another full timeout against a dead
                    // link -- device-measured as the 30s that the user experiences as "hold still ...
                    // couldn't sign in". Answer without touching the tag. The daemon aborts on the
                    // first NFCERR now, so this is belt-and-braces -- but it is what makes the cost
                    // bounded no matter what the other side decides to ask for next.
                    out.write(("NFCERR link lost\n").getBytes("UTF-8"));
                    out.flush();
                    continue;
                }
                try {
                    String hex = line.substring(5).trim();
                    if (!isHexApdu(hex)) {
                        // NWP-20261127-18: the daemon frames every APDU as even-length hex, so anything else -- an
                        // odd length, a char that is not hex, a signed pair ("+1", "-f") -- is a daemon bug: surface
                        // it, and send nothing to the key. It is refused BEFORE the lazy connect, so the tag is never
                        // touched. Like any failed exchange it ends the link, but it does NOT set tagFailed: a daemon
                        // bug is not a dropped key, and the gate must not tell the user to hold the key still for it
                        // (LINK_LOST, NfcTapVerdict.failText). An empty payload never gets here: the line is trimmed,
                        // so "APDU " is "APDU", and it returns below as the daemon's own ERR line.
                        linkDead = true;
                        log.warn("nfc: malformed APDU refused", null);
                        out.write(("NFCERR bad apdu\n").getBytes("UTF-8"));
                        out.flush();
                        continue;
                    }
                    if (!connected) {
                        // NWP-20260824-15: the daemon has spoken, so the tag is needed NOW and not before.
                        // The elapsed figure is the tag-idle window that used to be spent connected.
                        log.info("nfc: daemon resolved in " + (clock.ms() - t0) + "ms; connecting tag now");
                        if (!tap.isConnected()) tap.connect(); // isConnected: belt and braces, nothing else connects
                        tap.setTimeout(apduTimeoutMs); // ALWAYS, not just on the connect branch -- a 0 timeout here
                                                       // would undo the whole point of holding the tap open
                        connected = true;              // latches only AFTER a clean connect, so the failure log below
                                                       // reports connected=false when it was the CONNECT that failed
                    }
                    long ta = clock.ms();
                    resp = tap.transceive(hexToBytes(hex));
                    long td = clock.ms() - ta;
                    if (td > 2000) {
                        log.warn("nfc: slow transceive " + td + "ms", null);
                    }
                } catch (Throwable t) {
                    // Name WHICH hop failed and how long the tag had been in play -- "Tag was lost" alone
                    // cannot distinguish a stale idle tag from marginal coupling.
                    linkDead = true; // NWP-20260825-01: no further exchanges on a link that just failed
                    tagFailed = true; // NWP-20261109-05: the TAG failed (not the malformed-APDU guard): LINK_LOST if the daemon gives up
                    log.warn("nfc: transceive failed at t+" + (clock.ms() - t0) + "ms (connected=" + connected + ")", t);
                    out.write(("NFCERR " + t.getMessage() + "\n").getBytes("UTF-8"));
                    out.flush();
                    continue;
                }
                out.write(("RESP " + bytesToHex(resp) + "\n").getBytes("UTF-8"));
                out.flush();
            } else if (line.startsWith("OK")) {
                return new String[]{"OK", line};
            } else if (!line.isEmpty()) {
                return new String[]{"ERR", tagFailed ? LINK_LOST : line};
            }
        }
        return new String[]{"ERR", tagFailed ? LINK_LOST : "closed"};
    }

    /**
     * NWP-20261127-18: true only for a non-empty, even-length run of ASCII hex digits (0-9, a-f, A-F). It does
     * not trim: run() trims the line, and a caller that did not must not have its spaces hidden.
     */
    static boolean isHexApdu(String hex) {
        if (hex.isEmpty() || hex.length() % 2 != 0) return false;
        for (int i = 0; i < hex.length(); i++) {
            if (nibble(hex.charAt(i)) < 0) return false;
        }
        return true;
    }

    /** Throws IllegalArgumentException on a char that is not an ASCII hex digit: a sign never becomes a byte. */
    static byte[] hexToBytes(String h) {
        int n = h.length() / 2;
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) {
            int hi = nibble(h.charAt(2 * i)), lo = nibble(h.charAt(2 * i + 1));
            if (hi < 0 || lo < 0) throw new IllegalArgumentException("not a hex pair at byte " + i);
            b[i] = (byte) ((hi << 4) | lo);
        }
        return b;
    }

    /**
     * The value of one ASCII hex digit, or -1. Not Character.digit(c, 16): that also decodes non-ASCII digits
     * and letters (U+0663 is 3, U+FF21 is 10), and Integer.parseInt also takes a sign.
     */
    private static int nibble(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    private static final char[] HEX = "0123456789abcdef".toCharArray();

    static String bytesToHex(byte[] b) {
        char[] c = new char[b.length * 2];
        for (int i = 0; i < b.length; i++) {
            c[2 * i] = HEX[(b[i] >> 4) & 0xf];
            c[2 * i + 1] = HEX[b[i] & 0xf];
        }
        return new String(c);
    }
}
