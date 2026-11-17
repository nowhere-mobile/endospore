package com.nowhere.chooser;

/** NWP-20261204-10: how TelIngest.deliverMms writes one MMS, decided before the pdu insert. java.* only, so
 *  test-mms-ingest-plan-java.sh compiles it alone. Row: "An inbound text MMS is delivered but shows an empty balloon
 *  in the Messaging app". */
final class MmsIngestPlan {
    private MmsIngestPlan() {}

    /** A text-only MMS: 1 or 2 parts, each application/smil or text/plain, at least one text/plain. Any other text/
     *  type (a vCard), any media, or 3+ parts is not. Such a message is written parts first (deliverMms). */
    static boolean textOnly(java.util.List<String> cts) {
        if (cts == null || cts.isEmpty() || cts.size() > 2) return false;
        boolean text = false;
        for (String ct : cts) {
            if (ct == null) return false;
            if (ct.startsWith("text/plain")) text = true;
            else if (!"application/smil".equals(ct)) return false;
        }
        return text;
    }

    /** #150: a degraded MMS (a note, e.g. "too-large") with no non-empty text and no media gets a hint part. */
    static boolean hint(String note, boolean anyNonEmptyText, boolean anyMedia) {
        return note != null && !note.isEmpty() && !anyNonEmptyText && !anyMedia;
    }

    /** The message id the parts are saved under before the pdu exists: the arrival in ms, far above any provider
     *  _id. The mms/#/part URI takes digits only, so it is never negative (an arrival is always above 0). */
    static long placeholderMid(long when) { return when; }
}
