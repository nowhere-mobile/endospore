package com.nowhere.chooser;

/**
 * NWP-20261122-13: the one line a session's Preferences shows while the phone has an active SIM this profile does not
 * own (h52 #3 in docs/product-decisions.md, the 2026-11-01 entry "twenty-two answers to harvests 50, 51 and 52 ...").
 * The gate (user 0) works out the case at sign-in and at each re-verdict after a bind or unbind (NWP-20261005-12) and
 * sends its wire form to SimCaseReceiver in the session; ProfileActivity.showPreferences draws line(case).
 *
 * The case is a bit and a count, nothing else: whether the profile owns any SIM, and how many active SIMs it does not
 * own. It carries no SIM identifier and no word about who else holds a SIM, so the words cannot differ between an
 * unbound SIM and one assigned elsewhere, and a session learns nothing about other profiles. Pure java.util -- no
 * Android -- so core/vendor-common/bin/test-foreign-sim-line-java.sh runs it under plain javac.
 */
final class ForeignSimLine {

    /** The case: ownsAny, and notOwned = the active SIMs this profile does not own (never negative). */
    static final class Case {
        final boolean ownsAny;
        final int notOwned;
        Case(boolean ownsAny, int notOwned) {
            if (notOwned < 0) throw new IllegalArgumentException("notOwned < 0");
            this.ownsAny = ownsAny;
            this.notOwned = notOwned;
        }
    }

    // The h52 #3 drafts, written out (Chester corrects them in the entry, then here). The decision gives the
    // plural as "SIMs" and "them"; the agreement around them ("other SIMs that aren't", "they can't", "the SIMs")
    // is this slice's reading of that rule.
    static final String OWNS_ONE = "This phone has another SIM that isn't assigned to this profile, so it can't be"
            + " used here. The phone's owner manages it from owner mode at the gate.";
    static final String OWNS_MANY = "This phone has other SIMs that aren't assigned to this profile, so they can't be"
            + " used here. The phone's owner manages them from owner mode at the gate.";
    static final String NONE_ONE = "No SIM on this phone is assigned to this profile, so calls and texts can't be made"
            + " here. Emergency calls still work. The phone's owner manages the SIM from owner mode at the gate.";
    static final String NONE_MANY = "No SIM on this phone is assigned to this profile, so calls and texts can't be made"
            + " here. Emergency calls still work. The phone's owner manages the SIMs from owner mode at the gate.";

    private static final java.util.regex.Pattern WIRE = java.util.regex.Pattern.compile("[01] (0|[1-9][0-9]{0,3})");

    /** The wire form: "<0|1> <n>". */
    static String encode(Case c) {
        return (c.ownsAny ? "1" : "0") + " " + c.notOwned;
    }

    /** The case from its wire form, or null for anything that is not exactly "<0|1> <n>" (n a plain decimal). */
    static Case decode(String s) {
        if (s == null || !WIRE.matcher(s).matches()) return null;
        return new Case(s.charAt(0) == '1', Integer.parseInt(s.substring(2)));
    }

    /** The counting rule both gate walks use: a SIM counts only when OwnedSims.target says HIDE. SKIP (an unreadable
     *  ICCID, the fail-open rule) and VISIBLE (owned) do not count. */
    static boolean notOwned(int target) {
        return target == OwnedSims.HIDE;
    }

    /** The line for c, or null when there is nothing to say (no case, or no SIM it does not own). */
    static String line(Case c) {
        if (c == null || c.notOwned == 0) return null;
        boolean many = c.notOwned >= 2;
        if (c.ownsAny) return many ? OWNS_MANY : OWNS_ONE;
        return many ? NONE_MANY : NONE_ONE;
    }
}
