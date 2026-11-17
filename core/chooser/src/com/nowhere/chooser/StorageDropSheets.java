package com.nowhere.chooser;

import java.util.Arrays;

/**
 * NWP-20261205-15: the Storage screen's confirmations as PopupSheet models (docs/backlog.md, "Popups are plain dialogs:
 * the choice pickers and the confirmations move to one bottom-sheet design", design A, slice 3). Stop keeping and Stop
 * carrying are warnings: the change LOOKS destructive and is not, so the green button keeps the app and the red-outlined
 * one stops. The over-plan notice is routine: its green button opens the storage breakdown. The context and the lines
 * are today's AlertDialog messages, split; the tones and the two "Keep ..." buttons are drafts for Chester's mockup.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-storage-drop-sheets-java.sh).
 */
final class StorageDropSheets {
    private StorageDropSheets() {}

    // DRAFT (NWP-20261205-15): mockup for Chester
    static final String STOP_KEEPING_TITLE = "Stop keeping ";
    static final String STOP_KEEPING_CONTEXT = "It stays on this phone and keeps working until you log off.";
    static final String STOP_KEEPING_LINE_1 = "It just won't come back on your next phone.";
    static final String STOP_KEEPING_LINE_2 = "Its data stops being carried when you log off — what your plan counts "
            + "then takes a few days to drop, because recent backups are kept for a while.";
    static final String KEEP_IT = "Keep it";
    static final String STOP_KEEPING_IT = "Stop keeping it";
    static final String STOP_CARRYING_TITLE = "Stop carrying ";
    static final String STOP_CARRYING_CONTEXT = "This app is not on your phone any more, but your profile is still "
            + "carrying its data — and still counting it against your plan.";
    static final String STOP_CARRYING_LINE_1 = "Stopping means the data is not kept when you log off.";
    static final String STOP_CARRYING_LINE_2 = "What your plan counts takes a few days to drop, because recent backups "
            + "are kept for a while.";
    static final String KEEP_CARRYING_IT = "Keep carrying it";
    static final String STOP_CARRYING_IT = "Stop carrying it";
    static final String OVER_PLAN_TITLE = "Not enough storage for ";
    static final String OVER_PLAN_CONTEXT_START = "Keeping ";
    static final String OVER_PLAN_CONTEXT_END = " would put your account over the storage your plan covers.";
    static final String OVER_PLAN_LINE = "Free up space or add storage, then try again.";
    static final String SEE_SPACE = "See what's using space";
    static final String QUESTION = "?";

    /** Amber: the app's data stops roaming at logoff. Slot 0 keeps the app, slot 1 stops keeping it. */
    static PopupSheet.Confirm stopKeeping(String label) {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, STOP_KEEPING_TITLE + label + QUESTION,
                STOP_KEEPING_CONTEXT,
                Arrays.asList(
                        new PopupSheet.Line(STOP_KEEPING_LINE_1, null),
                        new PopupSheet.Line(STOP_KEEPING_LINE_2, null)),
                Arrays.asList(
                        new PopupSheet.Button(KEEP_IT, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(STOP_KEEPING_IT, PopupSheet.Style.RED_OUTLINED)));
    }

    /** Amber, for an app that is gone but whose data the profile still carries. Slot 0 keeps carrying, slot 1 stops. */
    static PopupSheet.Confirm stopCarrying(String label) {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, STOP_CARRYING_TITLE + label + QUESTION,
                STOP_CARRYING_CONTEXT,
                Arrays.asList(
                        new PopupSheet.Line(STOP_CARRYING_LINE_1, null),
                        new PopupSheet.Line(STOP_CARRYING_LINE_2, null)),
                Arrays.asList(
                        new PopupSheet.Button(KEEP_CARRYING_IT, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(STOP_CARRYING_IT, PopupSheet.Style.RED_OUTLINED)));
    }

    /** Routine: slot 0 opens the storage breakdown, slot 1 only closes the sheet. */
    static PopupSheet.Confirm overPlan(String name) {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, OVER_PLAN_TITLE + name,
                OVER_PLAN_CONTEXT_START + name + OVER_PLAN_CONTEXT_END,
                Arrays.asList(new PopupSheet.Line(OVER_PLAN_LINE, null)),
                Arrays.asList(
                        new PopupSheet.Button(SEE_SPACE, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }
}
