package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;

/**
 * NWP-20261206-18: the two Google confirmations as PopupSheet models (docs/backlog.md, "Popups are plain dialogs: the
 * choice pickers and the confirmations move to one bottom-sheet design", design A, slice 3). Turn Google Play off is a
 * warning: its green button keeps Google Play and "Turn off" is red-outlined. Sign out of Google is routine, with the
 * words docs/product-decisions.md 2026-10-21 (dn-1106 #2) decided. ProfileActivity.confirmPlayOff and
 * confirmGoogleSignOut draw them through SheetDialog.confirm.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-google-sheets-java.sh).
 */
final class GoogleSheets {
    private GoogleSheets() {}

    /** The sign-out dialog's positive label before NWP-20261206-18, kept. */
    static final String SIGN_OUT = "Sign out";

    // DRAFT (NWP-20261206-18): mockup for Chester
    static final String KEEP_PLAY = "Keep Google Play";

    /** Turn Google Play off. The tone is a DRAFT: WARNING, because Off removes Play Store and signs the Google account
     *  out. Button 0 keeps Google Play; button 1 turns it off. */
    static PopupSheet.Confirm playOff() {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, PlayChoice.OFF_TITLE, PlayChoice.OFF_CONTEXT,
                Arrays.asList(new PopupSheet.Line(PlayChoice.OFF_LINE, null)),
                Arrays.asList(new PopupSheet.Button(KEEP_PLAY, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PlayChoice.OFF_CONFIRM, PopupSheet.Style.RED_OUTLINED)));
    }

    /** Sign out of Google. The tone is a DRAFT: ROUTINE. The title and the context are decided, word for word.
     *  Button 0 signs the account out; button 1 closes. */
    static PopupSheet.Confirm signOut() {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, GoogleSignOut.ROW_LABEL, GoogleSignOut.CONFIRM,
                Collections.<PopupSheet.Line>emptyList(),
                Arrays.asList(new PopupSheet.Button(SIGN_OUT, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }
}
