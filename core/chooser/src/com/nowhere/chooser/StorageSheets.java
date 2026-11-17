package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261204-17: three Profile pickers that apply on a tap, as PopupSheet models (docs/backlog.md, "Popups are plain
 * dialogs: the choice pickers and the confirmations move to one bottom-sheet design", design A): Backups while apps set
 * up (SealHold), Save automatically (SaveMode) and Re-archive idle apps. The words are the dialogs' words: each title,
 * and each option's name with its trade-off line under it. Only an exact match is current; an unknown value marks none.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-storage-sheets-java.sh).
 */
final class StorageSheets {
    private StorageSheets() {}

    static final String SEAL_HOLD_TITLE = "Backups while apps set up";
    static final String SAVE_MODE_TITLE = "Save automatically";
    static final String RECLAIM_TITLE = "Re-archive idle apps";

    /** One card per SealHold.VALUES entry: its label, its trade-off; cur is current. */
    static PopupSheet.Picker sealHold(String cur) {
        List<PopupSheet.Option> options = new ArrayList<>();
        for (String v : SealHold.VALUES) {
            options.add(new PopupSheet.Option(SealHold.label(v), Collections.<String>emptyList(),
                    SealHold.tradeoff(v), v.equals(cur)));
        }
        return new PopupSheet.Picker(SEAL_HOLD_TITLE, options);
    }

    /** One card per SaveMode.VALUES entry: its label, its trade-off; cur is current. */
    static PopupSheet.Picker saveMode(String cur) {
        List<PopupSheet.Option> options = new ArrayList<>();
        for (String v : SaveMode.VALUES) {
            options.add(new PopupSheet.Option(SaveMode.label(v), Collections.<String>emptyList(),
                    SaveMode.tradeoff(v), v.equals(cur)));
        }
        return new PopupSheet.Picker(SAVE_MODE_TITLE, options);
    }

    /** One card per name, no trade-off line; the card at index current is current (-1 or out of range: none). */
    static PopupSheet.Picker reclaim(CharSequence[] names, int current) {
        List<PopupSheet.Option> options = new ArrayList<>();
        if (names != null) {
            for (int i = 0; i < names.length; i++) {
                String name = names[i] == null ? null : names[i].toString();
                options.add(new PopupSheet.Option(name, Collections.<String>emptyList(), null, i == current));
            }
        }
        return new PopupSheet.Picker(RECLAIM_TITLE, options);
    }
}
