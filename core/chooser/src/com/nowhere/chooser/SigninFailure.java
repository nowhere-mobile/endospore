package com.nowhere.chooser;

/**
 * NWP-20261023-08: the verdict on a failed sign-in or create -- which line the gate shows, and whether it may offer the
 * snapshot rollback. Pure java.lang so a javac suite pins it (core/vendor-common/bin/test-signin-failure-java.sh);
 * ChooserActivity.roamLogin reads the reply, switches on {@link #of} and paints.
 *
 * THE ORDER IS THE SAFETY PROPERTY. The rollback ("Restore last good version") is a permanent step back to an older
 * save, so it is reachable only from a reply that says the restore itself failed after progress. BLANK NET (the store
 * could not be reached, NWP-20260910-06), an empty reply (our own socket timed out), ERR-UNRECORDED (the daemon could
 * not write its session marker, NWP-20261013-31) and ERR-CREATEUSER (the phone refused to create the user,
 * NWP-20261023-08), ERR-TIMEOUT and ERR-WORKER-BUSY are all decided BEFORE the progress flag, so none of them can reach it however much progress was seen.
 *
 * ERR-TIMEOUT is the daemon's own stall budget or hard cap, the same situation as the gate's socket timeout: the restore
 * may still be running, so per NWP-20260910-06 it never gets the rollback. ERR-WORKER-BUSY means nothing was attempted
 * (NWP-20261022-02): neither a credential verdict nor a damaged save (NWP-20261023-02).
 *
 * THE BLIND RULE. Every other reply -- a plain BLANK, an unknown ERR- -- stays BLANK, so a wrong passphrase and an
 * unknown profile still read identically. The named replies are network or phone state and credential-independent:
 * a wrong passphrase on the same dead network gets the same BLANK NET, and ERR-CREATEUSER is decided on the phone
 * before any store contact, so a line of its own says nothing about which profiles exist.
 *
 * A create's PHONE_FAULT line does not say "Nothing was changed": CREATE had already answered OK when the user could not
 * be opened. Its wording follows the create path's no-answer message (NWP-20261007-09).
 */
final class SigninFailure {
    private SigninFailure() {}

    enum Verdict { STORE_HINT, STORE_UNREACHABLE, TIMED_OUT, WORKER_BUSY, PHONE_FAULT, CREATE_FAILED, OFFER_ROLLBACK, BLANK }

    static final String UNREACHABLE = "Couldn't reach your storage — check your connection and try again.";
    static final String SETUP_UNFINISHED = "Couldn't finish setting up — check your connection and try again.";
    static final String SIGNIN_SLOW = "Signing in took too long — check your connection and try again.";
    static final String SIGNIN_BUSY = "The phone is still finishing your last sign-in. Wait a minute, then try again.";
    static final String CREATE_BUSY = "Your profile was created, but the phone is still finishing an earlier sign-in. Wait a minute, then sign in.";
    static final String UNRECORDED = "The phone couldn't start your session (a storage error on the phone, not your passphrase). Nothing was changed — try again.";
    static final String CREATEUSER = "The phone couldn't start your session (a problem on the phone, not your passphrase). Nothing was changed — try again.";
    static final String CREATE_PHONE_FAULT = "The phone couldn't open your new profile (a problem on the phone, not your passphrase). Tap Create again: if it says the profile already exists, sign in instead.";

    /** The verdict for a failed login. A null reply is an empty one. */
    static Verdict of(String reply, boolean sawRestoreProgress, boolean isCreate) {
        String r = reply == null ? "" : reply;
        if (r.startsWith("NOSTORE")) return Verdict.STORE_HINT;
        if (r.startsWith("BLANK NET")) return Verdict.STORE_UNREACHABLE;
        if (r.isEmpty()) return Verdict.TIMED_OUT;
        if (r.startsWith("ERR-TIMEOUT")) return Verdict.TIMED_OUT;
        if (r.startsWith("ERR-WORKER-BUSY")) return Verdict.WORKER_BUSY;
        if (r.startsWith("ERR-UNRECORDED") || r.startsWith("ERR-CREATEUSER")) return Verdict.PHONE_FAULT;
        if (sawRestoreProgress) return isCreate ? Verdict.CREATE_FAILED : Verdict.OFFER_ROLLBACK;
        return Verdict.BLANK;
    }

    /** The line to show for a verdict; null where the caller has its own screen (STORE_HINT, OFFER_ROLLBACK, BLANK). */
    static String message(Verdict v, String reply, boolean isCreate) {
        switch (v) {
            case STORE_UNREACHABLE: return UNREACHABLE;
            case TIMED_OUT: return isCreate ? SETUP_UNFINISHED : SIGNIN_SLOW;
            case CREATE_FAILED: return SETUP_UNFINISHED;
            case WORKER_BUSY: return isCreate ? CREATE_BUSY : SIGNIN_BUSY;
            case PHONE_FAULT:
                if (isCreate) return CREATE_PHONE_FAULT;
                return reply != null && reply.startsWith("ERR-CREATEUSER") ? CREATEUSER : UNRECORDED;
            default: return null;
        }
    }

    /**
     * NWP-20261106-11 (Q065): the word the gate sends to the daemon for the line it just showed, one of the codes
     * core/agent/signin_fail.go accepts; null where nothing is recorded. The blind line (BLANK) is never recorded, so a
     * wrong passphrase and an unknown profile still leave nothing, and a create's failure is not a sign-in's.
     */
    static String shownCode(Verdict v, String reply) {
        switch (v) {
            case STORE_HINT: return "nostore";
            case STORE_UNREACHABLE: return "unreachable";
            case TIMED_OUT: return "slow";
            case WORKER_BUSY: return "busy";
            case PHONE_FAULT: return reply != null && reply.startsWith("ERR-UNRECORDED") ? "phone-storage" : "phone";
            case OFFER_ROLLBACK: return "load";
            default: return null;
        }
    }
}
