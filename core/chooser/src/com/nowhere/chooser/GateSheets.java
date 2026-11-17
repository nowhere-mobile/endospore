package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261204-18: the gate's two picker sheets (docs/backlog.md, "Popups are plain dialogs: the choice pickers and the
 * confirmations move to one bottom-sheet design", slice 2): Back up my data (showSyncIntervalPicker) and Restore data
 * from… (pickRestoreDevice). The words are the old dialogs' title and labels, unchanged. No option is current: the gate
 * does not hold the stored cadence there, and a device list has no current device.
 *
 * Pure java.util so core/vendor-common/bin/test-gate-sheets-java.sh compiles it off the build host.
 */
final class GateSheets {
    private GateSheets() {}

    static final String SYNC_TITLE = "Back up my data";
    static final String RESTORE_TITLE = "Restore data from…";

    /** One card per cadence label, in SyncChoices order, so a tap's index is its index in SyncChoices.SECS. */
    static PopupSheet.Picker sync(String[] labels) {
        return picker(SYNC_TITLE, labels);
    }

    /** One card per device label, in LIST-UNITS order, so a tap's index is its index in the units list. */
    static PopupSheet.Picker restore(CharSequence[] labels) {
        return picker(RESTORE_TITLE, labels);
    }

    /** A null label is an empty name, never a skipped card, so the indexes never shift. */
    private static PopupSheet.Picker picker(String title, CharSequence[] labels) {
        List<PopupSheet.Option> options = new ArrayList<>();
        if (labels != null) {
            for (CharSequence l : labels) {
                String name = l == null ? "" : l.toString();
                options.add(new PopupSheet.Option(name, Collections.<String>emptyList(), "", false));
            }
        }
        return new PopupSheet.Picker(title, options);
    }
}
