package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261204-15: the Security screen's two pickers as PopupSheet models (docs/backlog.md, "Popups are plain dialogs:
 * the choice pickers and the confirmations move to one bottom-sheet design", slice 2): Erase a locked session after
 * and Always-on VPN. The words are the dialogs' own title and labels; this class adds none.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-security-sheets-java.sh).
 */
final class SecuritySheets {
    private SecuritySheets() {}

    static final String WIPE_TITLE = "Erase a locked session after";
    static final String VPN_TITLE = "Always-on VPN";

    /** One card per WipeChoice.LABELS entry; choice sel is current when it is one of them. */
    static PopupSheet.Picker wipe(int sel) {
        return cards(WIPE_TITLE, Arrays.asList(WipeChoice.LABELS), sel);
    }

    /** One card per label; index current is current when it is in range, so a negative index marks none. */
    static PopupSheet.Picker vpn(List<String> labels, int current) {
        return cards(VPN_TITLE, labels, current);
    }

    private static PopupSheet.Picker cards(String title, List<String> names, int current) {
        List<PopupSheet.Option> options = new ArrayList<>();
        if (names != null) {
            for (int i = 0; i < names.size(); i++) {
                options.add(new PopupSheet.Option(names.get(i), Collections.<String>emptyList(), null, i == current));
            }
        }
        return new PopupSheet.Picker(title, options);
    }
}
