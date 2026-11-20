package com.nowhere.chooser;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Progress;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-06: Report an issue's two sheets and Storage's Repair stored credit sheet. Each failure line names its
 *  case. The "today" literal is the Send report AlertDialog message less its "Continue?", so the split keeps today's
 *  words and adds none (docs/privacy-claims.md). NWP-20261208-28: the sending, failure and notice sheets; the literals
 *  below are the row's approved words and, for the failure sentences, ProfileActivity.renderReportResult's on main
 *  before this slice, so a changed word fails here. */
final class ReportRepairSheetsCases {
    private static int failed;

    private static final String TODAY_SEND = "Your device info and scrubbed diagnostics will be sent to support. This "
            + "can't be traced back to you.";

    private static int cases;

    private static void check(String name, boolean ok) {
        cases++;
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

    /** The retry sheet: amber, retry, the failed title, the sentence, the kept-note line, Try again then Not now. */
    private static void retrySheet(String name, String reply, String sentence) {
        Confirm f = ReportRepairSheets.failed(reply);
        check(name, f.tone == Tone.WARNING && f.retry && "Couldn't send the report".equals(f.title)
                && sentence.equals(f.context) && f.lines.size() == 1
                && line(f, 0, "Your note is kept, so you don't need to type it again.")
                && f.buttons.size() == 2 && button(f, 0, "Try again", Style.GREEN_FILLED)
                && button(f, 1, PopupSheet.NOT_NOW, Style.OUTLINED)
                && PopupSheet.violations(f).isEmpty() && ReportRepairSheets.retryable(reply));
    }

    /** The warning notice: amber, no retry, the failed title, the sentence, no line, one green Got it. */
    private static void notice(String name, String reply, String sentence) {
        Confirm f = ReportRepairSheets.failed(reply);
        check(name, f.tone == Tone.WARNING && !f.retry && "Couldn't send the report".equals(f.title)
                && sentence.equals(f.context) && f.lines.isEmpty()
                && f.buttons.size() == 1 && button(f, 0, PopupSheet.GOT_IT, Style.GREEN_FILLED)
                && PopupSheet.violations(f).isEmpty() && !ReportRepairSheets.retryable(reply));
    }

    private static final String NOGW = "Support reporting isn't available on this device.";
    private static final String DISABLED = "Support isn't accepting reports right now. Try again later.";
    private static final String TOOBIG = "The report was too large to send.";
    private static final String NET = "Couldn't reach support. Check your connection and try again.";

    private static void sending() {
        check("SENDING_TITLE", "Sending report…".equals(ReportRepairSheets.SENDING_TITLE));
        check("SENDING_CONTEXT", "Your device info and scrubbed diagnostics are on their way to support."
                .equals(ReportRepairSheets.SENDING_CONTEXT));
        check("SENDING_LINE", "This closes by itself when support answers.".equals(ReportRepairSheets.SENDING_LINE));
        check("FAILED_TITLE", "Couldn't send the report".equals(ReportRepairSheets.FAILED_TITLE));
        check("FAILED_LINE", "Your note is kept, so you don't need to type it again.".equals(ReportRepairSheets.FAILED_LINE));
        check("TRY_AGAIN", "Try again".equals(ReportRepairSheets.TRY_AGAIN));

        Progress p = ReportRepairSheets.sending();
        check("sending", ReportRepairSheets.SENDING_TITLE.equals(p.title) && ReportRepairSheets.SENDING_CONTEXT.equals(p.context)
                && ReportRepairSheets.SENDING_LINE.equals(p.line) && PopupSheet.violations(p).isEmpty());

        check("failureSentence ERR-NOGW", NOGW.equals(ReportRepairSheets.failureSentence("ERR-NOGW")));
        check("failureSentence ERR-DISABLED", DISABLED.equals(ReportRepairSheets.failureSentence("ERR-DISABLED")));
        check("failureSentence ERR-TOOBIG", TOOBIG.equals(ReportRepairSheets.failureSentence("ERR-TOOBIG")));
        check("failureSentence ERR-NET", NET.equals(ReportRepairSheets.failureSentence("ERR-NET")));
        check("failureSentence null", NET.equals(ReportRepairSheets.failureSentence(null)));
        check("failureSentence empty", NET.equals(ReportRepairSheets.failureSentence("")));
        check("failureSentence ERR-XYZ", "Couldn't send the report (ERR-XYZ).".equals(ReportRepairSheets.failureSentence("ERR-XYZ")));

        retrySheet("failed ERR-NET", "ERR-NET", NET);
        retrySheet("failed empty", "", NET);
        retrySheet("failed null", null, NET);
        retrySheet("failed ERR-XYZ", "ERR-XYZ", "Couldn't send the report (ERR-XYZ).");
        notice("failed ERR-NOGW", "ERR-NOGW", NOGW);
        notice("failed ERR-DISABLED", "ERR-DISABLED", DISABLED);
        notice("failed ERR-TOOBIG", "ERR-TOOBIG", TOOBIG);
    }

    public static void main(String[] args) {
        sending();

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
        System.out.println("ok: " + cases + " cases");
    }
}
