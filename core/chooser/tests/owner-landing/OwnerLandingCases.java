package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/** NWP-20261129-12: OwnerLanding executed, and its eight sites in ChooserActivity read from the source.
 *  The source reader removes comments and counts braces outside string and char literals. Every pin compares
 *  comment-stripped code, so a guard that is commented out counts as absent. Exit 1 when any case fails. */
public final class OwnerLandingCases {
    private static final String OWN = "final boolean owned = ownerSessionPass != null;";
    private static final String GUARD = "if (!OwnerLanding.lands(owned, ownerSessionPass != null)) return;";
    private static final String BUILDER = "new android.app.AlertDialog.Builder(";
    private static final String THREAD = "new Thread(";
    private static final String LAMBDA = "runOnUiThread(() -> {";

    private static final String INBOX = "private View buildOwnerInboxScreen()";
    private static final String ITEM = "private View buildOwnerInboxItemScreen(";
    private static final String REPAIR = "private void confirmRepairBindings(TextView status)";
    private static final String BIND = "private View buildBindSimScreen(final SimInfo sim0)";
    private static final String STORE = "private View buildStoreScreen()";
    private static final String REPORT = "private View buildReportScreen()";
    private static final String REPORT_ANSWER = "private void renderGateReportResult(";

    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) {
            System.out.println("  ok    " + name);
        } else {
            failed++;
            System.out.println("  FAIL  " + name);
        }
    }

    private interface Pin { boolean holds(); }

    /** A pin whose anchor is gone fails. It does not pass and it does not stop the other pins. */
    private static void pin(String name, Pin p) {
        boolean ok;
        try {
            ok = p.holds();
        } catch (IllegalStateException e) {
            System.out.println("        " + e.getMessage());
            ok = false;
        }
        check(name, ok);
    }

    /** The end of the string or char literal that opens at i, past its closing quote. */
    private static int literalEnd(String s, int i) {
        char q = s.charAt(i);
        for (int j = i + 1; j < s.length(); j++) {
            char c = s.charAt(j);
            if (c == '\\') j++;
            else if (c == q) return j + 1;
        }
        return s.length();
    }

    /** src with its // and block comments removed. Literals stay as they are. */
    static String code(String src) {
        StringBuilder out = new StringBuilder(src.length());
        int i = 0;
        while (i < src.length()) {
            char c = src.charAt(i);
            if (c == '"' || c == '\'') {
                int e = literalEnd(src, i);
                out.append(src, i, e);
                i = e;
            } else if (src.startsWith("//", i)) {
                int e = src.indexOf('\n', i);
                i = e < 0 ? src.length() : e;
            } else if (src.startsWith("/*", i)) {
                int e = src.indexOf("*/", i + 2);
                i = e < 0 ? src.length() : e + 2;
            } else {
                out.append(c);
                i++;
            }
        }
        return out.toString();
    }

    private static int count(String text, String what) {
        int n = 0;
        for (int i = text.indexOf(what); i >= 0; i = text.indexOf(what, i + what.length())) n++;
        return n;
    }

    /** head, which occurs exactly once in text, through the } that closes its first {. */
    static String blockAt(String text, String head) {
        if (count(text, head) != 1) throw new IllegalStateException(count(text, head) + " x: " + head);
        int start = text.indexOf(head);
        int i = text.indexOf('{', start);
        if (i < 0) throw new IllegalStateException("no block: " + head);
        int depth = 0;
        while (i < text.length()) {
            char c = text.charAt(i);
            if (c == '"' || c == '\'') {
                i = literalEnd(text, i);
                continue;
            }
            if (c == '{') depth++;
            if (c == '}' && --depth == 0) return text.substring(start, i + 1);
            i++;
        }
        throw new IllegalStateException("unbalanced: " + head);
    }

    /** The text after the one occurrence of after, with its leading whitespace removed. */
    static String first(String text, String after) {
        if (count(text, after) != 1) throw new IllegalStateException(count(text, after) + " x: " + after);
        return text.substring(text.indexOf(after) + after.length()).stripLeading();
    }

    /** The UI lambda that follows the one occurrence of anchor starts with the guard. */
    private static boolean landingGuarded(String method, String anchor) {
        String rest = first(method, anchor);
        int at = rest.indexOf(LAMBDA);
        if (at < 0) throw new IllegalStateException("no " + LAMBDA + " after " + anchor);
        return rest.substring(at + LAMBDA.length()).stripLeading().startsWith(GUARD);
    }

    /** The span holds OWN once, and OWN comes before the first of each named text. A named text that is gone fails. */
    private static boolean ownBefore(String span, String... later) {
        if (count(span, OWN) != 1) throw new IllegalStateException(count(span, OWN) + " x " + OWN);
        for (String s : later) {
            int at = span.indexOf(s);
            if (at < 0) throw new IllegalStateException("no " + s);
            if (span.indexOf(OWN) > at) return false;
        }
        return true;
    }

    public static void main(String[] args) throws Exception {
        String src = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);
        String c = code(src);

        System.out.println("== OwnerLanding.lands ==");
        check("lands(false, false): first run's Store step, as today", OwnerLanding.lands(false, false));
        check("lands(false, true) is true", OwnerLanding.lands(false, true));
        check("lands(true, true): the normal owner action", OwnerLanding.lands(true, true));
        check("lands(true, false) is false: owner mode ended, the defect", !OwnerLanding.lands(true, false));

        System.out.println("== P1: each landing lambda starts with the guard ==");
        pin("P1 Clear all", () -> landingGuarded(blockAt(c, INBOX), "daemonCmd(\"CLEAR-OWNER-INBOX\");"));
        pin("P1 Delete", () -> landingGuarded(blockAt(c, ITEM), "daemonCmd(\"DELETE-OWNER-ITEM\\n\" + id);"));
        pin("P1 Repair", () -> landingGuarded(blockAt(c, REPAIR), "sendDaemon(\"REPAIR-BINDINGS\\n\");"));
        pin("P1 Unbind", () -> landingGuarded(blockAt(c, BIND), "sendDaemon(\"DELETE-BINDING\\n\""));
        pin("P1 Mark-mine", () -> landingGuarded(blockAt(c, BIND), "sendDaemon(\"SET-SIM-MINE\\n\""));
        pin("P1 Save", () -> landingGuarded(blockAt(c, STORE), "sendDaemon(\"SET-STORE\\n\""));

        System.out.println("== P2: each dialog's positive button starts with the guard ==");
        pin("P2 Repair", () -> first(blockAt(c, REPAIR), ".setPositiveButton(\"Repair\", (d, w) -> {").startsWith(GUARD));
        pin("P2 Unbind", () -> first(blockAt(c, BIND), ".setPositiveButton(\"Unbind\", (d, w) -> {").startsWith(GUARD));

        System.out.println("== P3: owned is read once, on the UI thread, before the worker and the dialog ==");
        pin("P3 Clear all", () -> ownBefore(blockAt(blockAt(c, INBOX), "clear.setOnClickListener(v -> {"), THREAD));
        pin("P3 Delete", () -> ownBefore(blockAt(blockAt(c, ITEM), "del.setOnClickListener(v -> {"), THREAD));
        pin("P3 Repair", () -> ownBefore(blockAt(c, REPAIR), BUILDER, THREAD));
        pin("P3 Unbind", () -> ownBefore(blockAt(blockAt(c, BIND),
                "settingsRow(\"Unbind all\", \"Remove every profile from this line\", v -> {"), BUILDER, THREAD));
        pin("P3 Mark-mine", () -> ownBefore(blockAt(blockAt(c, BIND), "BindingMarks.MARK_SUMMARY, v -> {"), THREAD));
        pin("P3 Save", () -> ownBefore(blockAt(blockAt(c, STORE), "save.setOnClickListener(v -> {"), THREAD));
        check("P3 the file holds six reads", count(c, OWN) == 6);

        System.out.println("== P4: the eight sites and no others ==");
        check("P4 OwnerLanding.lands( occurs eight times", count(c, "OwnerLanding.lands(") == 8);

        System.out.println("== P5 (control): buildReportScreen keeps its own guards ==");
        pin("P5 buildReportScreen's callback returns when the screen is gone",
                () -> count(blockAt(c, REPORT), "if (!root.isAttachedToWindow()) return;") >= 1);
        pin("P5 renderGateReportResult returns twice when the screen is gone",
                () -> count(blockAt(c, REPORT_ANSWER), "if (!root.isAttachedToWindow()) return;") >= 2);
        pin("P5 renderGateReportResult's dialog button checks the screen at the click",
                () -> count(blockAt(c, REPORT_ANSWER), "if (root.isAttachedToWindow()) setContentView(buildReportScreen());") == 1);

        System.out.println(failed == 0 ? "every case passed" : failed + " case(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
