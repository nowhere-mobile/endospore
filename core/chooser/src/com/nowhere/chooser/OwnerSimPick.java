package com.nowhere.chooser;

/** NWP-20261111-20: which unassigned SIM owner Compose starts on, and how a picker row names a SIM. Pure Java, no
 *  android import, so test-owner-sim-pick-java.sh runs it under javac. Backlog row "Owner-mode transmit picks the
 *  FIRST unbound SIM — no arrival-SIM selection on a 2+-unbound-SIM phone". */
final class OwnerSimPick {
    private OwnerSimPick() {}

    /** The index into the unbound list that Compose starts on, or -1 when the owner must choose. The arrival line
     *  (ownerSimIndexFor) wins when it is inside the list. One SIM is the only choice. With two or more SIMs and no
     *  known arrival, nothing is chosen: the old default (the first listed SIM) sent on the wrong line, silently. */
    static int initial(int unboundCount, int arrivalIndex) {
        if (arrivalIndex >= 0 && arrivalIndex < unboundCount) return arrivalIndex;
        if (unboundCount == 1) return 0;
        return -1;
    }

    /** A picker row's text: the carrier and the slot, so two SIMs of one carrier differ. It never shows an ICCID or
     *  a number. activeSims names a SIM with no carrier name "SIM <slot+1>"; that name is not repeated. */
    static String rowLabel(String carrier, int slot) {
        final String c = carrier == null ? "" : carrier.trim();
        if (slot < 0) return c.isEmpty() ? "SIM" : c;
        if (c.isEmpty() || c.equals("SIM " + (slot + 1))) return "SIM " + (slot + 1);
        return carrier + " — SIM " + (slot + 1);
    }
}
