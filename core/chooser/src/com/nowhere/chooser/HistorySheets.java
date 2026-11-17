package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * NWP-20261205-14: the History screen's ("Restore a snapshot") two confirmations as PopupSheet models (docs/backlog.md,
 * "Popups are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 3).
 * Restoring a version is a warning: its green button keeps the current data and the risky "Restore" is red-outlined.
 * Deleting a version is destructive: a red filled button, then an outlined "Keep ...". The delete words come from
 * SnapshotCopy and keep docs/product-decisions.md 2026-10-19's limits: never the current state, no size promised.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-history-sheets-java.sh).
 */
final class HistorySheets {
    private HistorySheets() {}

    // DRAFT (NWP-20261205-14): mockup for Chester
    static final String DELETE_BUTTON = "Delete this version";
    static final String KEEP_VERSION = "Keep this version";
    static final String ROLLBACK_TITLE = "Restore this version?";
    static final String ROLLBACK_CONTEXT_PREFIX = "This rolls your data back to the version saved ";
    static final String ROLLBACK_CONTEXT_SUFFIX = ".";
    static final String ROLLBACK_DISCARD = "Your current data on this device will be discarded.";
    static final String ROLLBACK_SIGN_OUT = "You'll be signed out — sign in again to load the earlier version.";
    static final String KEEP_CURRENT = "Keep my current data";
    static final String RESTORE = "Restore";

    /** Delete one retained version: the red filled button deletes, the outlined one below keeps it. */
    static PopupSheet.Confirm delete(String label) {
        List<PopupSheet.Line> lines = new ArrayList<>();
        for (String l : SnapshotCopy.confirmLines()) lines.add(new PopupSheet.Line(l, null));
        return new PopupSheet.Confirm(PopupSheet.Tone.DESTRUCTIVE, SnapshotCopy.confirmTitle(),
                SnapshotCopy.confirmContext(label), lines,
                Arrays.asList(new PopupSheet.Button(DELETE_BUTTON, PopupSheet.Style.RED_FILLED),
                        new PopupSheet.Button(KEEP_VERSION, PopupSheet.Style.OUTLINED)));
    }

    /** Roll back to a retained version. The tone is a DRAFT: WARNING, because it discards this device's current data.
     *  The green button is the safe way out; "Restore" is red-outlined. */
    static PopupSheet.Confirm rollback(String label) {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, ROLLBACK_TITLE,
                ROLLBACK_CONTEXT_PREFIX + label + ROLLBACK_CONTEXT_SUFFIX,
                Arrays.asList(new PopupSheet.Line(ROLLBACK_DISCARD, null), new PopupSheet.Line(ROLLBACK_SIGN_OUT, null)),
                Arrays.asList(new PopupSheet.Button(KEEP_CURRENT, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(RESTORE, PopupSheet.Style.RED_OUTLINED)));
    }
}
