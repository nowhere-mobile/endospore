package com.nowhere.chooser;

/** NWP-20261129-02: what one TelIngest run inserted and whether the session's reader can see it, sent as one
 *  TELINGEST-SEEN line so login.log, which an issue report carries, tells a hidden row from a delivered one.
 *  line() is the wire order "sms smsHidden mms mmsHidden unknown addr parts", decimal, each clamped to 0..99999 (the
 *  agent refuses more than five digits). Counts only: never a number, a body or a time. Pure, java.lang and java.util
 *  only, so test-tel-seen-java.sh compiles it alone. */
final class TelSeen {
    final java.util.Set<Long> sms = new java.util.LinkedHashSet<>();
    final java.util.Set<Long> mms = new java.util.LinkedHashSet<>();
    int smsHidden;
    int mmsHidden;
    int unknown;
    int addrNotInserted;
    int partsNotInserted;

    /** A row counts once however many passes insert it. */
    void inserted(String kind, long when) {
        if ("mms".equals(kind)) mms.add(when); else sms.add(when);
    }

    /** TRUE visible (counts nothing), FALSE hidden, null unknown: a read that cannot see is never hidden. */
    void readBack(String kind, Boolean present) {
        if (present == null) { unknown++; return; }
        if (present) return;
        if ("mms".equals(kind)) mmsHidden++; else smsHidden++;
    }

    void addr(boolean inserted) { if (!inserted) addrNotInserted++; }

    void part(boolean inserted) { if (!inserted) partsNotInserted++; }

    /** A row inserted, or an addr or part failure. */
    boolean any() {
        return !sms.isEmpty() || !mms.isEmpty() || addrNotInserted > 0 || partsNotInserted > 0;
    }

    String line() {
        return clamp(sms.size()) + " " + clamp(smsHidden) + " " + clamp(mms.size()) + " " + clamp(mmsHidden) + " "
                + clamp(unknown) + " " + clamp(addrNotInserted) + " " + clamp(partsNotInserted);
    }

    /** A live run never sends: sign-in deliveries only (docs/product-decisions.md 2026-11-06, harvest 60 #4). */
    static boolean sends(boolean live, TelSeen s) {
        return !live && s != null && s.any();
    }

    static int clamp(int v) {
        return v < 0 ? 0 : v > 99999 ? 99999 : v;
    }
}
