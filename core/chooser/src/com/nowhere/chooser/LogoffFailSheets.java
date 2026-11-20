package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261208-22: a failed sign-out's choice and its two second steps as PopupSheet models (docs/backlog.md, "Popups
 * are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 3).
 * ProfileActivity.showLogoffFailedDialog shows failed() for the exit failedDialogExit chose; confirmEndUnsaved shows
 * endConfirm() and confirmRestartUnsaved restartConfirm(). All three are held sheets (SheetDialog.confirmHeld): only a
 * button closes them, as NWP-20261010-10's dialogs stayed until they were answered. The titles, the messages and the
 * button labels are the dialogs' words, unchanged; "OK" is PopupSheet.GOT_IT and "Report this" is a link line, so it
 * no longer takes a button. acts() gives the meaning of each button, in button order, so the caller maps its actions
 * from the same table that orders the labels.
 *
 * DRAFT (NWP-20261208-22): mockup for Chester. The tones and the button order and styles await his approval.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-logoff-fail-sheets-java.sh).
 */
final class LogoffFailSheets {
    private LogoffFailSheets() {}

    /** What a button does. STAY and GOT_IT only close the sheet. */
    enum Act { STAY, END_UNSAVED, RESTART_UNSAVED, USE_KEY, LOCK, GOT_IT, BACK, END_CONFIRMED, RESTART_CONFIRMED }

    static final String TITLE_CANT_SAVE = "Can't save this session";
    static final String TITLE_STILL_IN = "You're still signed in";
    static final String L_STAY = "Stay signed in";
    static final String L_END_UNSAVED = "End session without saving";
    static final String L_RESTART_UNSAVED = "Restart without saving";
    static final String L_USE_KEY = "Use your security key";
    static final String L_LOCK = "Lock";
    static final String REPORT_THIS = "Report this";
    static final String REPORT_KEY = "report";
    static final String END_CONFIRM_TITLE = "End this session without saving?";
    static final String L_END_CONFIRMED = "End without saving";
    static final String RESTART_CONFIRM_TITLE = "Restart without saving?";
    static final String L_BACK = "Back";

    // DRAFT (NWP-20261208-22): mockup for Chester
    static final PopupSheet.Tone FAILED_TONE = PopupSheet.Tone.WARNING;
    // DRAFT (NWP-20261208-22): mockup for Chester
    static final PopupSheet.Tone LOCK_TONE = PopupSheet.Tone.ROUTINE;
    // DRAFT (NWP-20261208-22): mockup for Chester
    static final PopupSheet.Tone CONFIRM_TONE = PopupSheet.Tone.WARNING;

    /** endConfirm's buttons' meanings, in button order. */
    static final List<Act> END_CONFIRM_ACTS = Collections.unmodifiableList(Arrays.asList(Act.BACK, Act.END_CONFIRMED));
    /** restartConfirm's buttons' meanings, in button order. */
    static final List<Act> RESTART_CONFIRM_ACTS =
            Collections.unmodifiableList(Arrays.asList(Act.BACK, Act.RESTART_CONFIRMED));

    /** One exit's tone, title, buttons and their meanings, and whether it may carry "Report this". */
    private static final class Exit {
        final PopupSheet.Tone tone;
        final String title;
        final List<PopupSheet.Button> buttons = new ArrayList<>();
        final List<Act> acts = new ArrayList<>();
        final boolean report;

        Exit(PopupSheet.Tone tone, String title, boolean report) {
            this.tone = tone;
            this.title = title;
            this.report = report;
        }

        Exit add(String label, PopupSheet.Style style, Act act) {
            buttons.add(new PopupSheet.Button(label, style));
            acts.add(act);
            return this;
        }
    }

    /** The one table of the exits: failed() and acts() both read it, so a label and its meaning cannot drift apart.
     *  A null or unknown exit is "". */
    private static Exit exit(String exit, boolean reportable) {
        String x = exit == null ? "" : exit;
        switch (x) {
            case "RESTART":
                return new Exit(FAILED_TONE, TITLE_CANT_SAVE, true)
                        .add(L_STAY, PopupSheet.Style.GREEN_FILLED, Act.STAY)
                        .add(L_RESTART_UNSAVED, PopupSheet.Style.RED_OUTLINED, Act.RESTART_UNSAVED);
            case "END":
                return new Exit(FAILED_TONE, TITLE_CANT_SAVE, true)
                        .add(L_STAY, PopupSheet.Style.GREEN_FILLED, Act.STAY)
                        .add(L_END_UNSAVED, PopupSheet.Style.RED_OUTLINED, Act.END_UNSAVED);
            case "KEY-END":
                // Q016 (NWP-20261111-07): the key exit first; as before, no "Report this".
                return new Exit(FAILED_TONE, TITLE_CANT_SAVE, false)
                        .add(L_USE_KEY, PopupSheet.Style.GREEN_FILLED, Act.USE_KEY)
                        .add(L_END_UNSAVED, PopupSheet.Style.RED_OUTLINED, Act.END_UNSAVED)
                        .add(L_STAY, PopupSheet.Style.OUTLINED, Act.STAY);
            case "LOCK":
                // Q070: no network. Lock needs none and loses nothing until the 12-hour wipe, so it comes first.
                return new Exit(LOCK_TONE, TITLE_STILL_IN, false)
                        .add(L_LOCK, PopupSheet.Style.GREEN_FILLED, Act.LOCK)
                        .add(L_STAY, PopupSheet.Style.OUTLINED, Act.STAY);
            case "LOCK-END":
                return new Exit(FAILED_TONE, TITLE_STILL_IN, false)
                        .add(L_LOCK, PopupSheet.Style.GREEN_FILLED, Act.LOCK)
                        .add(L_END_UNSAVED, PopupSheet.Style.RED_OUTLINED, Act.END_UNSAVED)
                        .add(L_STAY, PopupSheet.Style.OUTLINED, Act.STAY);
            default:
                // No exit: the warning notice, one green "Got it".
                return new Exit(FAILED_TONE, TITLE_STILL_IN, reportable)
                        .add(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED, Act.GOT_IT);
        }
    }

    /** The failed sign-out's sheet for failedDialogExit's exit. msg is the context, unchanged. "Report this" is a link
     *  line (key REPORT_KEY) on RESTART and END, and on "" only when reportable. */
    static PopupSheet.Confirm failed(String exit, String msg, boolean reportable) {
        Exit e = exit(exit, reportable);
        List<PopupSheet.Line> lines = e.report
                ? Collections.singletonList(new PopupSheet.Line(REPORT_THIS, REPORT_KEY))
                : Collections.<PopupSheet.Line>emptyList();
        return new PopupSheet.Confirm(e.tone, e.title, msg, lines, e.buttons);
    }

    /** The meaning of each of failed(exit, ...)'s buttons, in button order. */
    static List<Act> acts(String exit) {
        return Collections.unmodifiableList(exit(exit, false).acts);
    }

    /** confirmEndUnsaved's second step; text is what is lost and kept. Buttons as END_CONFIRM_ACTS. */
    static PopupSheet.Confirm endConfirm(String text) {
        return new PopupSheet.Confirm(CONFIRM_TONE, END_CONFIRM_TITLE, text, null,
                Arrays.asList(new PopupSheet.Button(L_BACK, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(L_END_CONFIRMED, PopupSheet.Style.RED_OUTLINED)));
    }

    /** confirmRestartUnsaved's second step; text is what is lost and kept. Buttons as RESTART_CONFIRM_ACTS. */
    static PopupSheet.Confirm restartConfirm(String text) {
        return new PopupSheet.Confirm(CONFIRM_TONE, RESTART_CONFIRM_TITLE, text, null,
                Arrays.asList(new PopupSheet.Button(L_BACK, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(L_RESTART_UNSAVED, PopupSheet.Style.RED_OUTLINED)));
    }
}
