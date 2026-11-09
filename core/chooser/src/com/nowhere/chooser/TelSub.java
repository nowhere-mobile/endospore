package com.nowhere.chooser;

import android.content.ContentValues;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Locale;

/**
 * NWP-20261130-01: which subscription a delivered SMS or MMS is filed under, and when its sealed copy may go.
 *
 * GrapheneOS 2026110200 (TelephonyProvider c756a6ab4) shows a sub_id=-1 row only to user 0, so a row TelIngest filed
 * that way (#148) lands in a session's provider and its Messages never shows it. The decision (docs/product-decisions.md,
 * 2026-11-06, option A plus the interim): the agent names the row's SIM in a slot of its own ("sim:&lt;tag&gt;",
 * serializeTelIngest), the chooser files the row under that SIM's active subscription, and a row the session cannot read
 * back is not acknowledged, so its sealed copy comes back at the next sign-in. Pure, so the suite
 * test-telingest-sub-java.sh runs all of it under javac; only ContentValues is android.
 */
final class TelSub {
    static final int NO_SUB = -1; // SubscriptionManager.INVALID_SUBSCRIPTION_ID: the fallback, and every untagged row

    private TelSub() {}

    /** The active SIMs this user can see, by position: subIds[i] is the subscription of iccids[i]. */
    static final class Sims {
        static final Sims NONE = new Sims(new int[0], new String[0]);
        final int[] subIds;
        final String[] iccids;

        Sims(int[] subIds, String[] iccids) {
            this.subIds = subIds;
            this.iccids = iccids;
        }
    }

    /** The tag in an SMS row's f[6] or an MMS row's f[3], at exactly that position (the agent's rowTag), else null. An
     *  older row has no slot, and a call row keeps its tag in its body slot and is never filed under a subscription. */
    static String rowTag(String[] f) {
        int slot = "sms".equals(f[0]) ? 6 : "mms".equals(f[0]) ? 3 : -1;
        if (slot < 0 || f.length <= slot || !f[slot].startsWith("sim:")) return null;
        String t = f[slot].substring(4);
        return isSimTag(t) ? t : null;
    }

    private static boolean isSimTag(String s) {
        if (s.length() != 16) return false;
        for (int i = 0; i < 16; i++) {
            char c = s.charAt(i);
            if (!(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')) return false;
        }
        return true;
    }

    /** The agent's normICCID: trimmed, lower-case, one trailing 'f' filler stripped. */
    private static String norm(String iccid) {
        String s = iccid.trim().toLowerCase(Locale.ROOT);
        return s.endsWith("f") ? s.substring(0, s.length() - 1) : s;
    }

    /** The agent's simTag: the first 16 hex characters of a hash of the normalised ICCID. A golden vector in both test
     *  sets holds the two together. Never logged: it is a stable name for the SIM. */
    static String simTag(String iccid) {
        try {
            byte[] h = MessageDigest.getInstance("SHA-256")
                    .digest(("nowhere-sim|" + norm(iccid)).getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(16);
            for (int i = 0; i < 8; i++) hex.append(String.format(Locale.ROOT, "%02x", h[i] & 0xff));
            return hex.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** The subscription of the SIM with this tag, else NO_SUB: an untagged row, or the SIM left the phone. An ICCID
     *  that did not read matches nothing. */
    static int subFor(String tag, Sims sims) {
        if (tag == null) return NO_SUB;
        for (int i = 0; i < sims.subIds.length; i++) {
            String iccid = sims.iccids[i];
            if (iccid != null && !norm(iccid).isEmpty() && tag.equals(simTag(iccid))) return sims.subIds[i];
        }
        return NO_SUB;
    }

    /** Files one row: puts its sub_id and returns it, so the caller counts what it filed. */
    static int file(ContentValues v, String tag, Sims sims) {
        int sub = subFor(tag, sims);
        v.put("sub_id", sub);
        return sub;
    }

    /** One SMS or MMS lookup: a reader without READ_SMS gets an EMPTY cursor from the provider, not an error, so its
     *  answer means nothing (null, unknown), whatever the query said. Without this a blind reader reads as "absent":
     *  every row would be inserted again, and never acknowledged. */
    static Boolean lookup(boolean canRead, Boolean present) {
        return canRead ? present : null;
    }

    /** Whether a row's sealed copy may go. An SMS or MMS: only when this session read it back, because a row the
     *  session cannot see is one its Messages cannot show. A call: when it landed (ackLanded then checks the call log). */
    static boolean ackable(String kind, boolean landed, boolean readOk) {
        return "sms".equals(kind) || "mms".equals(kind) ? readOk : landed;
    }

    /** How many SMS and MMS rows of a claimed reply (its first line is the daemon's OK) landed and have not read back. */
    static int notReadBack(List<String> reply, boolean[] everOk, boolean[] readOk) {
        int n = 0;
        for (int i = 1; i < reply.size(); i++) {
            String r = reply.get(i);
            if (everOk[i] && !readOk[i] && (r.startsWith("sms ") || r.startsWith("mms "))) n++;
        }
        return n;
    }

    /** One delivery batch's counts, for its one log line. It takes only ints: no number, body, subject, tag or sub id. */
    static final class Tally {
        int delivered, real, fellBack;

        /** One row the provider took, filed under this subscription. */
        void inserted(int sub) {
            delivered++;
            if (sub == NO_SUB) fellBack++; else real++;
        }

        String line(boolean live, int notReadBack) {
            return "telingest" + (live ? " (live)" : "") + " batch: delivered=" + delivered + " real-sub=" + real
                    + " fell-back=" + fellBack + " not-read-back=" + notReadBack;
        }
    }
}
