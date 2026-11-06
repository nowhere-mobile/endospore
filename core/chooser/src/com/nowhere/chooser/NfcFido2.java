package com.nowhere.chooser;

import android.app.Activity;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.tech.IsoDep;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;

/**
 * #81 item 5: run a FIDO2 CTAP2 flow over an NFC security key. The FP3's NFC controller is owned by
 * NfcService, so -- unlike the USB-HID path (the root worker opens /dev/hidraw) -- the raw ISO-DEP transceive
 * happens HERE, via {@link NfcAdapter} reader mode + {@link IsoDep}. The daemon frames CTAP2 and shuttles
 * ISO-DEP APDUs to us over the login socket: it writes "APDU &lt;hex&gt;", we {@code transceive()} the tap and
 * write back "RESP &lt;hex&gt;" (or "NFCERR &lt;msg&gt;"), until it replies OK/ERR. We just carry bytes -- all
 * the CTAP2/APDU logic lives in the agent (unit-tested), so this class holds no protocol knowledge.
 */
final class NfcFido2 {

    /** NWP-20260825-01: the per-APDU ceiling, and it is the difference between a flaky tap costing one
     *  second or thirty.
     *
     *  It was 30000 with the comment "a held tap through the CTAP flow can take a moment", which confused
     *  the duration of the WHOLE ceremony with the duration of ONE exchange. Device-measured on lynx
     *  2026-08-25, a healthy assert is three exchanges: SELECT (43ms), then 514ms, then 787ms. So 811ms
     *  is the worst healthy single exchange ever observed and 30s was ~37x that -- pure dead air whenever
     *  the link dropped, which on a field-powered tag it does: the key browns out mid-computation, stops
     *  answering, and IsoDep cannot tell that from a key thinking hard until the timer expires.
     *
     *  5s leaves >6x headroom over the measured worst case. ENROLL gets 10s because makeCredential
     *  generates a keypair and is materially slower than an assertion, and a spurious cut mid-ceremony is
     *  worse there: it is a TWO-TAP flow with state parked in the daemon between taps. */
    private static final int APDU_TIMEOUT_MS = 5000;
    private static final int APDU_TIMEOUT_ENROLL_MS = 10000;

    /** Delivered on the NFC reader-callback thread (off-main); callers marshal to the UI themselves. */
    interface Result {
        void done(boolean ok, String detail);
    }

    /** Builds the daemon verb header at TAP time from live UI (e.g. the gate's typed name + passphrase), or
     *  returns null to ignore this tap. Called on the reader thread; the impl handles its own UI marshalling. */
    interface VerbSupplier {
        String get();
    }

    private NfcFido2() {}

    /**
     * #81 item 5: keep reader mode armed CONTINUOUSLY at the gate so a security-key tap starts an NFC login with
     * no separate button and no per-login delay. On each tag, verbSupplier builds the request from the live
     * fields (FIDO2-NFC-ASSERT with the typed name+pass), or returns null when nothing's entered yet (a tap
     * then does nothing but the reader stays armed). Blind-safe: the reader is armed unconditionally, regardless
     * of whether any profile is key-enrolled, so it leaks nothing (a conditional prompt would). Reader mode
     * persists across taps until {@link #stop}; the caller stops it when a login actually begins, and re-arms on
     * return to the gate. Result is on the reader thread.
     */
    static boolean armGate(final Activity act, final VerbSupplier verbSupplier, final Result cb) {
        final NfcAdapter na = NfcAdapter.getDefaultAdapter(act);
        if (na == null) {
            android.util.Log.w("NowhereChooser", "armGate: no NFC adapter yet");
            return false;
        }
        if (!na.isEnabled()) {
            android.util.Log.w("NowhereChooser", "armGate: NFC not enabled yet");
            return false;
        }
        final NfcAdapter.ReaderCallback rc = new NfcAdapter.ReaderCallback() {
            @Override public void onTagDiscovered(Tag tag) {
                String verb;
                try {
                    verb = verbSupplier.get();
                } catch (Throwable t) {
                    return;
                }
                if (verb == null) { // no creds entered -> ignore, stay armed for the next tap
                    cb.done(false, "no-creds");
                    return;
                }
                boolean ok = false;
                String detail = "assert-failed";
                IsoDep iso = IsoDep.get(tag);
                if (iso == null) {
                    detail = "not-fido";
                } else {
                    try {
                        // NWP-20260824-15: do NOT connect here. shuttle() connects LAZILY, on the first APDU,
                        // so the tag is not held selected while the daemon works out what to send.
                        //
                        // ⚠ CORRECTED BY NWP-20260825-01 -- the ORIGINAL rationale here was WRONG and is worth
                        // keeping wrong-side-up so it is not re-derived. It claimed the resolve was a 2.7-3.4s
                        // store round trip and that the resulting idle window was why Chester's taps failed.
                        // That number came from testing with DUMMY CREDENTIALS, which forces the keyless
                        // non-PIN store-probe branch. MEASURED ON DEVICE: a login resolves in 655ms and a PIN
                        // resume -- the path that was actually failing -- reads the cold-lock marker LOCALLY
                        // and resolves in 2-4ms. So this change removes ~3ms of exposure there, not seconds.
                        //
                        // It is still right (a login genuinely held the tag ~655ms for nothing, and on a slow
                        // resolve it is what keeps the tag out of it), but the failures had a different cause
                        // entirely: the key browns out mid-computation and we then spent 30s finding out. See
                        // NWP-20260825-01 -- APDU_TIMEOUT_MS and the linkDead guard below.
                        // NWP-20261119-11: the sign-in assert's arm is 90 s with no vault write, so 40 s a line stays.
                        String[] res = shuttle(iso, verb, APDU_TIMEOUT_MS, 40000);
                        ok = "OK".equals(res[0]);
                        detail = res[1];
                    } catch (Throwable t) {
                        detail = "nfc-io";
                        android.util.Log.w("NowhereChooser", "nfc gate shuttle", t);
                    } finally {
                        try { iso.close(); } catch (Throwable ignore) {}
                    }
                }
                cb.done(ok, detail); // reader mode stays armed; the caller stops it once a login starts
            }
        };
        int flags = NfcAdapter.FLAG_READER_NFC_A | NfcAdapter.FLAG_READER_NFC_B
                | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK | NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS;
        try {
            na.enableReaderMode(act, rc, flags, null);
            android.util.Log.i("NowhereChooser", "armGate: NFC reader mode enabled");
            return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "armGate enableReaderMode", t);
            return false;
        }
    }

    /** NFC usable right now: hardware present AND the adapter enabled (Settings → NFC on). */
    static boolean available(Activity a) {
        NfcAdapter na = NfcAdapter.getDefaultAdapter(a);
        return na != null && na.isEnabled();
    }

    /** #143: NFC hardware present on the device (adapter exists), regardless of whether it's currently ON.
     *  We gate OFFERING the NFC enroll path on this, not on {@link #available}, so a device with NFC turned
     *  OFF still shows the option (then guides the user to enable it) instead of silently hiding it -- the
     *  bug where "NFC enrollment isn't offered" was just NFC being off in a roamed session. Reader mode itself
     *  works fine for a foreground secondary user once NFC is on (device-proven), so hardware-present is the
     *  right gate for visibility. */
    static boolean hasHardware(Activity a) {
        return NfcAdapter.getDefaultAdapter(a) != null;
    }

    /**
     * Enter reader mode; on the first tag, drive {@code verbLines} (the daemon request header, e.g.
     * "FIDO2-NFC-ASSERT\n&lt;name&gt;\n&lt;pass&gt;\n") to completion over the APDU shuttle, then report and
     * leave reader mode. One-shot: reader mode is disabled as soon as a tag is handled (or call {@link #stop}
     * to cancel before a tap). The socket loop runs on the reader-callback thread, which is already off-main.
     */
    static void run(final Activity act, final String verbLines, final Result cb) {
        final NfcAdapter na = NfcAdapter.getDefaultAdapter(act);
        if (na == null || !na.isEnabled()) {
            cb.done(false, "no-nfc");
            return;
        }
        final boolean[] handled = {false};
        final NfcAdapter.ReaderCallback rc = new NfcAdapter.ReaderCallback() {
            @Override public void onTagDiscovered(Tag tag) {
                synchronized (handled) {
                    if (handled[0]) return; // ignore a second tag while the first is in flight
                    handled[0] = true;
                }
                boolean ok = false;
                String detail = "assert-failed";
                IsoDep iso = IsoDep.get(tag);
                if (iso == null) {
                    detail = "not-fido"; // not an ISO-DEP tag -> not a FIDO2 security key
                } else {
                    try {
                        // NWP-20260824-15: lazy connect here too -- shuttle() connects on the first APDU. The
                        // enroll path waits on the SAME store round trip before the daemon can speak, so it
                        // held the tag selected and idle for exactly as long. Left eager, it would also have
                        // double-connected against shuttle's new lazy connect.
                        // NWP-20261119-11: the FINISH arm's 120 s deadline covers the paid vault write. Read past it,
                        // or an enrolment that committed reads as a failed one.
                        String[] res = shuttle(iso, verbLines, APDU_TIMEOUT_ENROLL_MS, 130000);
                        ok = "OK".equals(res[0]);
                        detail = res[1];
                    } catch (Throwable t) {
                        detail = "nfc-io";
                        android.util.Log.w("NowhereChooser", "nfc fido2 shuttle", t);
                    } finally {
                        try { iso.close(); } catch (Throwable ignore) {}
                    }
                }
                try { na.disableReaderMode(act); } catch (Throwable ignore) {}
                cb.done(ok, detail);
            }
        };
        int flags = NfcAdapter.FLAG_READER_NFC_A | NfcAdapter.FLAG_READER_NFC_B
                | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK | NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS;
        try {
            na.enableReaderMode(act, rc, flags, null);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "enableReaderMode", t);
            cb.done(false, "no-nfc");
        }
    }

    /** Cancel a pending reader-mode session (the user backed out before tapping). Safe to call unconditionally. */
    static void stop(Activity act) {
        try {
            NfcAdapter na = NfcAdapter.getDefaultAdapter(act);
            if (na != null) na.disableReaderMode(act);
        } catch (Throwable ignore) {}
    }

    /**
     * The APDU shuttle: send the verb header to the daemon, then answer each "APDU &lt;hex&gt;" by transceiving
     * over IsoDep and writing back "RESP &lt;hex&gt;" (or "NFCERR ..." on a transceive failure -- the tag left
     * the field), until the daemon replies OK/ERR. Returns {"OK"|"ERR", detail-line}. {@code socketTimeoutMs} bounds
     * each daemon line read (NWP-20261119-11).
     */
    private static String[] shuttle(final IsoDep iso, String verbLines, int apduTimeoutMs, int socketTimeoutMs)
            throws Exception {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            s.setSoTimeout(socketTimeoutMs);
            OutputStream os = s.getOutputStream();
            os.write(verbLines.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            return NfcShuttle.run(br, os, new NfcShuttle.Tap() {
                @Override public boolean isConnected() { return iso.isConnected(); }
                @Override public void connect() throws java.io.IOException { iso.connect(); }
                @Override public void setTimeout(int ms) { iso.setTimeout(ms); }
                @Override public byte[] transceive(byte[] apdu) throws java.io.IOException { return iso.transceive(apdu); }
            }, apduTimeoutMs, android.os.SystemClock::elapsedRealtime, new NfcShuttle.Log() {
                @Override public void info(String m) { android.util.Log.i("NowhereChooser", m); }
                @Override public void warn(String m, Throwable t) {
                    if (t == null) android.util.Log.w("NowhereChooser", m);
                    else android.util.Log.w("NowhereChooser", m, t);
                }
            });
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
    }
}
