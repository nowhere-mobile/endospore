package com.nowhere.chooser;

/**
 * NWP-20261208-20 (h45 #1, docs/product-decisions.md 2026-10-25): the gate removes a fingerprint or face enrolled in
 * user 0.
 *
 * User 0 is the gate and is never wiped. A fingerprint or face enrolled there through Owner settings > System settings
 * persists across every sign-out and power-off, reaches the next renter on a rental phone, and never helps a session's
 * apps (biometrics are per Android user). NWP-20261114-12 turned biometrics off at user 0's keyguard, so Settings'
 * entry is disabled while nothing is enrolled; an enrolment made before that stays. The decision: the gate removes it
 * at each gate start and Owner settings says so once; a template the gate cannot remove is reported in Owner settings.
 * The 2026-10-24 entry (biometrics cannot be enrolled under the device owner) stands.
 *
 * This class holds the run order, the verdict and the two texts. GateBiometricRemove holds the FingerprintManager /
 * FaceManager calls and the marker, behind Port. The verdict is always a recount, never a removal callback. Pure
 * java.*: test-gate-biometric-clear-java.sh compiles this file alone under javac.
 */
final class GateBiometricClear {
    private GateBiometricClear() {}

    enum Action { NONE, REMOVED, REPORT }

    /** Owner settings, once, after a run whose recount read 0. DRAFT, merge-gated: Chester approves the wording
     *  (## Mockup for Chester, NWP-20261208-20). */
    static final String REMOVED = "A fingerprint or face had been saved on this phone's gate, so it was removed: what is saved there stays for every profile.";
    /** Owner settings, while the last run answered REPORT. DRAFT, merge-gated: Chester approves the wording
     *  (## Mockup for Chester, NWP-20261208-20). */
    static final String REPORTED = "A fingerprint or face is saved on this phone's gate and could not be removed. Remove it in System settings: it stays for every profile.";

    /** What one run needs from the platform. GateBiometricRemove implements it with FingerprintManager / FaceManager. */
    interface Port {
        /** User 0's fingerprint templates plus its face templates. A manager the phone lacks counts 0. */
        int enrolled() throws Exception;
        /** True when every manager that holds a template has a removal call. */
        boolean canRemove();
        /** Removes user 0's templates. The recount, not this call, is the verdict. */
        void removeAll() throws Exception;
        /** The "removed, not yet shown" marker. */
        void writeMarker();
        /** One log line. It is never given a template, its name or its id. */
        void log(String line);
    }

    /**
     * One run = count, remove, count again. Returns the action for the Owner settings line, or null when the first
     * count failed (nothing is removed then). The summary line holds digits and the action name only; after = -1 when
     * no second count was made or it failed.
     */
    static Action run(Port p) {
        int n;
        try {
            n = p.enrolled();
        } catch (Throwable t) {
            p.log("enrolled failed (" + t.getClass().getSimpleName() + ")");
            return null;
        }
        int m = -1;
        Action a;
        if (n == 0) {
            a = Action.NONE;
        } else if (!p.canRemove()) {
            a = Action.REPORT;
        } else {
            boolean called;
            try {
                p.removeAll();
                called = true;
            } catch (Throwable t) {
                p.log("removeAll threw (" + t.getClass().getSimpleName() + ")");
                called = false;
            }
            if (!called) {
                a = Action.REPORT;
            } else {
                try {
                    m = p.enrolled();
                } catch (Throwable t) {
                    p.log("recount failed (" + t.getClass().getSimpleName() + ")");
                    m = -1;
                }
                a = m == 0 ? Action.REMOVED : Action.REPORT;
            }
        }
        if (a == Action.REMOVED) p.writeMarker();
        p.log("biometric-clear: before=" + n + " after=" + m + " -> " + a);
        return a;
    }

    /** The Owner settings line: REMOVED while the marker is present, REPORTED while the last run reported, else null. */
    static String noticeLine(boolean markerExists, Action last) {
        if (markerExists) return REMOVED;
        if (last == Action.REPORT) return REPORTED;
        return null;
    }

    /** False once REMOVED was shown, so the caller deletes the marker and the notice shows once. */
    static boolean keepsMarker(String shownLine) {
        return !REMOVED.equals(shownLine);
    }
}
