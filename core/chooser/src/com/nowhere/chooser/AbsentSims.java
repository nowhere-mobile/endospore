package com.nowhere.chooser;

/** NWP-20261116-20 (#73, Q118, docs/product-decisions.md 2026-10-22): owner mode's SIM lines also list each stored
 *  binding whose SIM is not in the phone, with its own Unbind, so an operator who pulled a bound SIM before unassigning
 *  it can still see and remove that line. rows picks those entries from bindingSummaries' list ({subId, iccid,
 *  "<n> bound · <vis>", label, vis}) the way fillSimRows matches its active rows: by ICCID (iccEq, the trailing 'F'
 *  filler ignored), by subId only for an active SIM read with no ICCID. Pure java.* so test-absent-sims-java.sh runs it
 *  under javac. summary shows the ICCID's last four digits only, on the owner's own screen. */
final class AbsentSims {
    static final String TITLE = "SIM not in this phone";

    private AbsentSims() {}

    /** The stored lines no active SIM matches, the first per ICCID, in stored order. Null sums give an empty list. */
    static java.util.List<String[]> rows(java.util.List<String[]> sums, java.util.List<String> activeIccids,
                                         java.util.List<Integer> activeSubIdsWithoutIccid) {
        final java.util.List<String[]> out = new java.util.ArrayList<>();
        if (sums == null) return out;
        for (String[] e : sums) {
            if (e == null || e.length < 5) continue; // TelArrival.DAMAGED_ROW has three fields
            if (e[1] == null || e[1].trim().isEmpty()) continue; // iccEq is false for an empty ICCID: not "absent"
            if (present(e, activeIccids)) continue;
            if (shownBySubId(e, activeSubIdsWithoutIccid)) continue;
            if (seen(e, out)) continue;
            out.add(e);
        }
        return out;
    }

    private static boolean present(String[] e, java.util.List<String> activeIccids) {
        if (activeIccids == null) return false;
        for (String a : activeIccids) if (BindFormFields.iccEq(a, e[1])) return true;
        return false;
    }

    // fillSimRows' own fallback: an active SIM read with no ICCID takes the line of its subId.
    private static boolean shownBySubId(String[] e, java.util.List<Integer> activeSubIdsWithoutIccid) {
        if (activeSubIdsWithoutIccid == null) return false;
        for (Integer id : activeSubIdsWithoutIccid) if (id != null && String.valueOf(id).equals(e[0])) return true;
        return false;
    }

    private static boolean seen(String[] e, java.util.List<String[]> kept) {
        for (String[] k : kept) if (BindFormFields.iccEq(k[1], e[1])) return true;
        return false;
    }

    /** "ends <last four> · <n> bound · <vis>", for example "ends 1234 · 2 bound · open". */
    static String summary(String[] e) {
        return "ends " + last4(e[1]) + " · " + e[2];
    }

    // ChooserActivity.icc4's rule: digits only, the last four (all of them when fewer).
    private static String last4(String iccid) {
        if (iccid == null) return "????";
        String d = iccid.replaceAll("[^0-9]", "");
        return d.length() >= 4 ? d.substring(d.length() - 4) : d;
    }
}
