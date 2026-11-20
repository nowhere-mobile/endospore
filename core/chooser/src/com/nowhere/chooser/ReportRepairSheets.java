package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;

/**
 * NWP-20261206-06: Report an issue's two popups and Storage's Repair stored credit as PopupSheet models
 * (docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet
 * design", design A, slice 3). Send report and Report sent are routine: the green button sends, or closes the notice.
 * Repair stored credit is a warning: the green Not now is the safe way out and the red-outlined Repair runs the CONFIRM.
 * The context and the lines are today's AlertDialog messages, split; the tones and the arrangement are drafts for
 * Chester's mockup. Send report adds no word to today's: a new privacy claim needs counsel (docs/privacy-claims.md).
 * NWP-20261208-28: Send report changes in place to Sending report… (a Progress), then to Report sent, to the amber
 * Couldn't send the report with Try again (the note kept), or, when a retry cannot help, to the amber notice with Got it.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-report-repair-sheets-java.sh).
 */
final class ReportRepairSheets {
    private ReportRepairSheets() {}

    // DRAFT (NWP-20261206-06): mockup for Chester
    static final String SEND_TITLE = "Send report?";
    static final String SEND_CONTEXT = "Your device info and scrubbed diagnostics will be sent to support.";
    static final String SEND_LINE = "This can't be traced back to you.";
    static final String SEND = "Send";
    static final String SENT_TITLE = "Report sent";
    static final String SENT_CONTEXT_START = "Thanks. Your reference is ";
    static final String SENT_CONTEXT_END = ".";
    static final String SENT_LINE_1 = "Quote it if you follow up with support.";
    static final String SENT_LINE_2 = "The report is anonymous.";
    static final String REPAIR_CONTEXT = "The stored copy of this profile's credit is damaged and nobody can read it, "
            + "so the credit in it can't be recovered.";
    static final String REPAIR_LINE_1 = "Repairing gives that credit up, so credit you buy from now on is saved again.";
    static final String REPAIR_LINE_2 = "Credit this phone holds now is kept.";

    // NWP-20261116-48: the sending and failure words, design approved by Chester 2026-11-17 ("mock approved").
    static final String SENDING_TITLE = "Sending report…";
    static final String SENDING_CONTEXT = "Your device info and scrubbed diagnostics are on their way to support.";
    static final String SENDING_LINE = "This closes by itself when support answers.";
    static final String FAILED_TITLE = "Couldn't send the report";
    static final String FAILED_LINE = "Your note is kept, so you don't need to type it again.";
    static final String TRY_AGAIN = "Try again";

    /** The sheet while the report is on its way: no buttons. */
    static PopupSheet.Progress sending() {
        return new PopupSheet.Progress(SENDING_TITLE, SENDING_CONTEXT, SENDING_LINE);
    }

    /** The daemon's REPORT-ISSUE failure reply as one sentence (the words the status line showed before NWP-20261208-28). */
    static String failureSentence(String reply) {
        if ("ERR-NOGW".equals(reply))          return "Support reporting isn't available on this device.";
        if ("ERR-DISABLED".equals(reply))      return "Support isn't accepting reports right now. Try again later.";
        if ("ERR-TOOBIG".equals(reply))        return "The report was too large to send.";
        if ("ERR-NET".equals(reply) || reply == null || reply.isEmpty())
                                               return "Couldn't reach support. Check your connection and try again.";
        return "Couldn't send the report (" + reply + ").";
    }

    /** False only for a reply a second try cannot change: no gateway, reports turned off, a report too large. */
    static boolean retryable(String reply) {
        return !"ERR-NOGW".equals(reply) && !"ERR-DISABLED".equals(reply) && !"ERR-TOOBIG".equals(reply);
    }

    /** Amber. Retryable: slot 0 (green Try again) sends the same note again, slot 1 (outlined Not now) only closes the
     *  sheet. Otherwise the warning notice: slot 0 (green Got it) only closes it. */
    static PopupSheet.Confirm failed(String reply) {
        if (retryable(reply)) {
            return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, FAILED_TITLE, failureSentence(reply),
                    Arrays.asList(new PopupSheet.Line(FAILED_LINE, null)),
                    Arrays.asList(
                            new PopupSheet.Button(TRY_AGAIN, PopupSheet.Style.GREEN_FILLED),
                            new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)),
                    true);
        }
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, FAILED_TITLE, failureSentence(reply),
                Collections.<PopupSheet.Line>emptyList(),
                Arrays.asList(new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED)));
    }

    /** Routine: slot 0 sends the report, slot 1 only closes the sheet. */
    static PopupSheet.Confirm sendReport() {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, SEND_TITLE, SEND_CONTEXT,
                Arrays.asList(new PopupSheet.Line(SEND_LINE, null)),
                Arrays.asList(
                        new PopupSheet.Button(SEND, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** Routine notice with the reference the support gateway returned; slot 0 closes it. */
    static PopupSheet.Confirm reportSent(String ticket) {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, SENT_TITLE,
                SENT_CONTEXT_START + ticket + SENT_CONTEXT_END,
                Arrays.asList(
                        new PopupSheet.Line(SENT_LINE_1, null),
                        new PopupSheet.Line(SENT_LINE_2, null)),
                Arrays.asList(new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED)));
    }

    /** Amber: slot 0 (green Not now) only closes the sheet, slot 1 (red-outlined Repair) runs the repair. */
    static PopupSheet.Confirm repairCredit() {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, WalletRepairCopy.TITLE, REPAIR_CONTEXT,
                Arrays.asList(
                        new PopupSheet.Line(REPAIR_LINE_1, null),
                        new PopupSheet.Line(REPAIR_LINE_2, null)),
                Arrays.asList(
                        new PopupSheet.Button(WalletRepairCopy.NEGATIVE, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(WalletRepairCopy.POSITIVE, PopupSheet.Style.RED_OUTLINED)));
    }
}
