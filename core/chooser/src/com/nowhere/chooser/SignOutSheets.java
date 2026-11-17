package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * NWP-20261206-10: the sign-out group's confirmations on the shared bottom sheet (docs/backlog.md, "Popups are plain
 * dialogs: the choice pickers and the confirmations move to one bottom-sheet design", design A, slice 3 part 1): the
 * update card's "Sign out and install?" and the held apps' "Release ...?". Both are routine sheets. ProfileActivity
 * draws them with SheetDialog.confirm.
 *
 * The install texts come from OtaUpdate (installContext, installLines), so the sheet and OtaUpdate.installConfirm
 * cannot drift apart. The release texts are the old dialog's three paragraphs, word for word.
 *
 * ⚠ The tones and the install button's word are DRAFTS for Chester; the PR and the commit carry the mockup.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-signout-sheets-java.sh).
 */
final class SignOutSheets {
    private SignOutSheets() {}

    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String INSTALL_TITLE = "Sign out and install?";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String INSTALL = "Sign out and install";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE = "Release";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String KEEP_HOLDING = "Keep holding";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String ONE = "it";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String ALL = "them";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_TITLE_HEAD = "Release ";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_TITLE_TAIL = "?";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_OPEN = "Your other device will be able to open ";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_KEPT = ". Nothing is deleted and ";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_WORKS = " keeps working here.";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_THEN = "If your other device then opens ";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_HELD = " becomes held THERE — and you won't be able to open ";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_UNTIL = " here until that device lets go.";
    // DRAFT (NWP-20261206-10): mockup for Chester
    static final String RELEASE_REACH = "Either way it takes a few minutes to reach your other device.";

    /** The update card's confirmation. {@code local} = a session that is not saved to the store, which a sign-out
     *  erases. Routine: "Sign out and install" is the green button, "Not now" is outlined. */
    static PopupSheet.Confirm install(boolean local) {
        List<PopupSheet.Line> lines = new ArrayList<>();
        for (String l : OtaUpdate.installLines()) lines.add(new PopupSheet.Line(l, null));
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, INSTALL_TITLE, OtaUpdate.installContext(local), lines,
                Arrays.asList(new PopupSheet.Button(INSTALL, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** The held apps' Release confirmation. {@code what} names the app or "N apps"; {@code all} = every held app.
     *  Routine (DRAFT: nothing is deleted): "Release" is the green button, "Keep holding" is outlined. */
    static PopupSheet.Confirm release(String what, boolean all) {
        final String it = all ? ALL : ONE;
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, RELEASE_TITLE_HEAD + what + RELEASE_TITLE_TAIL,
                RELEASE_OPEN + it + RELEASE_KEPT + what + RELEASE_WORKS,
                Arrays.asList(new PopupSheet.Line(RELEASE_THEN + it + ", " + it + RELEASE_HELD + it + RELEASE_UNTIL, null),
                        new PopupSheet.Line(RELEASE_REACH, null)),
                Arrays.asList(new PopupSheet.Button(RELEASE, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(KEEP_HOLDING, PopupSheet.Style.OUTLINED)));
    }
}
