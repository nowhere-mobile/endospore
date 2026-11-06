package com.nowhere.chooser;

/** The owner-mode bind form's ICCID match and the label + visibility it sends (NWP-20261021-04). Pure java.lang so it
 *  runs under plain javac (core/vendor-common/bin/test-bind-form-fields-java.sh). setBindingOwner overwrites a line's
 *  label and visibility on every bind, and "Enter a SIM manually" starts from no SIM row, so a manual bind of an
 *  already-bound ICCID sent blanks and "open": a line labelled "Work" and set Private went unlabelled and Open.
 *  forBind sends the stored values instead, unless the owner edited them on the form. */
final class BindFormFields {
    private BindFormFields() {}

    // ICCID equality that tolerates the trailing 'F' filler nibble: an ICCID with an odd significant-digit count
    // is padded to an even length with 'F', and getIccId() / the telephony DB may hand it back with or without the
    // pad (e.g. 19 vs 20 chars for the SAME physical SIM). Used so a renumbered SIM still matches its binding.
    static boolean iccEq(String a, String b) {
        if (a == null || b == null) return false;
        a = a.trim().toLowerCase(); b = b.trim().toLowerCase();
        if (a.isEmpty() || b.isEmpty()) return false;
        if (a.endsWith("f")) a = a.substring(0, a.length() - 1);
        if (b.endsWith("f")) b = b.substring(0, b.length() - 1);
        return a.equals(b);
    }

    /** {label, vis, kept} for SET-BINDING, from what the form holds and bindingSummaries()' entries. null when sums is
     *  null (GET-BINDINGS gave no reply), so the caller sends nothing. The stored line is the first entry of five
     *  fields whose ICCID matches; a short entry (TelArrival.DAMAGED_ROW) is skipped, and an empty list
     *  (TelArrival.DAMAGED_BINDINGS) has none. An edited field wins; an unedited one takes the line's own value.
     *  kept = "1" when what is sent differs from what the form showed. */
    static String[] forBind(String typedIccid, String typedLabel, boolean labelEdited, String typedVis, boolean visEdited,
                            java.util.List<String[]> sums) {
        if (sums == null) return null;
        String[] line = null;
        for (String[] e : sums) if (e.length >= 5 && iccEq(typedIccid, e[1])) { line = e; break; }
        String label = typedLabel, vis = typedVis;
        if (line != null) {
            label = labelEdited ? typedLabel : line[3];
            vis = visEdited ? typedVis : "notify".equals(line[4]) || "private".equals(line[4]) ? line[4] : "open";
        }
        return new String[]{ label, vis, label.equals(typedLabel) && vis.equals(typedVis) ? "0" : "1" };
    }

    /** The labels GET-BINDINGS lists for one SIM line, for owner mode's Clear notices (NWP-20261105-05, Q103): e[3] of
     *  every five-field entry whose ICCID matches, one per co-owner row. null when sums is null (GET-BINDINGS gave no
     *  reply); otherwise never null, possibly empty, because a null makes cancelTelNotices clear every line. A short
     *  entry (TelArrival.DAMAGED_ROW) is skipped; the caller checks TelArrival.DAMAGED_BINDINGS before calling. */
    static java.util.Set<String> lineLabels(java.util.List<String[]> sums, String iccid) {
        if (sums == null) return null;
        java.util.Set<String> out = new java.util.HashSet<>();
        for (String[] e : sums) if (e.length >= 5 && iccEq(iccid, e[1])) out.add(e[3]);
        return out;
    }
}
