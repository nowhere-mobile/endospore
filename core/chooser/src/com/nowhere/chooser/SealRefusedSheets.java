package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * NWP-20261206-11: the sign-out refusal pair as PopupSheet models (docs/backlog.md, "Popups are plain dialogs: the
 * choice pickers and the confirmations move to one bottom-sheet design", slice 3, the sign-out group, part 2).
 * ProfileActivity.showSealRefusedDialog shows refused() when a sign-out is refused for an app Nowhere could not read;
 * its "Sign out without ..." button opens drop(), the second step before that app's data is dropped
 * (ProfileActivity.confirmDropAndSignOut, NWP-20260825-14). The titles, context sentences, lines and the labels of
 * today's buttons are the dialogs' words, unchanged, except that a sheet naming several apps ("these apps") says "are"
 * and "their", "stay" and "them", and starts its sentence with a capital (the dialogs said "these apps is switched off
 * ... its data"). The tones, the green role of "Stay signed in" and the new "Keep me signed in" are drafts.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-seal-refused-sheets-java.sh).
 */
final class SealRefusedSheets {
    private SealRefusedSheets() {}

    // DRAFT (NWP-20261206-11): mockup for Chester
    static final PopupSheet.Tone REFUSED_TONE = PopupSheet.Tone.WARNING;
    // DRAFT (NWP-20261206-11): mockup for Chester
    static final PopupSheet.Tone DROP_TONE = PopupSheet.Tone.DESTRUCTIVE;
    // DRAFT (NWP-20261206-11): mockup for Chester
    static final String STAY = "Stay signed in";
    // DRAFT (NWP-20261206-11): mockup for Chester
    static final String KEEP = "Keep me signed in";

    static final String REPORT = "Report this";
    static final String REST_SAVED = "Everything else in your session IS saved, and your stored copy is intact.";
    static final String REST_NOT_SAVED =
            "Not everything else in your session could be saved either, but your stored copy is intact.";
    static final String DROP_REST_SAVED = "Everything else in this session is saved either way.";

    /** The first step: who blocks the sign-out, what is safe, and the way out without them. Green is the safe way
     *  out ("Stay signed in"); the risky sign-out is red-outlined. */
    static PopupSheet.Confirm refused(String who, String one, boolean many, boolean restSaved) {
        return new PopupSheet.Confirm(REFUSED_TONE,
                who + (many ? " are blocking sign-out" : " is blocking sign-out"),
                "nowhere couldn't read some of " + who + "'s files, so it can't save this session safely and has "
                        + "not signed you out.",
                Arrays.asList(new PopupSheet.Line(restSaved ? REST_SAVED : REST_NOT_SAVED, null),
                        new PopupSheet.Line("You can sign out without " + one + ". If you do, " + one + (many
                                ? " are switched off for this profile and their data from this session is NOT kept."
                                : " is switched off for this profile and its data from this session is NOT kept."),
                                null)),
                Arrays.asList(new PopupSheet.Button(STAY, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button("Sign out without " + one, PopupSheet.Style.RED_OUTLINED),
                        new PopupSheet.Button(REPORT, PopupSheet.Style.OUTLINED)));
    }

    /** The second step: only the loss, a red filled button that says what it does, then the way back. many: one
     *  names several apps ("these apps"). */
    static PopupSheet.Confirm drop(String who, String one, boolean many, boolean restSaved) {
        List<PopupSheet.Line> lines = new ArrayList<>();
        lines.add(new PopupSheet.Line(many
                ? capital(one) + " stay switched off for this profile until you turn them back on in Your apps, so "
                        + "later sessions will not carry them either."
                : one + " stays switched off for this profile until you turn it back on in Your "
                        + "apps, so later sessions will not carry it either.", null));
        if (restSaved) lines.add(new PopupSheet.Line(DROP_REST_SAVED, null));
        return new PopupSheet.Confirm(DROP_TONE, "Sign out without " + one + "?",
                who + "'s data from this session will NOT be saved, and cannot be recovered.",
                lines,
                Arrays.asList(new PopupSheet.Button("Drop " + one + " and sign out", PopupSheet.Style.RED_FILLED),
                        new PopupSheet.Button(KEEP, PopupSheet.Style.OUTLINED)));
    }

    /** s with its first letter in upper case: the plural line starts a sentence with "these apps". */
    private static String capital(String s) {
        return s == null || s.isEmpty() ? s : Character.toUpperCase(s.charAt(0)) + s.substring(1);
    }
}
