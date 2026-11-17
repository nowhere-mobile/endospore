package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.Locale;

/**
 * NWP-20261206-05: the install-time picker as a PopupSheet model (docs/backlog.md, "Popups are plain dialogs: the
 * choice pickers and the confirmations move to one bottom-sheet design"; docs/product-decisions.md 2026-11-14, harvest
 * 66, first bullet). The TimePicker stays, inside SheetDialog.slot, with a green Set, an outlined Any time and Not now.
 * The context sentence is a draft and awaits Chester's mockup approval; it makes no privacy or security claim.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-ota-time-sheet-java.sh).
 */
final class OtaTimeSheet {
    private OtaTimeSheet() {}

    static final String TITLE = "Install time (while charging)";
    static final String SET = "Set";
    static final String ANY_TIME = "Any time";
    static final int SET_INDEX = 0;
    static final int ANY_TIME_INDEX = 1;
    static final int NOT_NOW_INDEX = 2;
    /** DRAFT: awaits Chester's mockup approval. The hour is OtaWindow.within's. */
    static final String CONTEXT_DRAFT =
            "When an update is ready, it installs in the hour after this time, while the phone is charging.";

    /** Routine: Set does the action; Any time clears the stored time; Not now only closes. */
    static PopupSheet.Confirm model() {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, TITLE, CONTEXT_DRAFT,
                Collections.<PopupSheet.Line>emptyList(),
                Arrays.asList(new PopupSheet.Button(SET, PopupSheet.Style.GREEN_FILLED), new PopupSheet.Button(ANY_TIME, PopupSheet.Style.OUTLINED), new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** {hour, minute} of a GET-OTA-TIME reply that is exactly "HH:MM" in range, else {3, 0}. Never throws. */
    static int[] current(String reply) {
        if (reply != null && reply.length() == 5 && reply.charAt(2) == ':' && digit(reply.charAt(0))
                && digit(reply.charAt(1)) && digit(reply.charAt(3)) && digit(reply.charAt(4))) {
            int h = Integer.parseInt(reply.substring(0, 2));
            int m = Integer.parseInt(reply.substring(3, 5));
            if (h < 24 && m < 60) return new int[] { h, m };
        }
        return new int[] { 3, 0 };
    }

    private static boolean digit(char c) {
        return c >= '0' && c <= '9';
    }

    /** The SET-OTA-TIME argument: two-digit hour, colon, two-digit minute. */
    static String hhmm(int h, int m) {
        return String.format(Locale.US, "%02d:%02d", h, m);
    }
}
