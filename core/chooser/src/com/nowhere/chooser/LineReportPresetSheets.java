package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;

/**
 * NWP-20261208-21: the last three small asks as PopupSheet models (docs/backlog.md, "Popups are plain dialogs: the
 * choice pickers and the confirmations move to one bottom-sheet design", slice 3): the gate's Unbind this line?, the
 * gate's Send report? and Profile's presetGuard replace ask. A model's button index is the index of its action in the
 * caller's Runnable[] (SheetDialog.confirm).
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-line-report-preset-sheets-java.sh).
 */
final class LineReportPresetSheets {
    private LineReportPresetSheets() {}

    // The gate's Unbind all ask (ChooserActivity.buildBindSimScreen): today's title, message and button.
    static final String UNBIND_TITLE = "Unbind this line?";
    static final String UNBIND_CONTEXT = "Every profile is removed from this SIM, and any texts or calls for it that "
            + "have not reached a profile yet are deleted.";
    static final String UNBIND = "Unbind";
    // DRAFT (NWP-20261208-21): mockup for Chester
    static final String KEEP_BINDINGS = "Keep the bindings";

    // The gate's Send report ask (ChooserActivity.buildReportScreen): today's title and button, and today's message
    // split in two. Its "Continue?" goes: the sheet's buttons ask it.
    static final String SEND_TITLE = "Send report?";
    static final String SEND_CONTEXT = "Scrubbed device diagnostics will be sent to support.";
    static final String SEND_LINE = "Nothing identifies you.";
    static final String SEND = "Send";

    // DRAFT (NWP-20261208-21): mockup for Chester
    static final String REPLACE_TITLE = "Replace your saved Custom?";

    /** Red: slot 0 (red filled "Unbind") runs the unbind; slot 1 (outlined "Keep the bindings") only closes the sheet. */
    static PopupSheet.Confirm unbindLine() {
        return new PopupSheet.Confirm(PopupSheet.Tone.DESTRUCTIVE, UNBIND_TITLE, UNBIND_CONTEXT, Collections.emptyList(),
                Arrays.asList(new PopupSheet.Button(UNBIND, PopupSheet.Style.RED_FILLED),
                        new PopupSheet.Button(KEEP_BINDINGS, PopupSheet.Style.OUTLINED)));
    }

    /** Routine: slot 0 (green "Send") sends the report; slot 1 (outlined "Not now") only closes the sheet. */
    static PopupSheet.Confirm gateSendReport() {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, SEND_TITLE, SEND_CONTEXT,
                Collections.singletonList(new PopupSheet.Line(SEND_LINE, null)),
                Arrays.asList(new PopupSheet.Button(SEND, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** Amber: slot 0 (green "Not now") writes nothing and runs the caller's onCancel; slot 1 (red outlined "Replace")
     *  writes the change and replaces the saved Custom. The context is PresetPicker.replaceMessage(). */
    static PopupSheet.Confirm replaceCustom() {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, REPLACE_TITLE, PresetPicker.replaceMessage(),
                Collections.emptyList(),
                Arrays.asList(new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PresetPicker.REPLACE, PopupSheet.Style.RED_OUTLINED)));
    }
}
