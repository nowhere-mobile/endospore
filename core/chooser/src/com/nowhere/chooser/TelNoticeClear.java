package com.nowhere.chooser;

/**
 * NWP-20261110-22: the two parsers behind "Unbind all" and "Clear notices", lifted out of ChooserActivity so a javac
 * suite runs them. Pure, java.* only. Two producers feed them: SmsDeliverReceiver.postMessageNotice composes a gate
 * notice's title as {@code title + "  -  " + line}, and core/agent/main.go's DELETE-BINDING reply names the unbound
 * lines as {@code " L" + base64.StdEncoding(label)} (a bare {@code L} is a blank label). NWP-20261128-18: kindOf reads
 * the nowhere_kind and nowhere_call extras that postMessageNotice writes, and the title of a notice posted before them,
 * for the gate banner.
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

    /** NWP-20261128-18: the kind of event a gate notice stands for, as telNotices hands it to summarize: "call" (a
     *  missed call), "incoming" (a call answered at the gate) or "message". postMessageNotice marks a call with
     *  nowhere_call; a notice posted before that is read by its title, before the "  -  <label>" suffix only. */
    static String kindOf(String nowhereKind, String nowhereCall, String title) {
        String k = nowhereKind == null ? "" : nowhereKind, c = nowhereCall == null ? "" : nowhereCall;
        if (!k.isEmpty() && !"call".equals(k)) return "message";
        if ("call".equals(k) && "incoming".equals(c)) return "incoming";
        if ("call".equals(k) && "missed".equals(c)) return "call";
        String t = title == null ? "" : title;
        int i = t.indexOf("  -  ");
        String head = i >= 0 ? t.substring(0, i) : t;
        if (head.startsWith("Incoming call") || head.contains(" incoming calls")) return "incoming";
        if (head.startsWith("Missed call") || head.contains(" missed calls")) return "call";
        return "call".equals(k) ? "call" : "message";
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
