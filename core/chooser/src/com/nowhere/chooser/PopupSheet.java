package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * NWP-20261201-28: the shared bottom sheet's pure half (docs/backlog.md, "Popups are plain dialogs: the choice pickers
 * and the confirmations move to one bottom-sheet design", design A, Chester 2026-11-08). A picker is a sheet of cards,
 * one per option; a confirmation is a round tone icon, a short title, one context sentence, "what happens" lines and
 * buttons, in one of three tones. This class holds the models, the fixed words and the rules check. SheetDialog draws a
 * model and calls violations() before it shows one.
 *
 * The rules: a button names its action, never OK or Cancel; "&" is spelled "and"; a destructive or risky action is
 * never the green button. Routine: one green button does the action and the others are outlined. Warning: the green
 * button is the safe way out and the risky choice is red-outlined. Destructive: a red filled button, then an outlined
 * "Keep ...". Plain information is the routine tone with one "Got it".
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-popup-sheet-java.sh).
 */
final class PopupSheet {
    private PopupSheet() {}

    enum Tone { ROUTINE, WARNING, DESTRUCTIVE }

    enum Style { GREEN_FILLED, OUTLINED, RED_OUTLINED, RED_FILLED }

    static final String CURRENT_SUFFIX = "· current";
    static final String NOT_NOW = "Not now";
    static final String GOT_IT = "Got it";
    /** The first words that may not sit on a green button. */
    static final List<String> DESTRUCTIVE_VERBS = Collections.unmodifiableList(Arrays.asList("Delete", "Erase", "Wipe", "Remove", "Discard", "Unbind", "Clear", "Reset", "Drop", "Forget", "Leave", "Uninstall"));

    static final String R_EMPTY = "the model or its tone is missing";
    static final String R_OK_CANCEL = "a button says OK or Cancel instead of naming its action";
    static final String R_AMPERSAND = "a text holds \"&\" instead of \"and\"";
    static final String R_GREEN_DESTRUCTIVE = "a destructive action is on the green button";
    static final String R_ROUTINE_BUTTONS = "a routine sheet needs exactly one green button and all others outlined";
    static final String R_WARNING_BUTTONS = "a warning needs one green way out, a red-outlined risk and no red filled button";
    static final String R_DESTRUCTIVE_GREEN = "a destructive sheet has a green button";
    static final String R_DESTRUCTIVE_ORDER = "a destructive sheet needs one red filled button first, then an outlined \"Keep ...\"";
    static final String R_GOT_IT_TONE = "a lone \"Got it\" is only for the routine tone";
    static final String R_TWO_CURRENT = "a picker has more than one current option";

    /** One card of a picker. */
    static final class Option {
        final String name;
        final List<String> chips;
        final String description;
        final boolean current;

        Option(String name, List<String> chips, String description, boolean current) {
            this.name = name;
            this.chips = copy(chips);
            this.description = description;
            this.current = current;
        }
    }

    /** A sheet of cards. */
    static final class Picker {
        final String title;
        final List<Option> options;

        Picker(String title, List<Option> options) {
            this.title = title;
            this.options = copy(options);
        }
    }

    /** A "what happens" line; a non-null linkKey makes it a link to that screen. */
    static final class Line {
        final String text;
        final String linkKey;

        Line(String text, String linkKey) {
            this.text = text;
            this.linkKey = linkKey;
        }
    }

    static final class Button {
        final String label;
        final Style style;

        Button(String label, Style style) {
            this.label = label;
            this.style = style;
        }
    }

    /** A confirmation. */
    static final class Confirm {
        final Tone tone;
        final String title;
        final String context;
        final List<Line> lines;
        final List<Button> buttons;

        Confirm(Tone tone, String title, String context, List<Line> lines, List<Button> buttons) {
            this.tone = tone;
            this.title = title;
            this.context = context;
            this.lines = copy(lines);
            this.buttons = copy(buttons);
        }
    }

    private static <T> List<T> copy(List<T> in) {
        return in == null ? Collections.<T>emptyList() : Collections.unmodifiableList(new ArrayList<>(in));
    }

    /** One fixed reason per breach of a picker's rules; empty when it has none. Never throws. */
    static List<String> violations(Picker p) {
        List<String> out = new ArrayList<>();
        if (p == null) {
            out.add(R_EMPTY);
            return out;
        }
        ampersand(p.title, out);
        int current = 0;
        for (Option o : p.options) {
            if (o == null) continue;
            ampersand(o.name, out);
            ampersand(o.description, out);
            for (String c : o.chips) ampersand(c, out);
            if (o.current) current++;
        }
        if (current > 1) out.add(R_TWO_CURRENT);
        return out;
    }

    /** One fixed reason per breach of a confirmation's rules; empty when it has none. Never throws. */
    static List<String> violations(Confirm c) {
        List<String> out = new ArrayList<>();
        if (c == null || c.tone == null) {
            out.add(R_EMPTY);
            if (c == null) return out;
        }
        ampersand(c.title, out);
        ampersand(c.context, out);
        for (Line l : c.lines) if (l != null) ampersand(l.text, out);
        List<Button> buttons = new ArrayList<>();
        for (Button b : c.buttons) if (b != null) buttons.add(b);
        for (Button b : buttons) {
            ampersand(b.label, out);
            if (isOkOrCancel(b.label)) out.add(R_OK_CANCEL);
            if (b.style == Style.GREEN_FILLED && isDestructiveVerb(b.label)) out.add(R_GREEN_DESTRUCTIVE);
        }
        int green = count(buttons, Style.GREEN_FILLED);
        if (c.tone == Tone.ROUTINE && (green != 1 || count(buttons, Style.OUTLINED) != buttons.size() - 1))
            out.add(R_ROUTINE_BUTTONS);
        if (c.tone == Tone.WARNING
                && (green != 1 || count(buttons, Style.RED_OUTLINED) < 1 || count(buttons, Style.RED_FILLED) != 0))
            out.add(R_WARNING_BUTTONS);
        if (c.tone == Tone.DESTRUCTIVE && green != 0) out.add(R_DESTRUCTIVE_GREEN);
        if (c.tone == Tone.DESTRUCTIVE && !destructiveOrder(buttons)) out.add(R_DESTRUCTIVE_ORDER);
        if (c.tone != Tone.ROUTINE && buttons.size() == 1 && GOT_IT.equals(buttons.get(0).label)) out.add(R_GOT_IT_TONE);
        return out;
    }

    private static void ampersand(String text, List<String> out) {
        if (text != null && text.indexOf('&') >= 0) out.add(R_AMPERSAND);
    }

    private static boolean isOkOrCancel(String label) {
        if (label == null) return false;
        String l = label.trim().toLowerCase(Locale.ROOT);
        return l.equals("ok") || l.equals("okay") || l.equals("cancel");
    }

    private static boolean isDestructiveVerb(String label) {
        if (label == null) return false;
        String first = label.trim().split("\\s+", 2)[0];
        for (String v : DESTRUCTIVE_VERBS) if (v.equalsIgnoreCase(first)) return true;
        return false;
    }

    private static int count(List<Button> buttons, Style style) {
        int n = 0;
        for (Button b : buttons) if (b.style == style) n++;
        return n;
    }

    private static boolean destructiveOrder(List<Button> buttons) {
        if (buttons.size() < 2 || count(buttons, Style.RED_FILLED) != 1) return false;
        Button keep = buttons.get(1);
        return buttons.get(0).style == Style.RED_FILLED && keep.style == Style.OUTLINED && keep.label != null
                && keep.label.trim().startsWith("Keep ");
    }
}
