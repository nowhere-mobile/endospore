package com.nowhere.chooser;

/**
 * NWP-20261108-07 (Q018, docs/product-decisions.md 2026-10-20): which form the owner's stored check is in, and what a
 * verify makes of it. A StrongBox phone whose chip failed at setup stored the PBKDF2 form; a later verify with a working
 * chip computes the chip form, and comparing only that one locked the right passphrase out. Pure java.lang so a javac
 * suite can pin it (core/vendor-common/bin/test-owner-verify-form-java.sh); ChooserActivity.verifyOwner does the I/O
 * (the count before the derive, the conf write, the key mint) and calls this. NWP-20261108-11 adds the setup half:
 * ChooserActivity.enrollOwner retries a silent chip twice and reports through enrolResult whether it is still silent,
 * so the gate can say so instead of only "device passphrase set". NWP-20261120-04 (#26, docs/product-decisions.md
 * 2026-10-22) adds lostKey: a chip that lost the owner key is told from a wrong passphrase, and the gate opens re-setup.
 */
final class OwnerVerifyForm {
    private OwnerVerifyForm() {}

    static final String CHIP_DOWN_LINE = "this phone's security chip didn't answer — try again";

    /**
     * What an owner enrol tells its screen. ENROL_FAILED = the new check did not reach disk (the screen says try again);
     * ENROL_OK = it did; ENROL_OK_NO_CHIP = it did, but the StrongBox chip stayed silent through the retries, so either
     * the PBKDF2 form is stored or the chip form is stored with no pepper, and no owner key was minted. Setup is never
     * refused for a silent chip (Q018).
     */
    static final int ENROL_FAILED = 0, ENROL_OK = 1, ENROL_OK_NO_CHIP = 2;

    /** True in both silent-chip cases: the next verify with a working chip upgrades a PBKDF2-form check and mints the key. */
    static final String ENROL_NO_CHIP_LINE = "device passphrase set — this phone's security chip didn't respond, so the chip's part isn't set up yet. Opening Owner settings with this passphrase sets it up once the chip responds.";

    /** onDisk = the read-back matched what was written; noChip = the derive that was written is seBroken. */
    static int enrolResult(boolean onDisk, boolean noChip) { return !onDisk ? ENROL_FAILED : noChip ? ENROL_OK_NO_CHIP : ENROL_OK; }

    /**
     * MATCH = the stored check is the chip form and it matched; UPGRADE = the stored check is the PBKDF2 form and it
     * matched while the chip answers, so it is rewritten as the chip form; MATCH_NO_CHIP = the PBKDF2 form matched on a
     * StrongBox phone whose chip is silent (nothing to upgrade to yet); CHIP_DOWN = nothing matched, the chip is silent
     * on a StrongBox phone, so the stored form cannot be told; WRONG = nothing matched.
     */
    enum Outcome { MATCH, UPGRADE, MATCH_NO_CHIP, CHIP_DOWN, WRONG }

    /**
     * stored = owner.conf's check; chipHex = the chip's HMAC, empty when the chip did not answer; pbkdfHex = the
     * PBKDF2 hex of the typed passphrase; strongBox = the phone has a StrongBox. Both comparisons are always made, so
     * what answers cannot be read off the time taken.
     */
    static Outcome check(String stored, String chipHex, String pbkdfHex, boolean strongBox) {
        boolean chip = chipHex != null && !chipHex.isEmpty();
        boolean chipEq = constEq(chip ? chipHex : "", stored);
        boolean pbkdfEq = constEq(pbkdfHex, stored);
        if (stored == null || stored.isEmpty() || pbkdfHex == null || pbkdfHex.isEmpty()) return Outcome.WRONG;
        if (chip) return chipEq ? Outcome.MATCH : pbkdfEq ? Outcome.UPGRADE : Outcome.WRONG;
        if (pbkdfEq) return strongBox ? Outcome.MATCH_NO_CHIP : Outcome.MATCH;
        return strongBox ? Outcome.CHIP_DOWN : Outcome.WRONG;
    }

    static boolean matched(Outcome o) { return o == Outcome.MATCH || o == Outcome.UPGRADE || o == Outcome.MATCH_NO_CHIP; }

    /** What owner.conf keeps as the check after this outcome: the chip form on an UPGRADE, else what it held. */
    static String toStore(Outcome o, String stored, String chipHex) { return o == Outcome.UPGRADE ? chipHex : stored; }

    /** NWP-20261120-04: what a completed Keystore lookup of the `nowhere_owner` alias said. UNKNOWN = the lookup threw. */
    static final int ALIAS_UNKNOWN = 0, ALIAS_PRESENT = 1, ALIAS_MISSING = 2;

    static final String LOST_KEY_TITLE = "Set up Owner settings again";
    static final String LOST_KEY_LINE = "This phone's security chip no longer has the key that protected Owner settings, so the device passphrase can't be checked. Set a new device passphrase. Messages and calls for the unassigned line that arrived before now can't be opened.";

    /**
     * NWP-20261120-04 (#26): true when the chip's owner key is gone, by exactly the decision's two signals: (a) the
     * Keystore reports the alias missing, or (b) the chip answers with a key-check value that is not the stored one.
     * storedKcv = owner.conf's kcv, empty for a conf written before it or by a silent chip; kcvNow = the chip's kcv now,
     * empty when it did not answer. Never true without StrongBox or without a stored kcv, never for UNKNOWN, and never
     * for a silent chip (that stays CHIP_DOWN): a false true sends the owner to an enrol that replaces the owner key.
     */
    static boolean lostKey(boolean strongBox, String storedKcv, int aliasState, String kcvNow) {
        if (!strongBox || storedKcv == null || storedKcv.isEmpty()) return false;
        if (aliasState == ALIAS_MISSING) return true;
        return aliasState == ALIAS_PRESENT && kcvNow != null && !kcvNow.isEmpty() && !constEq(kcvNow, storedKcv);
    }

    private static boolean constEq(String a, String b) {
        if (a == null || b == null || a.length() != b.length()) return false;
        int d = 0;
        for (int i = 0; i < a.length(); i++) d |= a.charAt(i) ^ b.charAt(i);
        return d == 0;
    }
}
