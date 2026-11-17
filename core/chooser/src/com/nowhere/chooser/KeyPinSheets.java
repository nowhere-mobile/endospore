package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261206-16: Profile > Security's three confirmations as PopupSheet models (docs/backlog.md, "Popups are plain
 * dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 3). Removing a security key
 * and removing the session PIN are warnings: the green "Keep it" is the safe way out and the risky "Remove" is
 * red-outlined. Confirming a key removal with a fresh tap (NWP-20261127-02) is routine: the green "USB-C key" does it
 * and "Not now" is outlined. Every word is today's; the tones and the split into context and lines are drafts.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-key-pin-sheets-java.sh).
 */
final class KeyPinSheets {
    private KeyPinSheets() {}

    // DRAFT (NWP-20261206-16): mockup for Chester
    static final String KEEP_IT = "Keep it";
    static final String REMOVE = "Remove";
    static final String REMOVE_KEY_TITLE_PREFIX = "Remove ";
    static final String REMOVE_KEY_TITLE_SUFFIX = "?";
    static final String LAST_KEY_CONTEXT = "This is your only security key.";
    static final String LAST_KEY_PASSPHRASE = "Removing it means signing in needs just your passphrase again — no key.";
    static final String LAST_KEY_ADD_BACK = "You can add one back any time.";
    static final String OTHER_KEYS_CONTEXT = "Sign-in will still need one of your other keys.";
    static final String RECOVERY_UNCHANGED = "Your recovery code is unchanged.";
    static final String CONFIRM_TITLE = "Confirm with a key";
    static final String CONFIRM_LAST = "Touch this key to confirm.";
    static final String CONFIRM_OTHER = "Touch one of your other keys to confirm. "
            + "The key you're removing doesn't count.";
    static final String USB_C_KEY = "USB-C key";
    static final String PIN_TITLE = "Remove PIN?";
    static final String PIN_CONTEXT = "Sign-in will have no device credential.";
    static final String PIN_SAFEGUARD = "That also switches off the safeguard that cancels a pending cold lock when "
            + "you pick the phone up — with no credential, unlocking is only a swipe, so it cannot count as proof "
            + "it’s you.";
    static final String PIN_COLD_LOCK = "Expect the phone to cold-lock in your hand sometimes.";
    static final String PIN_SET_AGAIN = "You can set a PIN again any time.";

    /** Remove one security key. Removing the last one is a downgrade to passphrase-only, so its sheet says so. */
    static PopupSheet.Confirm removeKey(String label, boolean last) {
        List<PopupSheet.Line> lines = new ArrayList<>();
        if (last) {
            lines.add(new PopupSheet.Line(LAST_KEY_PASSPHRASE, null));
            lines.add(new PopupSheet.Line(LAST_KEY_ADD_BACK, null));
        }
        lines.add(new PopupSheet.Line(RECOVERY_UNCHANGED, null));
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING,
                REMOVE_KEY_TITLE_PREFIX + label + REMOVE_KEY_TITLE_SUFFIX,
                last ? LAST_KEY_CONTEXT : OTHER_KEYS_CONTEXT, lines, keepOrRemove());
    }

    /** The fresh tap that confirms a key removal: this key when it is the last one, else one of the others. */
    static PopupSheet.Confirm confirmWithKey(boolean last) {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, CONFIRM_TITLE, last ? CONFIRM_LAST : CONFIRM_OTHER,
                Collections.<PopupSheet.Line>emptyList(),
                Arrays.asList(new PopupSheet.Button(USB_C_KEY, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** Clear the session PIN. It also switches off the cold-lock abort (NWP-20260909-01), so the sheet says so. */
    static PopupSheet.Confirm removePin() {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, PIN_TITLE, PIN_CONTEXT,
                Arrays.asList(new PopupSheet.Line(PIN_SAFEGUARD, null), new PopupSheet.Line(PIN_COLD_LOCK, null),
                        new PopupSheet.Line(PIN_SET_AGAIN, null)),
                keepOrRemove());
    }

    private static List<PopupSheet.Button> keepOrRemove() {
        return Arrays.asList(new PopupSheet.Button(KEEP_IT, PopupSheet.Style.GREEN_FILLED),
                new PopupSheet.Button(REMOVE, PopupSheet.Style.RED_OUTLINED));
    }
}
