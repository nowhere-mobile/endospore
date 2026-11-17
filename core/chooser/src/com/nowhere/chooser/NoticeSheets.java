package com.nowhere.chooser;

import java.util.Collections;

/** NWP-20261206-08 (docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
 *  bottom-sheet design", slice 3): the save ceremony's EXISTS and SPLIT notices and the sign-out and restart failure
 *  notice (ProfileActivity.showNotice) as warning (amber) sheets with one green "Got it": each says something did not
 *  happen (Chester, 2026-11-15: "3301 amber"; PopupSheet's warning notice). The message is the caller's, unchanged:
 *  this class adds only the titles. Pure java.util, so test-notice-sheets-java.sh runs it under javac. */
final class NoticeSheets {
    private NoticeSheets() {}

    // DRAFT (NWP-20261206-08): mockup for Chester
    static final String NOT_DONE_TITLE = "That didn't go through";
    // DRAFT (NWP-20261206-08): mockup for Chester
    static final String SAVE_EXISTS_TITLE = "Not saved yet";
    // DRAFT (NWP-20261206-08): mockup for Chester
    static final String SAVE_SPLIT_TITLE = "Save didn't finish";

    /** A sign-out or a restart that did not happen. The title claims nothing more: restartUnknownMessage says only
     *  that the phone has not restarted, so it must not say "still signed in". */
    static PopupSheet.Confirm notDone(String msg) { return gotIt(PopupSheet.Tone.WARNING, NOT_DONE_TITLE, msg); }

    /** PROMOTE2 ERR-EXISTS: msg is PromoteCopy.text(r). */
    static PopupSheet.Confirm saveExists(String msg) { return gotIt(PopupSheet.Tone.WARNING, SAVE_EXISTS_TITLE, msg); }

    /** PROMOTE2 ERR-SESSION: msg is PromoteCopy.text(r). */
    static PopupSheet.Confirm saveSplit(String msg) { return gotIt(PopupSheet.Tone.WARNING, SAVE_SPLIT_TITLE, msg); }

    private static PopupSheet.Confirm gotIt(PopupSheet.Tone tone, String title, String msg) {
        return new PopupSheet.Confirm(tone, title, msg, null,
                Collections.singletonList(new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED)));
    }
}
