package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * NWP-20261205-10: the per-app kept-mode picker (Profile > Your apps) and its sideload warning as PopupSheet models
 * (docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet
 * design", slice 2). The picker takes AppFilter.keepModes' labels and does not know that class. The words and the
 * warning's tone are drafts for Chester's mockup approval.
 *
 * Pure java.util so a javac suite can compile it off the build host
 * (core/vendor-common/bin/test-keep-mode-sheets-java.sh).
 */
final class KeepModeSheets {
    private KeepModeSheets() {}

    /** Splits a keepModes label into the card's name and its description; not a shown word. */
    static final String SEP = " — ";

    // DRAFT (NWP-20261205-10): mockup for Chester
    static final String SIDELOAD_TITLE = "Keep a sideloaded app?";
    static final String SIDELOAD_CONTEXT = "This app didn't come from an app store, so no one has vetted it.";
    static final String SIDELOAD_SAVES = "Keeping it saves its code to your account and reinstalls it automatically "
            + "on every nowhere phone you sign in on.";
    static final String SIDELOAD_TRUST = "Only keep apps you trust.";
    static final String KEEP_IT = "Keep it";

    /** One card per item, in order: the name before the first SEP, the description after it (an item without SEP is
     *  all name). The card at checked is current; an out-of-range checked marks none. */
    static PopupSheet.Picker picker(String title, CharSequence[] items, int checked) {
        List<PopupSheet.Option> options = new ArrayList<>();
        int n = items == null ? 0 : items.length;
        for (int i = 0; i < n; i++) {
            String s = String.valueOf(items[i]);
            int k = s.indexOf(SEP);
            String name = k < 0 ? s : s.substring(0, k);
            String description = k < 0 ? "" : s.substring(k + SEP.length());
            boolean current = checked >= 0 && checked < n && i == checked;
            options.add(new PopupSheet.Option(name, Collections.<String>emptyList(), description, current));
        }
        return new PopupSheet.Picker(title, options);
    }

    /** The one-time warning before keeping a sideloaded app. Keeping unvetted code that reinstalls on every phone is
     *  the risky choice, so the green button is the way out. */
    static PopupSheet.Confirm sideload() {
        return new PopupSheet.Confirm(PopupSheet.Tone.WARNING, SIDELOAD_TITLE, SIDELOAD_CONTEXT,
                Arrays.asList(new PopupSheet.Line(SIDELOAD_SAVES, null), new PopupSheet.Line(SIDELOAD_TRUST, null)),
                Arrays.asList(new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(KEEP_IT, PopupSheet.Style.RED_OUTLINED)));
    }
}
