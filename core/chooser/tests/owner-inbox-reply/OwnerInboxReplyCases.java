package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;

/**
 * NWP-20261128-12: the owner inbox tells a failed read from an empty one. args: ChooserActivity.java,
 * telephony_owner.go. C* run OwnerInboxReply.of; W* read buildOwnerInboxScreen's wiring; X1 reads the daemon's reply.
 * Exit 1 when a case fails.
 */
public class OwnerInboxReplyCases {
    static final String CANCEL = "cancelTelNotices(java.util.Collections.singleton(SmsDeliverReceiver.UNBOUND_LINE))";
    static int fails = 0;

    static void ok(String name, boolean cond) {
        if (cond) System.out.println("  ok    " + name);
        else { fails++; System.out.println("  FAIL  " + name); }
    }

    /** From head to the brace that closes the first '{' after it; null when head is absent. */
    static String blockAt(String text, String head) {
        if (text == null) return null;
        int a = text.indexOf(head);
        if (a < 0) return null;
        int b = text.indexOf('{', a);
        if (b < 0) return null;
        int d = 0;
        for (int n = b; n < text.length(); n++) {
            char c = text.charAt(n);
            if (c == '{') d++;
            else if (c == '}' && --d == 0) return text.substring(a, n + 1);
        }
        return null;
    }

    /** From head to the first next after it (a switch arm has no braces); null when either is absent. */
    static String arm(String text, String head, String next) {
        if (text == null) return null;
        int a = text.indexOf(head);
        if (a < 0) return null;
        int b = text.indexOf(next, a + head.length());
        return b < 0 ? null : text.substring(a, b);
    }

    static int count(String text, String needle) {
        if (text == null) return -1;
        int k = 0;
        for (int i = text.indexOf(needle); i >= 0; i = text.indexOf(needle, i + needle.length())) k++;
        return k;
    }

    static boolean has(String text, String needle) { return text != null && text.contains(needle); }

    public static void main(String[] a) throws Exception {
        String ca = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        String go = new String(Files.readAllBytes(Paths.get(a[1])), StandardCharsets.UTF_8);

        ok("C1 null, nothing, ERR request, DENIED and NONEX are FAILED",
                OwnerInboxReply.of(null) == OwnerInboxReply.FAILED
                && OwnerInboxReply.of(Collections.<String>emptyList()) == OwnerInboxReply.FAILED
                && OwnerInboxReply.of(Arrays.asList("ERR request")) == OwnerInboxReply.FAILED
                && OwnerInboxReply.of(Arrays.asList("DENIED")) == OwnerInboxReply.FAILED
                && OwnerInboxReply.of(Arrays.asList("NONEX")) == OwnerInboxReply.FAILED);
        ok("C2 NONE and a bare OK are EMPTY",
                OwnerInboxReply.of(Arrays.asList("NONE")) == OwnerInboxReply.EMPTY
                && OwnerInboxReply.of(Arrays.asList("OK")) == OwnerInboxReply.EMPTY);
        ok("C3 OK and one row is ROWS",
                OwnerInboxReply.of(Arrays.asList("OK", "eyJpZCI6ImEifQ==")) == OwnerInboxReply.ROWS);
        ok("C4 the read-failure line differs from the empty line, and both have text",
                !OwnerInboxReply.FAILED_LINE.isEmpty() && !OwnerInboxReply.EMPTY_LINE.isEmpty()
                && !OwnerInboxReply.FAILED_LINE.equals(OwnerInboxReply.EMPTY_LINE));

        String m = blockAt(ca, "private View buildOwnerInboxScreen()");
        ok("W0 buildOwnerInboxScreen found", m != null);
        ok("W1 the list is read with roundTripLinesOrNull, never with roundTripLines(",
                has(m, "ownerInboxReq(\"GET-OWNER-INBOX\", \"\")")
                && has(m, "DaemonSocket.roundTripLinesOrNull(req, 30000)")
                && has(m, "OwnerInboxReply.of(lines)")
                && !has(m, "roundTripLines("));
        String failed = arm(m, "case OwnerInboxReply.FAILED:", "case OwnerInboxReply.EMPTY:");
        String empty = arm(m, "case OwnerInboxReply.EMPTY:", "default:");
        ok("W2 the FAILED arm shows the read-failure line and clears nothing",
                failed != null && has(failed, "OwnerInboxReply.FAILED_LINE")
                && !has(failed, "cancelTelNotices") && !has(failed, "EMPTY_LINE"));
        ok("W2 the EMPTY arm clears the unassigned-line notice once, off the UI thread, and shows the empty line",
                empty != null && count(empty, "new Thread(() -> " + CANCEL + ").start();") == 1
                && count(empty, "cancelTelNotices") == 1 && has(empty, "OwnerInboxReply.EMPTY_LINE"));
        String s0 = blockAt(m, "if (shown == 0) {");
        ok("W3 rows that all fail inboxDecode (shown == 0) show the read-failure line and clear nothing",
                s0 != null && has(s0, "OwnerInboxReply.FAILED_LINE") && !has(s0, "EMPTY_LINE")
                && !has(s0, "No messages on unassigned SIMs.") && !has(s0, "cancelTelNotices"));
        ok("W4 exactly three unassigned-line cancels (empty, open with rows, Clear all) and none for every line",
                count(m, "cancelTelNotices(") == 3 && count(m, CANCEL) == 3 && !has(m, "cancelTelNotices(null)"));

        String g = blockAt(go, "func serveOwnerInboxList(");
        String e = blockAt(g, "if len(lines) == 0 {");
        int eEnd = (g == null || e == null) ? -1 : g.indexOf(e) + e.length();
        ok("X1 the daemon answers an empty inbox NONE, never OK with no row (if that changes, OwnerInboxReply must too)",
                e != null && has(e, "fmt.Fprint(conn, \"NONE\\n\")") && !has(e, "\"OK\\n\"")
                && count(g, "fmt.Fprint(conn, \"OK\\n\")") == 1
                && g.indexOf("fmt.Fprint(conn, \"OK\\n\")") > eEnd);

        System.out.println(fails == 0 ? "all cases pass" : fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
