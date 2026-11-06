package com.nowhere.chooser;

/** NWP-20261023-12: the two daemon replies that decide which SIMs a signed-in profile owns, parsed in one place so a
 *  test can execute the rules (core/vendor-common/bin/test-owned-sims-java.sh). Pure java.util -- no Android.
 *
 *  Both parsers return null for "change nothing": no reply, an empty reply, or a header that is not the one the daemon
 *  writes. That is the fail-open rule of #158 / #176 -- a read that was cut short or garbled must never block an
 *  owner's outbound telephony (wrongly blocking the owner crash-loops their Messaging) or lock them to a subset of
 *  their SIMs. The caller reads with roundTripLinesOrNull, so a failed read arrives here as null. */
final class OwnedSims {
    private OwnedSims() {}

    /** The live session's verdict: its user id, and the ICCIDs it owns (empty = owns none). */
    static final class Live {
        final int uid;
        final java.util.Set<String> owned;
        Live(int uid, java.util.Set<String> owned) { this.uid = uid; this.owned = owned; }
    }

    /** The live-owned reply: "OK <uid>\n<iccid>\n..." (or "NONE\n" when no session is live). */
    static Live parseLive(java.util.List<String> lines) {
        if (lines == null || lines.isEmpty()) return null;
        String head = lines.get(0) == null ? "" : lines.get(0).trim();
        if (!head.startsWith("OK ")) return null;
        final int uid;
        try { uid = Integer.parseInt(head.substring(3).trim()); } catch (NumberFormatException e) { return null; }
        if (uid <= 0) return null;
        java.util.Set<String> owned = new java.util.LinkedHashSet<>();
        for (int i = 1; i < lines.size(); i++) {
            String l = lines.get(i) == null ? "" : lines.get(i).trim();
            if (!l.isEmpty()) owned.add(l);
        }
        return new Live(uid, owned);
    }

    /** The owned-ICCIDs reply: "OK\n<iccid>\n...". */
    static java.util.Set<String> parseOwned(java.util.List<String> lines) {
        if (lines == null || lines.isEmpty()) return null;
        String head = lines.get(0) == null ? "" : lines.get(0).trim();
        if (!head.equals("OK")) return null;
        java.util.Set<String> owned = new java.util.LinkedHashSet<>();
        for (int i = 1; i < lines.size(); i++) {
            String l = lines.get(i) == null ? "" : lines.get(i).trim();
            if (!l.isEmpty() && !"OK".equals(l)) owned.add(l);
        }
        return owned;
    }

    /** applyOwnerSimLock's per-SIM decision (#176): leave the SIM alone. */
    static final int SKIP = 0;
    /** ... leave it unassociated (null handle): visible to the session, still intercepted at the gate. */
    static final int VISIBLE = 1;
    /** ... associate it with user 0 so the session's pickers cannot offer it. */
    static final int HIDE = 2;

    /** What a bound owner may do with the SIM whose ICCID is `iccid`, given the ICCIDs `owned`. FAIL OPEN: an ICCID
     *  that cannot be read (null, empty or blank) or a null owned set is SKIP -- never risk hiding the owner's own
     *  line. An owned SIM matches through BindFormFields.iccEq, which tolerates the trailing-'F' filler (19 vs 20
     *  chars for the SAME SIM): an exact contains() once misclassified the owner's own SIM as foreign. Every other
     *  SIM is HIDE (the #176 dual-SIM leak: a profile bound to line A sent and called on line B). */
    static int target(java.util.Set<String> owned, String iccid) {
        if (iccid == null || iccid.trim().isEmpty()) return SKIP;
        if (owned == null) return SKIP;
        for (String o : owned) if (BindFormFields.iccEq(o, iccid)) return VISIBLE;
        return HIDE;
    }

    /** The read-back after the write: did the association take? handleUserId is the sub's user handle id read back,
     *  null = unassociated. VISIBLE sticks on null; HIDE sticks only on user 0 (any other handle is a different
     *  user's SIM, not the gate's). SKIP wrote nothing, so nothing sticks. */
    static boolean stuck(int target, Integer handleUserId) {
        if (target == VISIBLE) return handleUserId == null;
        if (target == HIDE) return handleUserId != null && handleUserId == 0;
        return false;
    }
}
