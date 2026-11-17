package com.nowhere.chooser;

/** NWP-20261129-02: what one TelIngest run inserted and whether the session's reader can see it, sent as one
 *  TELINGEST-SEEN line so login.log, which an issue report carries, tells a hidden row from a delivered one.
 *  line() is the wire order "sms smsHidden mms mmsHidden unknown addr parts offDefault defaultAway", decimal, each
 *  clamped to 0..99999 (the agent refuses more than five digits). NWP-20261204-11 adds the last two, for the backlog
 *  row "On GrapheneOS 2026110200 an MMS delivered into a session can arrive without its sender or its parts on a
 *  two-SIM phone". Counts only: never a number, a body, a time or a subscription id. Pure, java.lang and java.util
 *  only, so test-tel-seen-java.sh compiles it alone. */
final class TelSeen {
    final java.util.Set<Long> sms = new java.util.LinkedHashSet<>();
    final java.util.Set<Long> mms = new java.util.LinkedHashSet<>();
    int smsHidden;
    int mmsHidden;
    int unknown;
    int addrNotInserted;
    int partsNotInserted;
    int defaultSms = -1; // NWP-20261204-11: the default SMS subscription, set by run each pass; -1 = none or unread
    int mmsOffDefault;   // an inserted MMS filed under another subscription than the default SMS one
    int mmsDefaultAway;  // an inserted MMS while the default SMS subscription is not among the session's SIMs

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

    /** NWP-20261204-11: one inserted MMS, filed under filedSub, against the default SMS subscription run read this
     *  pass. MmsProvider checks the addr and part inserts (no sub_id) against that default, so these two counts say
     *  whether the row's condition arose beside addrNotInserted and partsNotInserted. sessionSubs null = none. */
    void mmsDefault(int filedSub, int[] sessionSubs) {
        if (defaultSms < 0) return;
        if (defaultSms != filedSub) mmsOffDefault++;
        boolean in = false;
        if (sessionSubs != null) for (int s : sessionSubs) if (s == defaultSms) { in = true; break; }
        if (!in) mmsDefaultAway++;
    }

    /** A row inserted, or an addr or part failure. */
    boolean any() {
        return !sms.isEmpty() || !mms.isEmpty() || addrNotInserted > 0 || partsNotInserted > 0;
    }

    String line() {
        return clamp(sms.size()) + " " + clamp(smsHidden) + " " + clamp(mms.size()) + " " + clamp(mmsHidden) + " "
                + clamp(unknown) + " " + clamp(addrNotInserted) + " " + clamp(partsNotInserted) + " "
                + clamp(mmsOffDefault) + " " + clamp(mmsDefaultAway);
    }

    /** A live run never sends: sign-in deliveries only (docs/product-decisions.md 2026-11-06, harvest 60 #4). */
    static boolean sends(boolean live, TelSeen s) {
        return !live && s != null && s.any();
    }

    static int clamp(int v) {
        return v < 0 ? 0 : v > 99999 ? 99999 : v;
    }
}
