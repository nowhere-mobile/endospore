package com.nowhere.chooser;

/**
 * NWP-20261110-22: the two parsers behind "Unbind all" and "Clear notices", lifted out of ChooserActivity so a javac
 * suite runs them. Pure, java.* only. Two producers feed them: SmsDeliverReceiver.postMessageNotice composes a gate
 * notice's title as {@code title + "  -  " + line}, and core/agent/main.go's DELETE-BINDING reply names the unbound
 * lines as {@code " L" + base64.StdEncoding(label)} (a bare {@code L} is a blank label).
 */
final class TelNoticeClear {
    private TelNoticeClear() {}

    /** The SIM line label a gate notice is for: everything after the FIRST "  -  " of its title; "" for a null title
     *  or a bare one with no separator. */
    static String labelOf(CharSequence title) {
        if (title == null) return "";
        String s = title.toString();
        int i = s.indexOf("  -  ");
        return i >= 0 ? s.substring(i + 5) : "";
    }

    /**
     * The line labels a DELETE-BINDING OK reply names ("OK L<label_b64> ..."). Never null -- null would make
     * cancelTelNotices clear EVERY notice -- so a reply naming none clears none. The first token (the status) is never
     * decoded; a token that does not decode is skipped. java.util.Base64's basic decoder accepts what the agent writes
     * (StdEncoding, padded; the space split leaves no whitespace in a token), so this matches android.util.Base64.DEFAULT
     * on every reply the agent can send.
     */
    static java.util.Set<String> unboundLabels(String reply) {
        java.util.Set<String> out = new java.util.HashSet<>();
        String[] t = reply == null ? new String[0] : reply.trim().split(" ");
        for (int i = 1; i < t.length; i++) {
            if (!t[i].startsWith("L")) continue;
            try {
                out.add(new String(java.util.Base64.getDecoder().decode(t[i].substring(1)),
                        java.nio.charset.StandardCharsets.UTF_8));
            } catch (Throwable ignore) {}
        }
        return out;
    }
}
