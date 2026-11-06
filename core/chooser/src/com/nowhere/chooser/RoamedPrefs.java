package com.nowhere.chooser;

/**
 * NWP-20261119-21: the parse of a profile's five lock prefs (idle=, wipe=, wipesaved=, holdlock=,
 * holdaudio=), one rule for both
 * readers. ChooserActivity.applyRoamedPrefs parses them at sign-in from GET-PREFS; PrefsLiveReceiver parses the values
 * a Security-screen Save sends to the gate during the session (docs/product-decisions.md, 2026-10-25, h45 #4: "a
 * Security-screen change takes effect in the running session"). One parse, so a live change and the next sign-in can
 * never read the same file differently.
 *
 * The rules are the ones applyRoamedPrefs always had: idle= is minutes and wipe= is hours; "0" is Never (0 ms), not the
 * default; null, empty or unparseable is the default the caller passes; there is no clamp. wipesaved= is
 * WipeOnSave.on's rule. Only holdlock=0 turns the install hold off. Only holdaudio=0 turns the audio hold off
 * (NWP-20261124-17).
 *
 * Pure java.lang so a javac suite can compile it off the build host (core/vendor-common/bin/test-roamed-prefs-live-java.sh).
 */
final class RoamedPrefs {
    private RoamedPrefs() {}

    /** The five values the gate's statics take. */
    static final class Values {
        final long idleMs;
        final long wipeMs;
        final boolean wipeOnSave;
        final boolean holdLock;
        final boolean holdAudio;

        Values(long idleMs, long wipeMs, boolean wipeOnSave, boolean holdLock, boolean holdAudio) {
            this.idleMs = idleMs;
            this.wipeMs = wipeMs;
            this.wipeOnSave = wipeOnSave;
            this.holdLock = holdLock;
            this.holdAudio = holdAudio;
        }
    }

    static Values parse(String idle, String wipe, String wipesaved, String holdlock, String holdaudio,
            long idleDefaultMs, long wipeDefaultMs) {
        long idleMs = idleDefaultMs;
        try { if (idle != null && !idle.isEmpty()) idleMs = Long.parseLong(idle) * 60L * 1000L; } catch (Throwable ignore) {}
        long wipeMs = wipeDefaultMs;
        try { if (wipe != null && !wipe.isEmpty()) wipeMs = Long.parseLong(wipe) * 60L * 60L * 1000L; } catch (Throwable ignore) {}
        return new Values(idleMs, wipeMs, WipeOnSave.on(wipesaved), !"0".equals(holdlock), !"0".equals(holdaudio));
    }
}
