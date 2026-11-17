package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

// NWP-20261206-09: the cases for the gate's two sign-in loss sheets (SigninLossSheets), run under plain javac by
// core/vendor-common/bin/test-signin-loss-sheets-java.sh. SupersedeCopy is supersedeLossTitle, supersedeLossContext and
// supersedeLossLines lifted out of ChooserActivity.java, so the warning is built here exactly as the gate builds it.
// Every failure prints "FAIL <case>", which the suite's --mutate reads.
public final class SigninLossSheetsCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String button(PopupSheet.Confirm c, int i) {
        if (i >= c.buttons.size()) return "<none>";
        PopupSheet.Button b = c.buttons.get(i);
        return b == null ? "<null>" : b.label + " / " + b.style;
    }

    static boolean is(PopupSheet.Confirm c, int i, String label, PopupSheet.Style style) {
        if (i >= c.buttons.size() || c.buttons.get(i) == null) return false;
        PopupSheet.Button b = c.buttons.get(i);
        return label.equals(b.label) && b.style == style;
    }

    static List<String> lineTexts(PopupSheet.Confirm c) {
        List<String> out = new ArrayList<>();
        for (PopupSheet.Line l : c.lines) out.add(l == null ? null : l.text);
        return out;
    }

    public static void main(String[] a) {
        // ---- the warning before a sign-in ends a locked session ----
        // The words must be true of a stored session and a throwaway alike (blind login: no existence oracle), so no
        // word -- the button labels included -- speaks to a reader, promises a sign-out's retry, or names an amount.
        for (boolean credit : new boolean[] { true, false }) {
            String k = "supersede (" + (credit ? "credit" : "none") + "): ";
            String[] lines = SupersedeCopy.supersedeLossLines(credit);
            PopupSheet.Confirm c = SigninLossSheets.supersede(SupersedeCopy.supersedeLossTitle(),
                    SupersedeCopy.supersedeLossContext(), lines);
            check(k + "tone is WARNING", c.tone == PopupSheet.Tone.WARNING, c.tone);
            check(k + "Keep that session is the green first button",
                    is(c, 0, "Keep that session", PopupSheet.Style.GREEN_FILLED), button(c, 0));
            check(k + "Continue is RED_OUTLINED", c.buttons.size() == 2
                    && is(c, 1, "Continue", PopupSheet.Style.RED_OUTLINED), c.buttons.size() + " " + button(c, 1));
            String keep = c.buttons.isEmpty() || c.buttons.get(0) == null ? "" : c.buttons.get(0).label;
            check(k + "the green button says what it keeps", keep.startsWith("Keep ") && keep.endsWith("that session"),
                    keep);
            StringBuilder all = new StringBuilder();
            all.append(c.title).append('\n').append(c.context);
            for (PopupSheet.Line l : c.lines) if (l != null) all.append('\n').append(l.text);
            for (PopupSheet.Button b : c.buttons) if (b != null) all.append('\n').append(b.label);
            String lower = all.toString().toLowerCase(Locale.ROOT);
            boolean clean = !lower.contains("your") && !lower.contains("sign out") && !lower.contains("signing out")
                    && !lower.contains("again") && !lower.contains("save to") && !lower.matches("(?s).*[0-9].*");
            check(k + "no word, labels included, holds your, sign out, signing out, again, save to or a digit", clean,
                    all);
            List<String> want = new ArrayList<>();
            for (String l : lines) want.add(l);
            check(k + "the context and lines are the gate's",
                    SupersedeCopy.supersedeLossTitle().equals(c.title)
                            && SupersedeCopy.supersedeLossContext().equals(c.context) && lineTexts(c).equals(want),
                    c.title + " | " + c.context + " | " + lineTexts(c));
            check(k + "violations() empty", PopupSheet.violations(c).isEmpty(), PopupSheet.violations(c));
        }

        // ---- Couldn't load your data ----
        PopupSheet.Confirm s = SigninLossSheets.snapshotOffer();
        check("snapshotOffer: tone is WARNING", s.tone == PopupSheet.Tone.WARNING, s.tone);
        check("snapshotOffer: Try again is the green first button",
                is(s, 0, "Try again", PopupSheet.Style.GREEN_FILLED), button(s, 0));
        check("snapshotOffer: Restore last good version is RED_OUTLINED, second",
                is(s, 1, "Restore last good version", PopupSheet.Style.RED_OUTLINED), button(s, 1));
        check("snapshotOffer: Not now is OUTLINED, third", s.buttons.size() == 3
                && is(s, 2, PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED), s.buttons.size() + " " + button(s, 2));
        check("snapshotOffer: the title is Couldn't load your data", "Couldn't load your data".equals(s.title), s.title);
        // The sheet splits the dialog's one message (main before NWP-20261206-09) into a context and two lines; the
        // words are the same.
        String joined = s.context + " " + String.join(" ", lineTexts(s));
        check("snapshotOffer: context and lines joined equal today's message", joined.equals("Your latest data didn't "
                + "load. Try again first. If it fails again, your most recent save may be damaged, and you can restore "
                + "your last good version instead."), joined);
        boolean okCancel = false;
        for (PopupSheet.Button b : s.buttons) {
            String l = b == null || b.label == null ? "" : b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) okCancel = true;
        }
        check("snapshotOffer: no OK or Cancel button", !okCancel, s.buttons.size());
        check("snapshotOffer: violations() empty", PopupSheet.violations(s).isEmpty(), PopupSheet.violations(s));

        System.out.println(fails == 0 ? "ALL " + runs + " PASS" : fails + " of " + runs + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
