package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;

/**
 * NWP-20261206-17: three of the gate's plain dialogs as PopupSheet models (docs/backlog.md, "Popups are plain dialogs:
 * the choice pickers and the confirmations move to one bottom-sheet design", slice 3): owner mode's Repair SIM bindings
 * ask, the OTA notes and the lost-credit notice. This class has no word of its own: the words are BindingsRepair's, the
 * caller's, or PopupSheet's NOT_NOW and GOT_IT.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-gate-notice-sheets-java.sh).
 */
final class GateNoticeSheets {
    private GateNoticeSheets() {}

    /** Routine: "Repair" is the green button (slot 0), "Not now" outlined (slot 1) changes nothing. */
    static PopupSheet.Confirm repairBindings() {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, BindingsRepair.TITLE, BindingsRepair.CONFIRM_CONTEXT,
                Collections.singletonList(new PopupSheet.Line(BindingsRepair.CONFIRM_AFTER, null)),
                Arrays.asList(new PopupSheet.Button("Repair", PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** OtaNotes.render's title and body, plain information. */
    static PopupSheet.Confirm otaNotes(String title, String body) {
        return gotIt(title, body);
    }

    /** The recorded lost-credit notice, plain information; the caller holds it until "Got it" is tapped. */
    static PopupSheet.Confirm creditLost(String title, String text) {
        return gotIt(title, text);
    }

    private static PopupSheet.Confirm gotIt(String title, String context) {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, title, context, Collections.emptyList(),
                Collections.singletonList(new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED)));
    }
}
