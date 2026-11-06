package com.nowhere.chooser;

/** One camera open at a time for QrScanActivity (NWP-20261113-29). On a first run the permission grant drove openCamera
 *  before onResume did, and `camera` was only set once the open landed on the bg thread, so the second call opened the
 *  same id again; that evicted the first device, whose onDisconnected then closed the shared session, camera and
 *  reader under the second open, and the scanner closed at once. Each admitted open is numbered, and a device callback
 *  acts only for the attempt that is still in flight: a callback queued by an attempt that closeCamera reset (onPause;
 *  HandlerThread.quitSafely still delivers what is already queued) never takes over, clears or cancels a newer open. */
final class QrOpenGate {
    private int attempt;
    private boolean inFlight;
    private Object held;

    /** True only when no open is in flight and no device is held; marks one in flight as a new attempt(). */
    synchronized boolean begin() {
        if (inFlight || held != null) return false;
        inFlight = true;
        attempt++;
        return true;
    }

    /** The number of the latest attempt begin() admitted; openCamera binds its device callback to it. */
    synchronized int attempt() { return attempt; }

    /** Attempt `at` landed with dev. True when `at` is the open in flight: dev is now current. False for a stale
     *  attempt (reset since, or a newer one began): the caller closes dev and touches nothing shared. */
    synchronized boolean opened(int at, Object dev) {
        if (!inFlight || at != attempt) return false;
        held = dev;
        inFlight = false;
        return true;
    }

    synchronized boolean isCurrent(Object dev) { return dev != null && dev == held; }

    /** openCamera refused or threw before the open was handed to the camera service. */
    synchronized void failed() { inFlight = false; }

    /** A device callback (onError / onDisconnected) of attempt `at` arrived before its device was recorded: the camera
     *  service refused that open. Clears it and returns true only when `at` is the open still in flight; false for a
     *  stale attempt, when a device is held, or when nothing is in flight. */
    synchronized boolean openRefused(int at) {
        if (!inFlight || held != null || at != attempt) return false;
        inFlight = false;
        return true;
    }

    /** closeCamera: nothing in flight, nothing held. */
    synchronized void reset() { inFlight = false; held = null; }
}
