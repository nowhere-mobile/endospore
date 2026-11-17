package com.nowhere.chooser;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-06: Report an issue's two sheets and Storage's Repair stored credit sheet. Each failure line names its
 *  case. The "today" literal is the Send report AlertDialog message less its "Continue?", so the split keeps today's
 *  words and adds none (docs/privacy-claims.md). */
final class ReportRepairSheetsCases {
    private static int failed;

    private static final String TODAY_SEND = "Your device info and scrubbed diagnostics will be sent to support. This "
            + "can't be traced back to you.";

    private static void check(String name, boolean ok) {
        if (ok) {
            System.out.println("  ok    " + name);
            return;
        }
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static String message(Confirm c) {
        StringBuilder sb = new StringBuilder(c.context);
        for (Line l : c.lines) sb.append(' ').append(l.text);
        return sb.toString();
    }

    private static boolean line(Confirm c, int i, String text) {
        return c.lines.size() > i && text.equals(c.lines.get(i).text) && c.lines.get(i).linkKey == null;
    }

    private static boolean button(Confirm c, int i, String label, Style style) {
        return c.buttons.size() > i && label.equals(c.buttons.get(i).label) && c.buttons.get(i).style == style;
    }

    public static void main(String[] args) {
        Confirm send = ReportRepairSheets.sendReport();
        check("sendReport tone", send.tone == Tone.ROUTINE);
        check("sendReport title", "Send report?".equals(send.title));
        check("sendReport context", "Your device info and scrubbed diagnostics will be sent to support.".equals(send.context));
        check("sendReport line", send.lines.size() == 1 && line(send, 0, "This can't be traced back to you.")
                && TODAY_SEND.equals(message(send)));
        check("sendReport buttons", send.buttons.size() == 2 && button(send, 0, "Send", Style.GREEN_FILLED)
                && button(send, 1, PopupSheet.NOT_NOW, Style.OUTLINED));
        check("sendReport rules", PopupSheet.violations(send).isEmpty());

        Confirm sent = ReportRepairSheets.reportSent("T-1");
        check("reportSent tone", sent.tone == Tone.ROUTINE);
        check("reportSent title", "Report sent".equals(sent.title));
        check("reportSent context", sent.context.contains("T-1") && "Thanks. Your reference is T-1.".equals(sent.context));
        check("reportSent lines", sent.lines.size() == 2 && line(sent, 0, "Quote it if you follow up with support.")
                && line(sent, 1, "The report is anonymous."));
        check("reportSent buttons", sent.buttons.size() == 1 && button(sent, 0, PopupSheet.GOT_IT, Style.GREEN_FILLED));
        check("reportSent rules", PopupSheet.violations(sent).isEmpty());

        Confirm repair = ReportRepairSheets.repairCredit();
        check("repairCredit tone", repair.tone == Tone.WARNING);
        check("repairCredit title", WalletRepairCopy.TITLE.equals(repair.title));
        check("repairCredit buttons", repair.buttons.size() == 2
                && button(repair, 0, WalletRepairCopy.NEGATIVE, Style.GREEN_FILLED)
                && button(repair, 1, "Repair", Style.RED_OUTLINED)
                && WalletRepairCopy.POSITIVE.equals(repair.buttons.get(1).label));
        check("repairCredit message", repair.lines.size() == 2 && line(repair, 0, ReportRepairSheets.REPAIR_LINE_1)
                && line(repair, 1, ReportRepairSheets.REPAIR_LINE_2) && WalletRepairCopy.MESSAGE.equals(message(repair)));
        check("repairCredit rules", PopupSheet.violations(repair).isEmpty());
        check("NEGATIVE is Not now", PopupSheet.NOT_NOW.equals(WalletRepairCopy.NEGATIVE));

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: 18 cases");
    }
}
