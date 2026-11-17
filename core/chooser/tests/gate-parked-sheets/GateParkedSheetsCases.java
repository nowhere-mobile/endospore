package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

// NWP-20261206-07: the cases for the gate's sheets over a parked or an open session (GateParkedSheets), run against
// Lifted, the pure helpers core/vendor-common/bin/test-gate-parked-sheets-java.sh lifts out of ChooserActivity.java. Each
// sheet holds today's words (Q123, h46 #5) split into context and lines, its tone and its buttons in slot order.
public final class GateParkedSheetsCases {
    static int fails = 0, runs = 0;
    static final List<PopupSheet.Confirm> ALL = new ArrayList<>();

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String join(PopupSheet.Confirm c, String sep) {
        StringBuilder b = new StringBuilder(c.context == null ? "null" : c.context);
        for (PopupSheet.Line l : c.lines) b.append(sep).append(l.text);
        return b.toString();
    }

    static String buttons(PopupSheet.Confirm c) {
        StringBuilder b = new StringBuilder();
        for (PopupSheet.Button x : c.buttons) b.append('[').append(x.label).append(' ').append(x.style).append(']');
        return b.toString();
    }

    static boolean button(PopupSheet.Confirm c, int i, String label, PopupSheet.Style style) {
        return c.buttons.size() > i && label.equals(c.buttons.get(i).label) && c.buttons.get(i).style == style;
    }

    static void coldLock(String who, String[] p) {
        PopupSheet.Confirm c = GateParkedSheets.coldLock(Lifted.createOverColdLockTitle(), Lifted.createOverColdLockText(p),
                p != null);
        ALL.add(c);
        String n = "coldLock " + who + ": ";
        check(n + "ROUTINE", c.tone == PopupSheet.Tone.ROUTINE, c.tone);
        check(n + "title verbatim", Lifted.createOverColdLockTitle().equals(c.title), c.title);
        check(n + "join equals createOverColdLockText", Lifted.createOverColdLockText(p).equals(join(c, "\n\n")),
                join(c, "\n\n"));
        check(n + "two lines", c.lines.size() == 2, c.lines.size());
        if (p != null) {
            check(n + "Resume it green first", c.buttons.size() == 2
                    && button(c, 0, "Resume it", PopupSheet.Style.GREEN_FILLED), buttons(c));
            check(n + "Not now OUTLINED", button(c, 1, "Not now", PopupSheet.Style.OUTLINED), buttons(c));
        } else {
            check(n + "one button, Got it green", c.buttons.size() == 1
                    && button(c, 0, "Got it", PopupSheet.Style.GREEN_FILLED), buttons(c));
        }
        check(n + "violations empty", PopupSheet.violations(c).isEmpty(), PopupSheet.violations(c));
    }

    static void install(String who, String[] p, boolean credit) {
        PopupSheet.Confirm c = GateParkedSheets.installOverParked(Lifted.installOverParkedTitle(),
                Lifted.installOverParkedContext(p), Lifted.installOverParkedLines(credit));
        ALL.add(c);
        String n = "install " + who + (credit ? " credit" : " no credit") + ": ";
        check(n + "WARNING", c.tone == PopupSheet.Tone.WARNING, c.tone);
        check(n + "title", Lifted.installOverParkedTitle().equals(c.title), c.title);
        check(n + "Not now green first", button(c, 0, "Not now", PopupSheet.Style.GREEN_FILLED), buttons(c));
        check(n + "Install RED_OUTLINED", c.buttons.size() == 2 && button(c, 1, "Install", PopupSheet.Style.RED_OUTLINED),
                buttons(c));
        check(n + "join equals installOverParkedText", Lifted.installOverParkedText(p, credit).equals(join(c, " ")),
                join(c, " "));
        check(n + (credit ? "two lines" : "one line"), c.lines.size() == (credit ? 2 : 1), c.lines.size());
        check(n + "violations empty", PopupSheet.violations(c).isEmpty(), PopupSheet.violations(c));
    }

    public static void main(String[] args) {
        String[] named = Lifted.parseColdLock("COLDLOCK 11 fido2 pin alice smith");
        String[] dotted = Lifted.parseColdLock("COLDLOCK 12 nokey nopin dr. who. jr");
        check("parse: named", named != null && "alice smith".equals(named[3]), named);
        check("parse: dotted", dotted != null && "dr. who. jr".equals(dotted[3]), dotted);
        if (named == null || dotted == null) {
            System.out.println("gate parked sheets: " + fails + " of " + runs + " case(s) FAILED");
            System.exit(1);
        }

        coldLock("named", named);
        coldLock("nameless", null);

        PopupSheet.Confirm live = GateParkedSheets.createLive(Lifted.createLiveText());
        ALL.add(live);
        check("createLive: WARNING", live.tone == PopupSheet.Tone.WARNING, live.tone);
        check("createLive: title", "A session is still open".equals(live.title), live.title);
        check("createLive: Not now green first", button(live, 0, "Not now", PopupSheet.Style.GREEN_FILLED), buttons(live));
        check("createLive: Restart RED_OUTLINED", live.buttons.size() == 2
                && button(live, 1, "Restart", PopupSheet.Style.RED_OUTLINED), buttons(live));
        check("createLive: two lines", live.lines.size() == 2, live.lines.size());
        check("createLive: join equals createLiveText", Lifted.createLiveText().equals(join(live, " ")), join(live, " "));
        check("createLive: violations empty", PopupSheet.violations(live).isEmpty(), PopupSheet.violations(live));

        for (boolean credit : new boolean[] { true, false }) {
            install("named", named, credit);
            install("nameless", null, credit);
            install("dotted", dotted, credit);
        }

        for (PopupSheet.Confirm c : ALL) {
            for (PopupSheet.Button b : c.buttons) {
                String l = b.label == null ? "" : b.label.trim().toLowerCase(java.util.Locale.ROOT);
                check("no OK or Cancel label: " + c.title, !l.equals("ok") && !l.equals("cancel"), b.label);
            }
        }

        if (fails > 0) {
            System.out.println("gate parked sheets: " + fails + " of " + runs + " case(s) FAILED");
            System.exit(1);
        }
        System.out.println("gate parked sheets: all " + runs + " cases pass");
    }
}
