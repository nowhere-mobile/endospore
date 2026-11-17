package com.nowhere.chooser;

import java.util.List;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Option;
import com.nowhere.chooser.PopupSheet.Picker;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261205-10: the kept-mode picker and the sideload warning as sheets. Each failure line names its case. */
final class KeepModeSheetsCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static CharSequence[] labels(boolean hasIcon) {
        List<String[]> modes = AppFilter.keepModes(hasIcon);
        CharSequence[] items = new CharSequence[modes.size()];
        for (int i = 0; i < items.length; i++) items[i] = modes.get(i)[0];
        return items;
    }

    private static int currents(Picker p) {
        int n = 0;
        for (Option o : p.options) if (o.current) n++;
        return n;
    }

    /** C1: four cards, the name before the dash, the description after it, verbatim; no chips. */
    private static void fourModes() {
        CharSequence[] items = labels(true);
        Picker p = KeepModeSheets.picker("Calculator", items, 0);
        String[] names = { "Off", "On-demand", "Auto", "Keep installed" };
        check("C1 four options", p.options.size() == 4);
        for (int i = 0; i < Math.min(4, p.options.size()); i++) {
            Option o = p.options.get(i);
            String s = items[i].toString();
            String after = s.substring(s.indexOf(" — ") + 3);
            check("C1 name of option " + i + " is " + names[i], names[i].equals(o.name));
            check("C1 description of option " + i + " is the text after the dash", after.equals(o.description));
            check("C1 option " + i + " has no chips", o.chips.isEmpty());
        }
        check("C1 Off's description reads removed at logoff",
                p.options.size() > 0 && "removed at logoff".equals(p.options.get(0).description));
        check("C1 Keep installed's description reads ready to use the moment you sign in",
                p.options.size() == 4 && "ready to use the moment you sign in".equals(p.options.get(3).description));
    }

    /** C2: exactly one current at k when 0 <= k < 4, none otherwise. */
    private static void current() {
        CharSequence[] items = labels(true);
        for (int k = -1; k <= 4; k++) {
            Picker p = KeepModeSheets.picker("T", items, k);
            boolean in = k >= 0 && k < items.length;
            check("C2 checked " + k + ": " + (in ? "exactly one current" : "none current"), currents(p) == (in ? 1 : 0));
            if (in) check("C2 checked " + k + ": the current one is at " + k, p.options.get(k).current);
        }
    }

    /** C3: an app with no launcher icon gets two cards. */
    private static void noIcon() {
        Picker p = KeepModeSheets.picker("T", labels(false), -1);
        check("C3 no-icon: two options", p.options.size() == 2);
        check("C3 no-icon: Off then Keep installed", p.options.size() == 2 && "Off".equals(p.options.get(0).name)
                && "Keep installed".equals(p.options.get(1).name));
        check("C3 no-icon at -1: none current", currents(p) == 0);
    }

    /** C4: an item without the dash is all name. */
    private static void noDash() {
        Picker p = KeepModeSheets.picker("T", new CharSequence[] { "Plain - item", "A — b — c" }, -1);
        check("C4 no dash: all name", "Plain - item".equals(p.options.get(0).name));
        check("C4 no dash: empty description", "".equals(p.options.get(0).description));
        check("C4 split at the first dash only", "A".equals(p.options.get(1).name)
                && "b — c".equals(p.options.get(1).description));
        check("C4 null items: no options", KeepModeSheets.picker("T", null, 0).options.isEmpty());
    }

    /** C5 + C6: the title is verbatim; neither picker breaks a rule. */
    private static void titleAndRules() {
        String title = "Calculator — beta";
        Picker p = KeepModeSheets.picker(title, labels(true), 2);
        check("C5 title verbatim", title.equals(p.title));
        check("C6 four-card picker: no violations", PopupSheet.violations(p).isEmpty());
        check("C6 two-card picker: no violations", PopupSheet.violations(KeepModeSheets.picker(title, labels(false), 1)).isEmpty());
    }

    /** C7: the sideload warning, amber, with Not now as its green way out. */
    private static void sideload() {
        Confirm c = KeepModeSheets.sideload();
        check("C7 tone WARNING", c.tone == Tone.WARNING);
        check("C7 title", "Keep a sideloaded app?".equals(c.title));
        check("C7 context", "This app didn't come from an app store, so no one has vetted it.".equals(c.context));
        check("C7 two lines", c.lines.size() == 2);
        if (c.lines.size() == 2) {
            check("C7 line 1", ("Keeping it saves its code to your account and reinstalls it automatically on every "
                    + "nowhere phone you sign in on.").equals(c.lines.get(0).text));
            check("C7 line 2", "Only keep apps you trust.".equals(c.lines.get(1).text));
            check("C7 no line is a link", c.lines.get(0).linkKey == null && c.lines.get(1).linkKey == null);
        }
        check("C7 two buttons", c.buttons.size() == 2);
        int green = 0;
        for (Button b : c.buttons) if (b.style == Style.GREEN_FILLED) green++;
        check("C7 exactly one GREEN_FILLED", green == 1);
        if (c.buttons.size() == 2) {
            check("C7 button 0 is Not now, GREEN_FILLED",
                    "Not now".equals(c.buttons.get(0).label) && c.buttons.get(0).style == Style.GREEN_FILLED);
            check("C7 button 1 is Keep it, RED_OUTLINED",
                    "Keep it".equals(c.buttons.get(1).label) && c.buttons.get(1).style == Style.RED_OUTLINED);
        }
        check("C7 no violations", PopupSheet.violations(c).isEmpty());
    }

    public static void main(String[] args) {
        fourModes();
        current();
        noIcon();
        noDash();
        titleAndRules();
        sideload();
        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: KeepModeSheetsCases");
    }
}
