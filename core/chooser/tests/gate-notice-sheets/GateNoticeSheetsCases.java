package com.nowhere.chooser;

import java.util.Locale;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-17: the gate's three notice sheets (GateNoticeSheets). Each failure line names its case. */
final class GateNoticeSheetsCases {
    private static int failed;

    /** Today's text of the Repair SIM bindings ask, the plain dialog's message before the sheet. */
    private static final String CONFIRM_TODAY = "Repair keeps every SIM binding this phone can still read and drops the "
            + "damaged ones. Afterwards, a SIM with no binding is not this phone's own line until you mark it so, and its "
            + "texts and calls can't be kept until it is bound or marked.";

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static boolean button(Confirm c, int i, String label, Style style) {
        if (c.buttons.size() <= i) return false;
        Button b = c.buttons.get(i);
        return b != null && label.equals(b.label) && b.style == style;
    }

    /** A routine sheet with that title and context, no lines, and one green "Got it". */
    private static boolean gotIt(Confirm c, String title, String context) {
        return c != null && c.tone == Tone.ROUTINE && title.equals(c.title) && context.equals(c.context)
                && c.lines.isEmpty() && c.buttons.size() == 1 && button(c, 0, "Got it", Style.GREEN_FILLED);
    }

    private static boolean noOkCancel(Confirm c) {
        for (Button b : c.buttons) {
            String l = b == null || b.label == null ? "" : b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) return false;
        }
        return true;
    }

    public static void main(String[] args) {
        Confirm r = GateNoticeSheets.repairBindings();
        check("C1 repairBindings is routine", r.tone == Tone.ROUTINE);
        check("C1 repairBindings title", "Repair SIM bindings?".equals(r.title));
        check("C1 repairBindings context is CONFIRM_CONTEXT", BindingsRepair.CONFIRM_CONTEXT.equals(r.context));
        check("C1 repairBindings has one line, CONFIRM_AFTER, no link", r.lines.size() == 1
                && BindingsRepair.CONFIRM_AFTER.equals(r.lines.get(0).text) && r.lines.get(0).linkKey == null);
        check("C1 repairBindings has two buttons", r.buttons.size() == 2);
        check("C1 repairBindings button 0 is Repair, green", button(r, 0, "Repair", Style.GREEN_FILLED));
        check("C1 repairBindings button 1 is Not now, outlined", button(r, 1, "Not now", Style.OUTLINED));

        check("C2 CONFIRM_CONTEXT + \" \" + CONFIRM_AFTER is today's text",
                CONFIRM_TODAY.equals(BindingsRepair.CONFIRM_CONTEXT + " " + BindingsRepair.CONFIRM_AFTER));
        check("C2 CONFIRM is today's text", CONFIRM_TODAY.equals(BindingsRepair.CONFIRM));

        check("C3 otaNotes(T, B)", gotIt(GateNoticeSheets.otaNotes("T", "B"), "T", "B"));
        check("C3 otaNotes(X, Y)", gotIt(GateNoticeSheets.otaNotes("X", "Y"), "X", "Y"));
        check("C4 creditLost(T, B)", gotIt(GateNoticeSheets.creditLost("T", "B"), "T", "B"));
        check("C4 creditLost(X, Y)", gotIt(GateNoticeSheets.creditLost("X", "Y"), "X", "Y"));

        Confirm[] all = { r, GateNoticeSheets.otaNotes("T", "B"), GateNoticeSheets.creditLost("T", "B") };
        String[] names = { "repairBindings", "otaNotes", "creditLost" };
        for (int i = 0; i < all.length; i++) {
            check("C5 " + names[i] + " has no OK or Cancel button", noOkCancel(all[i]));
            check("C6 " + names[i] + " breaks no popup rule", PopupSheet.violations(all[i]).isEmpty());
        }

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: GateNoticeSheetsCases C1-C6");
    }
}
