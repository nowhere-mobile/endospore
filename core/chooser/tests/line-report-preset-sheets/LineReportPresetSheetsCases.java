package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;
import java.util.Locale;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261208-21: the gate's Unbind this line? and Send report? and Profile's replace ask (LineReportPresetSheets),
 *  and their three call sites read from the source (args: ChooserActivity.java, ProfileActivity.java). The source
 *  reader removes comments and counts braces outside string and char literals, so a commented-out line counts as
 *  absent. Each failure line names its case. Exit 1 when any case fails. */
final class LineReportPresetSheetsCases {
    /** Today's messages of the two gate dialogs, before the sheet. */
    private static final String UNBIND_TODAY = "Every profile is removed from this SIM, and any texts or calls for it that "
            + "have not reached a profile yet are deleted.";
    private static final String SEND_TODAY = "Scrubbed device diagnostics will be sent to support. Nothing identifies you. "
            + "Continue?";

    private static final String BIND = "private View buildBindSimScreen(final SimInfo sim0)";
    private static final String UNBIND_ROW = "settingsRow(\"Unbind all\", \"Remove every profile from this line\", v -> {";
    private static final String UNBIND_SHEET = "SheetDialog.confirm(this, LineReportPresetSheets.unbindLine(), new Runnable[] {";
    private static final String UNBIND_SLOT0 = "LineReportPresetSheets.unbindLine(), new Runnable[] { () -> {";
    private static final String GUARD = "if (!OwnerLanding.lands(owned, ownerSessionPass != null)) return;";
    private static final String REPORT = "private View buildReportScreen()";
    private static final String REPORT_ANSWER = "private void renderGateReportResult(";
    private static final String SEND_CLICK = "send.setOnClickListener(";
    private static final String SEND_SLOT0 = "LineReportPresetSheets.gateSendReport(), new Runnable[] { () -> {";
    private static final String BUILDER = "AlertDialog.Builder";
    private static final String GUARD_METHOD = "private void presetGuard(";
    private static final String REPLACE_SHEET = "SheetDialog.confirm(this, LineReportPresetSheets.replaceCustom(), new Runnable[] {";
    private static final String LAMBDA = "() -> {";
    private static final String ON_CANCEL = "if (onCancel != null) onCancel.run();";
    private static final String WRITE = "write.run();";
    private static final String SAVE = "if (SettingLanded.landed(change, presetCurrent())) presetSaveCustom(g.save);";
    private static final String CANCEL_LISTENER = "if (d != null) d.setOnCancelListener(x -> {";

    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private interface Pin { boolean holds(); }

    /** A pin whose anchor is gone fails. It does not pass and it does not stop the other pins. */
    private static void pin(String name, Pin p) {
        boolean ok;
        try {
            ok = p.holds();
        } catch (IllegalStateException e) {
            System.out.println("        " + name + ": " + e.getMessage());
            ok = false;
        }
        check(name, ok);
    }

    private static boolean button(Confirm c, int i, String label, Style style) {
        if (c.buttons.size() <= i) return false;
        Button b = c.buttons.get(i);
        return b != null && label.equals(b.label) && b.style == style;
    }

    private static boolean noOkCancel(Confirm c) {
        for (Button b : c.buttons) {
            String l = b == null || b.label == null ? "" : b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) return false;
        }
        return true;
    }

    // ---- the source reader (as tests/owner-landing/OwnerLandingCases.java) ----

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
    private static String code(String src) {
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

    private static int once(String text, String head) {
        if (count(text, head) != 1) throw new IllegalStateException(count(text, head) + " x: " + head);
        return text.indexOf(head);
    }

    /** From start through the bracket that closes the first opening bracket at or after open; with stopAtSemicolon,
     *  through the first ; met outside every bracket instead. */
    private static String span(String text, int start, int open, boolean stopAtSemicolon) {
        int depth = 0;
        for (int i = open; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '"' || c == '\'') {
                i = literalEnd(text, i) - 1;
                continue;
            }
            if (c == '{' || c == '(' || c == '[') depth++;
            if (c == '}' || c == ')' || c == ']') {
                depth--;
                if (!stopAtSemicolon && depth == 0) return text.substring(start, i + 1);
            }
            if (stopAtSemicolon && c == ';' && depth == 0) return text.substring(start, i + 1);
        }
        throw new IllegalStateException("unbalanced at " + start);
    }

    /** head, which occurs exactly once in text, through the } that closes its first {. */
    private static String blockAt(String text, String head) {
        int start = once(text, head);
        int open = text.indexOf('{', start);
        if (open < 0) throw new IllegalStateException("no block: " + head);
        return span(text, start, open, false);
    }

    /** head, which occurs exactly once in text, through the ; that ends its statement. */
    private static String statementAt(String text, String head) {
        int start = once(text, head);
        return span(text, start, start, true);
    }

    /** The lambda body whose "{" ends the one occurrence of head (head ends with "{"), braces included. */
    private static String lambdaAt(String text, String head) {
        int open = once(text, head) + head.length() - 1;
        return span(text, open, open, false);
    }

    /** The text after the one occurrence of head, with its leading whitespace removed. */
    private static String after(String text, String head) {
        return text.substring(once(text, head) + head.length()).stripLeading();
    }

    public static void main(String[] args) throws Exception {
        // ---- C: the three models ----
        Confirm u = LineReportPresetSheets.unbindLine();
        check("C1 unbindLine is destructive", u.tone == Tone.DESTRUCTIVE);
        check("C1 unbindLine title", "Unbind this line?".equals(u.title));
        check("C1 unbindLine context is today's message", UNBIND_TODAY.equals(u.context));
        check("C1 unbindLine has no line", u.lines.isEmpty());
        check("C1 unbindLine has two buttons", u.buttons.size() == 2);
        check("C1 unbindLine button 0 is Unbind, red filled", button(u, 0, "Unbind", Style.RED_FILLED));
        check("C1 unbindLine button 1 is Keep the bindings, outlined", button(u, 1, "Keep the bindings", Style.OUTLINED));

        Confirm s = LineReportPresetSheets.gateSendReport();
        check("C2 gateSendReport is routine", s.tone == Tone.ROUTINE);
        check("C2 gateSendReport title", "Send report?".equals(s.title));
        check("C2 gateSendReport context", "Scrubbed device diagnostics will be sent to support.".equals(s.context));
        check("C2 gateSendReport has one line, Nothing identifies you., no link", s.lines.size() == 1
                && "Nothing identifies you.".equals(s.lines.get(0).text) && s.lines.get(0).linkKey == null);
        check("C2 gateSendReport context + line is today's message less Continue?", s.lines.size() == 1
                && SEND_TODAY.equals(s.context + " " + s.lines.get(0).text + " Continue?"));
        check("C2 gateSendReport has two buttons", s.buttons.size() == 2);
        check("C2 gateSendReport button 0 is Send, green", button(s, 0, "Send", Style.GREEN_FILLED));
        check("C2 gateSendReport button 1 is Not now, outlined", button(s, 1, "Not now", Style.OUTLINED));

        Confirm r = LineReportPresetSheets.replaceCustom();
        check("C3 replaceCustom is a warning", r.tone == Tone.WARNING);
        check("C3 replaceCustom title", "Replace your saved Custom?".equals(r.title));
        check("C3 replaceCustom context is PresetPicker.replaceMessage()", PresetPicker.replaceMessage().equals(r.context)
                && "This replaces your saved Custom settings.".equals(r.context));
        check("C3 replaceCustom has no line", r.lines.isEmpty());
        check("C3 replaceCustom has two buttons", r.buttons.size() == 2);
        check("C3 replaceCustom button 0 is Not now, green", button(r, 0, "Not now", Style.GREEN_FILLED));
        check("C3 replaceCustom button 1 is Replace, red outlined", button(r, 1, "Replace", Style.RED_OUTLINED));

        Confirm[] all = { u, s, r };
        String[] names = { "unbindLine", "gateSendReport", "replaceCustom" };
        for (int i = 0; i < all.length; i++) {
            List<String> v = PopupSheet.violations(all[i]);
            check("C4 " + names[i] + " breaks no popup rule " + v, v.isEmpty());
            check("C5 " + names[i] + " has no OK or Cancel button", noOkCancel(all[i]));
        }

        // The decided words stay: the sheet uses Not now, REPLACE_ASK keeps its "Replace / Cancel." for Chester.
        check("C6 PresetPicker.CANCEL is Cancel", "Cancel".equals(PresetPicker.CANCEL));
        check("C6 REPLACE_ASK keeps Replace / Cancel.", ProfilePresets.REPLACE_ASK.endsWith(" Replace / Cancel."));

        // ---- Q: the three call sites ----
        String ca = code(new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8));
        String pa = code(new String(Files.readAllBytes(Paths.get(args[1])), StandardCharsets.UTF_8));

        pin("Q1 the Unbind row holds the unbindLine sheet and no AlertDialog.Builder", () -> {
            String row = blockAt(blockAt(ca, BIND), UNBIND_ROW);
            return !row.contains(BUILDER) && count(row, UNBIND_SHEET) == 1;
        });
        pin("Q1 the send click holds the gateSendReport sheet and no AlertDialog.Builder", () -> {
            String click = statementAt(blockAt(ca, REPORT), SEND_CLICK);
            return !click.contains(BUILDER) && count(click, "LineReportPresetSheets.gateSendReport()") == 1;
        });
        pin("Q1 (control) What's sent and renderGateReportResult keep their AlertDialog.Builder", () ->
                blockAt(ca, REPORT).contains(".setTitle(\"What's sent\")") && blockAt(ca, REPORT).contains(BUILDER)
                        && blockAt(ca, REPORT_ANSWER).contains(BUILDER));

        pin("Q2 Unbind's slot 0 starts with the guard, sends DELETE-BINDING, and slot 1 is null", () -> {
            String row = blockAt(blockAt(ca, BIND), UNBIND_ROW);
            String slot0 = lambdaAt(row, UNBIND_SLOT0);
            return after(row, UNBIND_SLOT0).startsWith(GUARD) && slot0.contains("sendDaemon(\"DELETE-BINDING\\n\"")
                    && after(row, slot0).startsWith(", null }, null);");
        });

        pin("Q3 Send report's slot 0 sends REPORT-ISSUE, and slot 1 is null", () -> {
            String click = statementAt(blockAt(ca, REPORT), SEND_CLICK);
            String slot0 = lambdaAt(click, SEND_SLOT0);
            return slot0.contains("sendDaemon(\"REPORT-ISSUE\\n\" + gateReportJson(noteText, false)")
                    && after(click, slot0).startsWith(", null }, null)");
        });

        pin("Q4 presetGuard's ASK arm: slot 0 and the cancel listener run onCancel, slot 1 writes and saves only when landed", () -> {
            String m = blockAt(pa, GUARD_METHOD);
            int a = once(m, "case ASK:");
            int b = m.indexOf("break;", a);
            if (b < 0) throw new IllegalStateException("no break; after case ASK:");
            String arm = m.substring(a, b);
            int sheet = once(arm, REPLACE_SHEET);
            String rest = arm.substring(sheet + REPLACE_SHEET.length()).stripLeading();
            if (!rest.startsWith(LAMBDA)) throw new IllegalStateException("slot 0 is not a lambda");
            String slot0 = span(rest, LAMBDA.length() - 1, LAMBDA.length() - 1, false);
            String tail = rest.substring(LAMBDA.length() + slot0.length() - 1).stripLeading();
            if (!tail.startsWith(",")) throw new IllegalStateException("no slot 1");
            tail = tail.substring(1).stripLeading();
            if (!tail.startsWith(LAMBDA)) throw new IllegalStateException("slot 1 is not a lambda");
            String slot1 = span(tail, LAMBDA.length() - 1, LAMBDA.length() - 1, false);
            String end = tail.substring(LAMBDA.length() + slot1.length() - 1).stripLeading();
            String listener = lambdaAt(arm, CANCEL_LISTENER);
            return !arm.contains(BUILDER)
                    && slot0.contains(ON_CANCEL) && !slot0.contains(WRITE) && !slot0.contains("presetSaveCustom(")
                    && !slot1.contains("onCancel") && count(slot1, WRITE) == 1 && count(slot1, SAVE) == 1
                    && count(slot1, "presetSaveCustom(") == 1 && slot1.indexOf(WRITE) < slot1.indexOf(SAVE)
                    && end.startsWith("}, null);")
                    && arm.indexOf(CANCEL_LISTENER) > sheet && listener.contains(ON_CANCEL);
        });

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: LineReportPresetSheetsCases C1-C6 + pins Q1-Q4");
    }
}
