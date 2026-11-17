package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261206-04: Auto standby when idle as a PopupSheet picker with two boxes (docs/backlog.md, "Popups are plain
 * dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 2; docs/product-decisions.md
 * "2026-11-14 — DECIDED: four answers to harvest 66", second bullet). A card tap applies the timeout (idle=); each box
 * saves its own key (holdlock=, holdaudio=) on its toggle. ProfileActivity.showIdlePicker draws it with
 * SheetDialog.pickerWithBoxes and saves through saveStandby. The words are the old dialog's own; this class adds none.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-standby-sheet-java.sh).
 */
final class StandbySheets {
    private StandbySheets() {}

    static final String TITLE = "Auto standby when idle";

    // NWP-20260913-17: the shortest option is 5 MINUTES, not 2. At idle=2 the phone STOPPED SEALING.
    // Measured on frankel 2026-09-13 in one log, either side of the change: 10 `periodic seal -> OK`
    // in the idle=60 hour, and in the idle=2 hour ONE (itself PARTIAL) plus three `deferred: login`.
    // The cause is arithmetic on shipped constants, not a model: a resume arms a seal-suppression
    // window of loginWindowCap=180s (main.go:9765, armed at main.go:10451) and ONLY a login can close
    // it early -- the sole GRANT-PERMS sender is provisionRoamedApps, inside roamLogin
    // (ChooserActivity.java:8912, called from :3794). The cold lock fires at 120s and removes
    // .roamsession, which stops the sync (main.go:10267). With syncIntervalDefault=120 (main.go:8231;
    // syncIntervalDefault was 120 then; 900 since NWP-20261202-25's release), 180 > 120 means no
    // instant exists at which a periodic seal is both permitted AND has a live session to seal. On a phone
    // that wipes at power-off, that is lost work, so the option was not honest to offer.
    //
    // ⚠ 3 MINUTES WOULD BE THE WORST CHOICE AVAILABLE: 180s IS loginWindowCap exactly, so a 3-minute
    // idle leaves a ZERO-second seal-eligible window -- the same starvation, made intermittent. 5 min
    // leaves 120s, one whole sync tick, which is the smallest value that is not zero.
    //
    // ⚠ NO MIGRATION, BY DECISION (Chester, 2026-09-13). A profile whose roamed prefs already say
    // `idle=2` KEEPS arming 120000ms -- ChooserActivity.java:9271 parses the pref raw with no clamp --
    // while the sheet marks no card as current, because current() matches only an exact value of MINS
    // (NWP-20261206-04; the old dialog highlighted "After 15 minutes" there). So for those profiles this
    // screen does not show what the phone does until the user picks a value again. Recorded here rather
    // than hidden: it is the known cost of the decision, not an oversight.
    static final int[] MINS = { 5, 15, 30, 60, 0 };
    static final String[] LABELS = { "After 5 minutes", "After 15 minutes", "After 30 minutes", "After 1 hour", "Never" };
    /** Matches IDLE_LOGOFF_MS: the default when no idle= pref is set (DIA-20260626-03). */
    static final int DEFAULT_MINUTES = 15;

    // NWP-20261005-02 (Chester, 2026-10-05): "Wait for app installs" qualifies THIS setting, so it lives in this
    // picker -- he moved it here from a separate switch under the Security card ("looks off outside"). Each box saves
    // on its own toggle (NWP-20261206-04). On by default: only holdlock=0 turns it off (setPref).
    // NWP-20261124-17 (decision 2026-11-01, "before the idle cold lock, a session can wait for app installs and for
    // audio playing ..."): one heading over two boxes, "app installs" (holdlock=) and "audio playing" (holdaudio=).
    // Each is on unless its key is "0". A throwaway never sees either: showSecurity does not add this row there.
    static final String WAIT_HEAD = "Before standby, wait for:";
    static final String[] BOX_KEYS = { "holdlock", "holdaudio" };
    static final String[] BOX_LABELS = { "app installs", "audio playing" };

    /** The card index idle= selects: an empty or unparseable value is DEFAULT_MINUTES, a value in MINS is its index,
     *  and any other number (an old idle=2) is -1, so no card is current. */
    static int current(String idlePref) {
        int minutes = DEFAULT_MINUTES;
        if (idlePref != null && !idlePref.isEmpty()) {
            try {
                minutes = Integer.parseInt(idlePref);
            } catch (NumberFormatException e) {
                minutes = DEFAULT_MINUTES;
            }
        }
        for (int i = 0; i < MINS.length; i++) if (MINS[i] == minutes) return i;
        return -1;
    }

    /** One card per LABELS entry, no chips; card current is current when it is in range. */
    static PopupSheet.Picker picker(int current) {
        List<PopupSheet.Option> options = new ArrayList<>();
        for (int i = 0; i < LABELS.length; i++) {
            options.add(new PopupSheet.Option(LABELS[i], Collections.<String>emptyList(), null, i == current));
        }
        return new PopupSheet.Picker(TITLE, options);
    }

    /** The two boxes under WAIT_HEAD; each is checked unless its key is "0". */
    static PopupSheet.Boxes boxes(String holdlock, String holdaudio) {
        return new PopupSheet.Boxes(WAIT_HEAD, Arrays.asList(BOX_LABELS),
                Arrays.asList(!"0".equals(holdlock), !"0".equals(holdaudio)));
    }

    /** The value a box writes to its key: "" when on, "0" when off. */
    static String boxValue(boolean on) {
        return on ? "" : "0";
    }

    /** The toast after a save landed: the title and the current card's label, plus the next-sign-in note when the gate
     *  was not told. With no card current it is the title alone, plus that note. */
    static String toast(int current, boolean live) {
        String label = current >= 0 && current < LABELS.length ? ": " + LABELS[current].toLowerCase() : "";
        return TITLE + label + (live ? "" : " — applies next sign-in");
    }
}
