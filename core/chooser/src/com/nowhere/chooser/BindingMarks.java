package com.nowhere.chooser;

/** NWP-20261110-07 (Q031, docs/product-decisions.md 2026-10-20): which SIM is this phone's own line. In a rebuilt
 *  bindings file (a repair rewrote it) a SIM that no line names stays unresolved until the owner binds it or marks it
 *  "mine"; in any other file such a SIM is the owner's line. GET-BINDINGS gives the marks after its binding lines
 *  (NWP-20261110-02): "REBUILT" when the file is rebuilt, then one "MINE <iccid>" per mine record. SET-SIM-MINE
 *  ("SET-SIM-MINE\n<iccid>\n<1|0>\n") adds or removes one mark and answers OK | OK UNCHANGED | OK NOTREBUILT |
 *  ERR repair | ERR damaged | ERR io | ERR | BUSY | DENIED; mineOutcome maps that reply to the one line the owner sees.
 *  Pure java.* so test-binding-marks-java.sh runs it under javac. No line holds a count, a profile name or an ICCID. */
final class BindingMarks {
    /** The reply says the file is rebuilt, or the reply is not an answer (fail closed: no SIM is the owner's line). */
    final boolean rebuilt;
    private final java.util.List<String> mine;

    private BindingMarks(boolean rebuilt, java.util.List<String> mine) {
        this.rebuilt = rebuilt;
        this.mine = mine;
    }

    static final String OWN_LINE = "this phone's own line";
    static final String NOT_OWN_LINE = "not bound — not this phone's own line";
    static final String MARK_ROW = "Use as this phone's own line";
    static final String MARK_SUMMARY = "Its texts and calls go to owner mode's inbox, and owner mode can text and call on it";
    static final String UNMARK_ROW = "Stop using as this phone's own line";
    static final String UNMARK_SUMMARY = "Its texts and calls are kept for nobody until it is bound or marked again";
    static final String DONE = "Saved.";
    static final String REPAIR_FIRST = "Repair SIM bindings first";
    static final String BUSY = "the phone is busy — try again";
    static final String FAILED = "couldn't save — try again";
    /** A key, not shown text: ChooserActivity shows TelArrival.BINDINGS_DAMAGED for it (TelArrival imports android). */
    static final String DAMAGED = "damaged";

    /** The marks of a GET-BINDINGS reply. NONE (no file) is not rebuilt. A reply that is neither NONE nor OK (no reply,
     *  BUSY, ERR damaged) counts as rebuilt with no mark, so no SIM is the owner's line; the callers' own damage guards
     *  run first, so this is defence in depth. A five-field binding line and DAMAGED are not marks. */
    static BindingMarks parse(java.util.List<String> lines) {
        java.util.List<String> mine = new java.util.ArrayList<>();
        if (lines == null || lines.isEmpty() || lines.get(0) == null) return new BindingMarks(true, mine);
        String head = lines.get(0);
        if (head.startsWith("NONE")) return new BindingMarks(false, mine);
        if (!head.startsWith("OK")) return new BindingMarks(true, mine);
        boolean rebuilt = false;
        for (int i = 1; i < lines.size(); i++) {
            String t = lines.get(i) == null ? "" : lines.get(i).trim();
            if (t.equals("REBUILT")) rebuilt = true;
            else if (t.startsWith("MINE ") && t.indexOf('|') < 0) {
                String m = t.substring(5).trim();
                if (!m.isEmpty()) mine.add(m);
            }
        }
        return new BindingMarks(rebuilt, mine);
    }

    /** True when a SIM that no binding line names is this phone's own line: always outside a rebuilt file; in one,
     *  only a non-empty ICCID that matches a MINE mark (BindFormFields.iccEq, so a trailing 'F' filler is one SIM). */
    boolean ownersLine(String iccid) {
        if (!rebuilt) return true;
        if (iccid == null || iccid.trim().isEmpty()) return false;
        for (String m : mine) if (BindFormFields.iccEq(iccid, m)) return true;
        return false;
    }

    /** True only for "OK": the mark was written, so the caller goes back to the SIM lines. */
    static boolean mineBack(String reply) {
        return "OK".equals(reply == null ? "" : reply.trim());
    }

    /** The line shown for a SET-SIM-MINE reply. OK NOTREBUILT does not arise from the row (it shows only in a rebuilt
     *  file) and reads as done: a SIM no line names is then the owner's line anyway. */
    static String mineOutcome(String reply) {
        String t = reply == null ? "" : reply.trim();
        if (t.equals("OK") || t.equals("OK UNCHANGED") || t.equals("OK NOTREBUILT")) return DONE;
        if (t.equals("ERR repair")) return REPAIR_FIRST;
        if (t.equals("BUSY")) return BUSY;
        if (t.equals("ERR damaged") || t.startsWith("ERR damaged ")) return DAMAGED;
        return FAILED;
    }
}
