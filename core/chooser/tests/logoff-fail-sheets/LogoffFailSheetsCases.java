package com.nowhere.chooser;

import java.util.List;
import java.util.Locale;

/** NWP-20261208-22: the failed sign-out's sheets of LogoffFailSheets, run by test-logoff-fail-sheets-java.sh. The
 *  titles and the labels are literals here, not the constants, so a changed constant fails a case. */
public final class LogoffFailSheetsCases {
    private static boolean failed;

    private static void check(String name, boolean ok) {
        if (!ok) {
            System.out.println("  FAIL  " + name);
            failed = true;
        }
    }

    private static final PopupSheet.Style G = PopupSheet.Style.GREEN_FILLED;
    private static final PopupSheet.Style O = PopupSheet.Style.OUTLINED;
    private static final PopupSheet.Style R = PopupSheet.Style.RED_OUTLINED;
    private static final String STAY = "Stay signed in";
    private static final String END = "End session without saving";
    private static final String RESTART = "Restart without saving";

    /** One expected button: its label, style and meaning. */
    private static Object[] b(String label, PopupSheet.Style s, LogoffFailSheets.Act a) {
        return new Object[] {label, s, a};
    }

    /** f's model c against the expected tone, title, context, buttons (in order) and link line. acts is the button
     *  meanings the caller maps, null when the model has no acts() to check. */
    private static void sheet(String f, PopupSheet.Confirm c, List<LogoffFailSheets.Act> acts, PopupSheet.Tone tone,
            String title, String context, boolean report, Object[]... buttons) {
        check(f + " not null", c != null);
        if (c == null) return;
        check(f + " tone", c.tone == tone);
        check(f + " title", title.equals(c.title));
        check(f + " context", context.equals(c.context));
        if (report) {
            check(f + " link line", c.lines.size() == 1 && c.lines.get(0) != null
                    && "Report this".equals(c.lines.get(0).text) && "report".equals(c.lines.get(0).linkKey));
        } else {
            check(f + " no link line", c.lines.isEmpty());
        }
        check(f + " button count", c.buttons.size() == buttons.length);
        for (int i = 0; i < Math.min(buttons.length, c.buttons.size()); i++) {
            PopupSheet.Button x = c.buttons.get(i);
            check(f + " button " + i + " label", x != null && buttons[i][0].equals(x.label));
            check(f + " button " + i + " style", x != null && buttons[i][1] == x.style);
        }
        if (acts != null) {
            check(f + " acts parallel to buttons", acts.size() == c.buttons.size());
            for (int i = 0; i < Math.min(buttons.length, acts.size()); i++) {
                check(f + " act " + i, buttons[i][2] == acts.get(i));
            }
            for (int i = 0; i < Math.min(acts.size(), c.buttons.size()); i++) fixed(f, acts.get(i), c.buttons.get(i));
        }
        for (PopupSheet.Button x : c.buttons) {
            String l = x == null || x.label == null ? "" : x.label.trim().toLowerCase(Locale.ROOT);
            check(f + " no OK or Cancel", !l.equals("ok") && !l.equals("okay") && !l.equals("cancel"));
        }
        List<String> v = PopupSheet.violations(c);
        if (!v.isEmpty()) System.out.println("  violations of " + f + ": " + v);
        check(f + " violations", v.isEmpty());
    }

    /** Each meaning has one label and one style wherever it appears; STAY is green only where it is the way out. */
    private static void fixed(String f, LogoffFailSheets.Act a, PopupSheet.Button x) {
        if (x == null) return;
        switch (a) {
            case END_UNSAVED: check(f + " END_UNSAVED fixed", END.equals(x.label) && x.style == R); break;
            case RESTART_UNSAVED: check(f + " RESTART_UNSAVED fixed", RESTART.equals(x.label) && x.style == R); break;
            case USE_KEY: check(f + " USE_KEY fixed", "Use your security key".equals(x.label) && x.style == G); break;
            case LOCK: check(f + " LOCK fixed", "Lock".equals(x.label) && x.style == G); break;
            case GOT_IT: check(f + " GOT_IT fixed", "Got it".equals(x.label) && x.style == G); break;
            case STAY: check(f + " STAY fixed", STAY.equals(x.label) && (x.style == G || x.style == O)); break;
            case BACK: check(f + " BACK fixed", "Back".equals(x.label) && x.style == G); break;
            case END_CONFIRMED: check(f + " END_CONFIRMED fixed", "End without saving".equals(x.label) && x.style == R); break;
            case RESTART_CONFIRMED: check(f + " RESTART_CONFIRMED fixed", RESTART.equals(x.label) && x.style == R); break;
            default: check(f + " unknown act " + a, false);
        }
    }

    public static void main(String[] args) {
        PopupSheet.Tone W = PopupSheet.Tone.WARNING;
        String msg = "Your stored copy is intact.";
        for (boolean rep : new boolean[] {true, false}) {
            String r = " reportable=" + rep;
            sheet("RESTART" + r, LogoffFailSheets.failed("RESTART", msg, rep), LogoffFailSheets.acts("RESTART"),
                    W, "Can't save this session", msg, true,
                    b(STAY, G, LogoffFailSheets.Act.STAY), b(RESTART, R, LogoffFailSheets.Act.RESTART_UNSAVED));
            sheet("END" + r, LogoffFailSheets.failed("END", msg, rep), LogoffFailSheets.acts("END"),
                    W, "Can't save this session", msg, true,
                    b(STAY, G, LogoffFailSheets.Act.STAY), b(END, R, LogoffFailSheets.Act.END_UNSAVED));
            sheet("KEY-END" + r, LogoffFailSheets.failed("KEY-END", msg, rep), LogoffFailSheets.acts("KEY-END"),
                    W, "Can't save this session", msg, false,
                    b("Use your security key", G, LogoffFailSheets.Act.USE_KEY),
                    b(END, R, LogoffFailSheets.Act.END_UNSAVED), b(STAY, O, LogoffFailSheets.Act.STAY));
            sheet("LOCK" + r, LogoffFailSheets.failed("LOCK", msg, rep), LogoffFailSheets.acts("LOCK"),
                    PopupSheet.Tone.ROUTINE, "You're still signed in", msg, false,
                    b("Lock", G, LogoffFailSheets.Act.LOCK), b(STAY, O, LogoffFailSheets.Act.STAY));
            sheet("LOCK-END" + r, LogoffFailSheets.failed("LOCK-END", msg, rep), LogoffFailSheets.acts("LOCK-END"),
                    W, "You're still signed in", msg, false,
                    b("Lock", G, LogoffFailSheets.Act.LOCK), b(END, R, LogoffFailSheets.Act.END_UNSAVED),
                    b(STAY, O, LogoffFailSheets.Act.STAY));
            for (String x : new String[] {"", "BOGUS", null}) {
                sheet("'" + x + "'" + r, LogoffFailSheets.failed(x, msg, rep), LogoffFailSheets.acts(x),
                        W, "You're still signed in", msg, rep, b("Got it", G, LogoffFailSheets.Act.GOT_IT));
            }
        }
        String text = "This session's changes since 10:04 are lost.";
        sheet("endConfirm", LogoffFailSheets.endConfirm(text), LogoffFailSheets.END_CONFIRM_ACTS,
                W, "End this session without saving?", text, false,
                b("Back", G, LogoffFailSheets.Act.BACK), b("End without saving", R, LogoffFailSheets.Act.END_CONFIRMED));
        sheet("restartConfirm", LogoffFailSheets.restartConfirm(text), LogoffFailSheets.RESTART_CONFIRM_ACTS,
                W, "Restart without saving?", text, false,
                b("Back", G, LogoffFailSheets.Act.BACK), b(RESTART, R, LogoffFailSheets.Act.RESTART_CONFIRMED));
        check("acts() is read-only", readOnly(LogoffFailSheets.acts("END")));
        check("END_CONFIRM_ACTS is read-only", readOnly(LogoffFailSheets.END_CONFIRM_ACTS));
        check("RESTART_CONFIRM_ACTS is read-only", readOnly(LogoffFailSheets.RESTART_CONFIRM_ACTS));
        if (failed) System.exit(1);
        System.out.println("  ok: the six exits x reportable, the unknown exits, endConfirm, restartConfirm");
    }

    private static boolean readOnly(List<LogoffFailSheets.Act> l) {
        try {
            l.add(LogoffFailSheets.Act.STAY);
            return false;
        } catch (UnsupportedOperationException e) {
            return true;
        }
    }
}
