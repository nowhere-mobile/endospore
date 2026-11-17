package com.nowhere.chooser;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * NWP-20261206-03 (Q047): the chooser client of the daemon's emergency-callback window. tell() records that an
 * emergency call went out (EMERGENCY-MARK); ask() asks on an inbound call whether one went out recently
 * (EMERGENCY-RECENT). One line each way; no number and no profile name go on the wire or into the log. The decision is
 * EmergencyWindowRule (pure, run under javac by test-emergency-window-java.sh).
 *
 * WIRED by NWP-20261115-18 into NowhereCallControlService: onCallAdded calls tell() where it sets
 * sLastEmergencyOutboundAt, and signal 4 of emergencyExemption is exemptReason(sLastEmergencyOutboundAt).
 * test-emergency-window-java.sh pins both call sites. ⚠ The wiring needs the daemon's EMERGENCY-MARK and
 * EMERGENCY-RECENT arms (NWP-20261206-02) in the same image: on an older daemon an unknown verb falls into the legacy
 * login, which wipes the session state dir.
 *
 * ask() never waits behind the daemon: the whole ask, connect included, is bounded by ASK_CAP_MS, and no answer in
 * time makes the rule fail open (the call rings).
 */
final class EmergencyWindow {
    private EmergencyWindow() {}

    /** The bound on the WHOLE ask, connect included. The round trip runs on its own thread; an abandoned thread ends
     *  by itself at the socket's connect and read caps. */
    static final int ASK_CAP_MS = 1500;

    /** The daemon's EMERGENCY-RECENT reply, or null when it did not answer within ASK_CAP_MS or answered nothing. */
    static String ask() {
        final AtomicReference<String> got = new AtomicReference<>();
        final CountDownLatch latch = new CountDownLatch(1);
        Thread t = new Thread(() -> {
            try { got.set(DaemonSocket.roundTrip("EMERGENCY-RECENT\n", ASK_CAP_MS)); }
            catch (Throwable ignore) {}
            finally { latch.countDown(); }
        }, "nowhere-emergency-ask");
        t.setDaemon(true);
        t.start();
        try {
            if (!latch.await(ASK_CAP_MS, TimeUnit.MILLISECONDS)) return null;
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            return null;
        }
        String r = got.get();
        return (r == null || r.isEmpty()) ? null : r;
    }

    /** Tell the daemon that an emergency call went out. Fire-and-forget on its own thread, never the caller's. */
    static void tell() {
        Thread t = new Thread(() -> {
            String r = "";
            try { r = DaemonSocket.roundTrip("EMERGENCY-MARK\n", 3000); } catch (Throwable ignore) {}
            String c = EmergencyWindowRule.markFailure(r);
            if (c != null) android.util.Log.w("NowhereChooser", "emergency window: mark not recorded (" + c + ")");
        }, "nowhere-emergency-tell");
        t.setDaemon(true);
        t.start();
    }

    /** The reason an inbound call must not be rejected for the emergency window, or null. A hit in the local static
     *  or in the daemon counts; no answer from the daemon in time fails open. */
    static String exemptReason(long markedAtMs) {
        return EmergencyWindowRule.exemptReason(markedAtMs, System.currentTimeMillis(), EmergencyWindow::ask);
    }
}
