package com.nowhere.chooser;

/**
 * NWP-20261118-04 (h48 #1, docs/product-decisions.md 2026-10-30): the gate removes a screen lock set on user 0.
 *
 * User 0 is the gate. A PIN, pattern or password set there (Owner settings › System settings asks for one before a
 * fingerprint enrolment) leaves user 0 RUNNING_LOCKED at the next boot, and the chooser, user 0's HOME, never starts:
 * the phone stops at a lock screen (lynx, 2026-10-29). The decision: the gate clears it each time the gate starts and
 * each time the owner returns from System settings, with the reset-token call CredentialService already uses for a
 * session's lock, and Owner settings says once that it did. For its own user the gate KEEPS the token (option 2 of
 * the h48 question), so a lock set later is cleared with no typing.
 *
 * This class holds the decision, the order of one run and the two texts. GateLockToken holds the token file, the marker
 * and the DevicePolicyManager calls, behind Port. Pure java.*: test-gate-lock-clear-java.sh compiles this file alone
 * under javac.
 *
 * The inputs: secure = user 0 has a screen lock (KeyguardManager.isDeviceSecure); stored = the token file holds a
 * token; active = isResetPasswordTokenActive. A token set while a lock exists stays inactive until that lock is next
 * typed. So secure && stored && !active is a WAIT, never a replace: a replaced token is inactive again, and the wait
 * would never end.
 */
final class GateLockClear {
    private GateLockClear() {}

    enum Action { NONE, SET_TOKEN, CLEAR, SET_TOKEN_REPORT, REPORT }

    /** Owner settings, once, after a CLEAR that returned true. */
    static final String CLEARED = "A screen lock had been set on this phone's gate, so it was removed: a lock there stops every restart before the gate.";
    /** Owner settings, while the last run answered REPORT or SET_TOKEN_REPORT. */
    static final String REPORTED = "A screen lock is set on this phone's gate. It will be removed after it is next entered; until then every restart stops at it.";

    /** The action for one run, total over the eight inputs. */
    static Action decide(boolean secure, boolean stored, boolean active) {
        if (secure) {
            // A token we hold no bytes for cannot clear, active or not: set one; it activates once the lock is typed.
            if (!stored) return Action.SET_TOKEN_REPORT;
            // Never replace an inactive kept token: the replacement would wait for the same typing again.
            return active ? Action.CLEAR : Action.REPORT;
        }
        // No lock: a new token activates at once, so replace anything but a kept, active one.
        return stored && active ? Action.NONE : Action.SET_TOKEN;
    }

    /** A CLEAR that returned false or threw becomes REPORT for this run; the next run decides again (no retry loop). */
    static Action afterClear(boolean clearReturnedTrue) {
        return clearReturnedTrue ? Action.CLEAR : Action.REPORT;
    }

    /** The "cleared, not yet shown" marker is written only after a CLEAR that returned true. */
    static boolean writesMarker(Action afterClearResult) {
        return afterClearResult == Action.CLEAR;
    }

    /** What one run needs from the platform. GateLockToken implements it with DevicePolicyManager and the files dir. */
    interface Port {
        /** KeyguardManager.isDeviceSecure: user 0 has a screen lock. */
        boolean secure() throws Exception;
        /** The kept token's bytes, or null when the file is absent or does not hold a token. */
        byte[] storedToken();
        /** isResetPasswordTokenActive. Its documented contract throws IllegalStateException when no token exists. */
        boolean active() throws Exception;
        /** A new token, set on the platform and then kept in the file. */
        void setToken();
        /** resetPasswordWithToken(admin, null, token, 0): true when the lock was removed. */
        boolean clear(byte[] token) throws Exception;
        /** The "cleared, not yet shown" marker. */
        void writeMarker();
        /** One log line. It is never given the token. */
        void log(String line);
    }

    /**
     * One run = read the state, decide, act. Returns the action for the Owner settings line, or null when a read failed
     * (never a blind CLEAR or replace). The kept token is read BEFORE the activation query: without kept bytes the
     * action does not depend on activation, so the query is not made. That query throws IllegalStateException when no
     * token exists (the documented contract), and a run that stopped there set no token and reported nothing. With kept
     * bytes, that exception means the platform holds no token, so the bytes cannot clear: the run sets a new one.
     */
    static Action run(Port p) {
        boolean secure;
        try {
            secure = p.secure();
        } catch (Throwable t) {
            p.log("isDeviceSecure failed (" + t.getClass().getSimpleName() + ")");
            return null;
        }
        byte[] token = p.storedToken();
        try {
            boolean stored = token != null;
            boolean active = false;
            if (stored) {
                try {
                    active = p.active();
                } catch (IllegalStateException e) {
                    stored = false;
                    p.log("the platform holds no token, so the kept one cannot clear");
                } catch (Throwable t) {
                    p.log("isResetPasswordTokenActive failed (" + t.getClass().getSimpleName() + ")");
                    return null;
                }
            }
            Action a = decide(secure, stored, active);
            switch (a) {
                case SET_TOKEN:
                case SET_TOKEN_REPORT:
                    p.setToken();
                    break;
                case CLEAR: {
                    boolean ok;
                    try {
                        ok = p.clear(token);
                    } catch (Throwable t) {
                        p.log("clear threw (" + t.getClass().getSimpleName() + ")");
                        ok = false;
                    }
                    a = afterClear(ok);
                    if (writesMarker(a)) p.writeMarker();
                    break;
                }
                default: // REPORT, NONE: nothing to do
                    break;
            }
            p.log("secure=" + secure + " stored=" + stored + " active=" + active + " action=" + a);
            return a;
        } finally {
            if (token != null) java.util.Arrays.fill(token, (byte) 0);
        }
    }

    /** The Owner settings line: CLEARED while the marker is present, REPORTED while the last run reported, else null. */
    static String noticeLine(boolean markerPresent, Action last) {
        if (markerPresent) return CLEARED;
        if (last == Action.REPORT || last == Action.SET_TOKEN_REPORT) return REPORTED;
        return null;
    }

    /** False once CLEARED was shown, so the caller deletes the marker and the notice shows once. */
    static boolean keepsMarker(String shownLine) {
        return !CLEARED.equals(shownLine);
    }
}
