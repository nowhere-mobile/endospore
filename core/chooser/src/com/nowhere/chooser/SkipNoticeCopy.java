package com.nowhere.chooser;

/**
 * NWP-20261128-08: the chooser half of the #119 skip notice -- the daemon reply parser and the decided words. Pure
 * (java.lang only), so test-skip-notice-copy-java.sh compiles it with its cases alone.
 *
 * Backlog row "`pushProfile`'s tombstone skips report "Saved" and the next login tells nobody (#119)". A phone that
 * signed in before a passphrase change on another phone skips its seal at sign-out and writes a notice (core/agent
 * skip_notice.go). The next sign-in reads it and shows it (docs/product-decisions.md 2026-11-01, h50 #6), in the words
 * decided 2026-10-30 (h48 #5), {@link #SENTENCE}, then records it shown.
 *
 * The daemon contract (core/agent skip_notice.go, read-only here):
 *   GET-SKIP-NOTICE\n                -> "NOTICE <phone>\t<unix seconds>" / "NONE" / "ERR"
 *   SKIP-NOTICE-SHOWN\n<unix s>\n    -> "OK" / "ERR"
 * The label carries no control character (skipNoticeLabelForWire), so the reply holds exactly one tab. The label
 * may be empty (deviceLabel() had nothing).
 *
 * ⚠ INFERENCE: an empty label reads {@link #ANOTHER_PHONE}. h48 #5 names {@code <phone>} only and says nothing about
 * a phone with no label; Chester did not state this fallback.
 */
final class SkipNoticeCopy {
    private SkipNoticeCopy() {}

    /** h48 #5, byte for byte. test-skip-notice-copy-java.sh checks it against docs/product-decisions.md. */
    static final String SENTENCE = "Changes made on <phone> after <time> weren't saved, because this profile's passphrase was changed after that phone signed in.";
    /** The empty-label fallback. An inference, not a decided word (see the class comment). */
    static final String ANOTHER_PHONE = "another phone";
    /** The card's one button. */
    static final String OK_BUTTON = "OK";

    private static final String PHONE = "<phone>";
    private static final String TIME = "<time>";
    private static final String PREFIX = "NOTICE ";

    /** One parsed notice: the phone's label (may be empty) and the unix time in seconds (> 0). */
    static final class Notice {
        final String phone;
        final long time;

        Notice(String phone, long time) {
            this.phone = phone;
            this.time = time;
        }
    }

    /** The GET-SKIP-NOTICE reply as a notice, or null for NONE, ERR, an empty or a malformed reply. */
    static Notice parse(String reply) {
        if (reply == null || !reply.startsWith(PREFIX)) return null;
        String rest = reply.substring(PREFIX.length());
        int tab = rest.indexOf('\t');
        if (tab < 0 || tab != rest.lastIndexOf('\t')) return null;
        String phone = rest.substring(0, tab);
        String num = rest.substring(tab + 1);
        if (num.isEmpty()) return null;
        for (int i = 0; i < num.length(); i++) {
            char c = num.charAt(i);
            if (c < '0' || c > '9') return null;
        }
        long t;
        try { t = Long.parseLong(num); } catch (NumberFormatException e) { return null; }
        if (t <= 0) return null;
        return new Notice(phone, t);
    }

    /** The h48 #5 sentence with the phone and the time put in. Spliced by index, so a label that holds the text
     *  "<time>" (or a time that holds "<phone>") cannot move the other slot. */
    static String words(String phone, String when) {
        String p = (phone == null || phone.isEmpty()) ? ANOTHER_PHONE : phone;
        int ip = SENTENCE.indexOf(PHONE);
        int it = SENTENCE.indexOf(TIME);
        return SENTENCE.substring(0, ip) + p + SENTENCE.substring(ip + PHONE.length(), it) + when
                + SENTENCE.substring(it + TIME.length());
    }

    /** The request that records the notice at {@code time} as shown. The time line needs its LF. */
    static String shownRequest(long time) {
        return "SKIP-NOTICE-SHOWN\n" + time + "\n";
    }
}
