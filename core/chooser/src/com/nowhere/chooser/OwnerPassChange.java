package com.nowhere.chooser;

/**
 * NWP-20261022-01: the decisions of the owner's device-passphrase change that need no Android -- the rewrap request,
 * what a daemon reply means for owner.conf, the passphrase floor the enrol and the change share, and what the change's
 * re-check of the old passphrase answers (recheckCode, NWP-20261126-20). Pure
 * java.lang/java.util so a javac suite can pin it (core/vendor-common/bin/test-owner-pass-change-java.sh);
 * ChooserActivity.changeOwnerPass does the I/O and calls these.
 */
final class OwnerPassChange {
    private OwnerPassChange() {}

    static final String CHANGED = "device passphrase changed";
    static final String UNCHANGED_MSG = "couldn't change the passphrase — it is unchanged";
    static final String NOT_NOW = "can't change the passphrase right now — try again";

    /** What the daemon's answer to the rewrap permits: write owner.conf, refuse as wrong, or change nothing. */
    enum Step { WRITE_CONF, WRONG, UNCHANGED }

    /** owner_key.go handleOwnerKey's grammar: the old pair, then the new pair; "-" stands for no pepper. */
    static String rewrapRequest(String oldPepperB64, String oldPassB64, String newPepperB64, String newPassB64) {
        return "OWNER-KEY-REWRAP\nv1\n" + p(oldPepperB64) + "\n" + oldPassB64 + "\n" + p(newPepperB64) + "\n" + newPassB64 + "\n";
    }

    private static String p(String x) { return x == null || x.isEmpty() ? "-" : x; }

    /** Only OK (the key was rewrapped) and NOKEY (there is no key to rewrap) let the new passphrase onto disk. */
    static Step step(String reply) {
        String r = reply == null ? "" : reply.trim();
        if (r.equals("OK") || r.equals("NOKEY")) return Step.WRITE_CONF;
        if (r.equals("WRONG")) return Step.WRONG;
        return Step.UNCHANGED;
    }

    /**
     * NWP-20261126-20: what changeOwnerPass's re-check of the old passphrase answers, by the verify's own form rule
     * (OwnerVerifyForm.check on the second derive). 0 = go on (the seBroken guard after it still refuses a pepperless
     * request with -5); -6 = the chip didn't answer; -4 = owner.conf changed underneath.
     */
    static int recheckCode(OwnerVerifyForm.Outcome o) {
        switch (o) {
            case MATCH: case UPGRADE: case MATCH_NO_CHIP: return 0;
            case CHIP_DOWN: return -6;
            default: return -4;
        }
    }

    /** The enrol's floor, in its order; null when the pair passes. */
    static String floorError(String a, String b) {
        if (a.length() < 8) return "use at least 8 characters — a passphrase (several words) is best";
        if (!a.equals(b)) return "the two passphrases don't match";
        return null;
    }
}
