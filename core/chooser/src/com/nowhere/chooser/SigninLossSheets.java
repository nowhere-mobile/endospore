package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * NWP-20261206-09: the gate's two sign-in loss screens as PopupSheet models (docs/backlog.md, "Popups are plain dialogs:
 * the choice pickers and the confirmations move to one bottom-sheet design", slice 3): the warning before a sign-in
 * ends a locked session (ChooserActivity.confirmSupersedeLoss) and "Couldn't load your data"
 * (ChooserActivity.offerSnapshotRecovery). Both are warnings: the green button is the safe way out and the risky
 * choice is red-outlined. The buttons are in action order.
 *
 * The warning's title, context and lines come from ChooserActivity (supersedeLossTitle, supersedeLossContext,
 * supersedeLossLines), where core/chooser/tests/supersede-credit checks them for the blind-login rules: true of a
 * stored session and a throwaway alike, so they are no existence oracle.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-signin-loss-sheets-java.sh).
 */
final class SigninLossSheets {
    private SigninLossSheets() {}

    // DRAFT (NWP-20261206-09): mockup for Chester
    static final PopupSheet.Tone SUPERSEDE_TONE = PopupSheet.Tone.WARNING;
    static final String SUPERSEDE_KEEP = "Keep that session";
    static final PopupSheet.Tone SNAPSHOT_TONE = PopupSheet.Tone.WARNING; // a rollback is final
    static final String SNAPSHOT_LINE_FIRST = "Try again first.";
    static final String SNAPSHOT_LINE_DAMAGED = "If it fails again, your most recent save may be damaged, and you can "
            + "restore your last good version instead.";

    static final String SUPERSEDE_CONTINUE = "Continue";
    static final String SNAPSHOT_TITLE = "Couldn't load your data";
    static final String SNAPSHOT_CONTEXT = "Your latest data didn't load.";
    static final String SNAPSHOT_RETRY = "Try again";
    static final String SNAPSHOT_RESTORE = "Restore last good version";

    /** The warning before a sign-in ends a locked session: Keep that session (green, the safe way out), then
     *  Continue (red-outlined). A null lines array gives no lines. */
    static PopupSheet.Confirm supersede(String title, String context, String[] lines) {
        List<PopupSheet.Line> out = new ArrayList<>();
        if (lines != null) for (String l : lines) if (l != null) out.add(new PopupSheet.Line(l, null));
        return new PopupSheet.Confirm(SUPERSEDE_TONE, title, context, out, Arrays.asList(
                new PopupSheet.Button(SUPERSEDE_KEEP, PopupSheet.Style.GREEN_FILLED),
                new PopupSheet.Button(SUPERSEDE_CONTINUE, PopupSheet.Style.RED_OUTLINED)));
    }

    /** "Couldn't load your data": Try again (green), Restore last good version (red-outlined), Not now (outlined). */
    static PopupSheet.Confirm snapshotOffer() {
        return new PopupSheet.Confirm(SNAPSHOT_TONE, SNAPSHOT_TITLE, SNAPSHOT_CONTEXT, Arrays.asList(
                new PopupSheet.Line(SNAPSHOT_LINE_FIRST, null), new PopupSheet.Line(SNAPSHOT_LINE_DAMAGED, null)),
                Arrays.asList(new PopupSheet.Button(SNAPSHOT_RETRY, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(SNAPSHOT_RESTORE, PopupSheet.Style.RED_OUTLINED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }
}
