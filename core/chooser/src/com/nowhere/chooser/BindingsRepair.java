package com.nowhere.chooser;

/** NWP-20261110-06 (Q031, docs/product-decisions.md 2026-10-20): owner mode's "Repair SIM bindings" -- its copy and the
 *  mapping from the daemon's REPAIR-BINDINGS reply (NWP-20261110-02: OK CLEAN | OK REPAIRED n | OK REPLACED | ERR io |
 *  BUSY, and DENIED for a caller that is not the gate) to the one line the owner sees. Pure java.* so
 *  test-bindings-repair-java.sh can run it under javac. No line holds a count: not of SIMs, lines or owners. */
final class BindingsRepair {
    private BindingsRepair() {}

    /** The row's label: the name the decision gives it. */
    static final String ROW = "Repair SIM bindings";
    static final String ROW_SUMMARY = "Keep the bindings that can be read, drop the damaged ones";
    static final String TITLE = "Repair SIM bindings?";

    /** What a repair does, said before it runs. */
    static final String CONFIRM = "Repair keeps every SIM binding this phone can still read and drops the damaged ones. "
            + "Afterwards, a SIM with no binding is not this phone's own line until you mark it so, and its texts and "
            + "calls can't be kept until it is bound or marked.";

    static final String REPAIRED = "SIM bindings repaired: the damaged ones were dropped. Bind again any SIM that lost its binding.";
    static final String REPLACED = "SIM bindings replaced: bind each SIM again.";
    static final String CLEAN = "SIM bindings can be read — nothing needed repairing.";
    static final String BUSY = "the phone is busy — try again";
    static final String IO = "Couldn't repair the SIM bindings — the phone's storage may be at fault. "
            + "Resetting the phone is the way out.";
    static final String FAILED = "couldn't repair — try again";

    /** True only for a reply that says the repair ran (or found nothing to do): the caller reloads the SIM lines then. */
    static boolean ok(String reply) {
        String t = reply == null ? "" : reply.trim();
        return t.equals("OK CLEAN") || t.equals("OK REPLACED") || t.matches("OK REPAIRED [0-9]+");
    }

    /** The line shown for a reply; a success line exactly when ok(reply). */
    static String outcome(String reply) {
        String t = reply == null ? "" : reply.trim();
        if (t.equals("OK CLEAN")) return CLEAN;
        if (t.equals("OK REPLACED")) return REPLACED;
        if (t.matches("OK REPAIRED [0-9]+")) return REPAIRED;
        if (t.equals("BUSY")) return BUSY;
        if (t.equals("ERR io") || t.startsWith("ERR io ")) return IO;
        return FAILED;
    }
}
