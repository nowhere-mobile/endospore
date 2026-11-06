package com.nowhere.chooser;

/**
 * NWP-20261114-30: which stream the gate's call screen ({@link IncomingCallActivity}) adjusts on a volume key.
 * While the screen shows the call controls (a connected call, or the owner's own outgoing call) the keys adjust the
 * call. While a call rings, or with no call, they adjust the ringer, as before this slice.
 *
 * Only the stream is decided here. The swallow (#99: the keys never reach PhoneWindow, whose volume path NPEs in the
 * nowhere_chooser domain) belongs to the caller and never moves. java.* only, so a javac suite runs it unchanged
 * (core/chooser/test-call-volume-java.sh).
 */
final class CallVolume {
    private CallVolume() {}

    /** True: adjust STREAM_VOICE_CALL. False: adjust STREAM_RING. The owner's own call never adjusts the ringer. */
    static boolean callStream(boolean haveCall, boolean ringing, boolean outgoing) {
        return haveCall && (outgoing || !ringing);
    }
}
