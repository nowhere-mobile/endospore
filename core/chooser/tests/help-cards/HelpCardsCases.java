package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * NWP-20261122-08: Profile › Help as step cards (decision 2026-11-02), run by test-help-cards-java.sh. The page cases
 * read HelpPages as it stands, never a fixed page index, so they hold when the pages are rewritten. After the cases
 * it prints the shot list: every card's picture slot, the capture slice's list of pictures to take.
 *
 * NWP-20261126-08 (decision 2026-11-03): the where-to-tap cases. path/text on real steps, found by their text; panel
 * windows; every pathed step draws a panel; TOPIC_ICONS one per title; the dots. On a pass it prints one
 * "menu-label<TAB><label>" line per MENUS label, and the suite finds each as a string literal in ProfileActivity.
 */
public final class HelpCardsCases {
    private static int fails = 0;

    private static void check(boolean ok, String what) {
        if (!ok) {
            fails++;
            System.out.println("  FAIL  " + what);
        }
    }

    private static String[] flat(String[][] cards) {
        List<String> out = new ArrayList<>();
        for (String[] c : cards) out.addAll(Arrays.asList(c));
        return out.toArray(new String[0]);
    }

    private static void rule(String[] steps, String[][] want) {
        String[][] got = HelpCards.cards(steps);
        check(Arrays.deepEquals(got, want), "cards(" + Arrays.toString(steps) + ") is " + Arrays.deepToString(got)
                + ", want " + Arrays.deepToString(want));
    }

    private static void next(int i, int n, int dir, int want) {
        int got = HelpCards.next(i, n, dir);
        check(got == want, "next(" + i + ", " + n + ", " + dir + ") is " + got + ", want " + want);
    }

    /** The first step on any page that starts with start, else null. */
    private static String step(String start) {
        for (int p = 0; p < HelpPages.TITLES.length; p++) {
            for (String s : HelpPages.steps(p)) if (s.startsWith(start)) return s;
        }
        return null;
    }

    private static void pathText(String start, String[] wantPath, String wantTextStart) {
        String s = step(start);
        check(s != null, "no HelpPages step starts with <" + start + ">");
        if (s == null) return;
        String[] got = HelpCards.path(s);
        check(Arrays.equals(got, wantPath), "path(" + s + ") is " + Arrays.toString(got) + ", want "
                + Arrays.toString(wantPath));
        String t = HelpCards.text(s);
        check(t.startsWith(wantTextStart), "text(" + s + ") is <" + t + ">, want it to start <" + wantTextStart + ">");
        if (wantPath.length == 0) check(t.equals(s), "text(" + s + ") changed a step with no path: <" + t + ">");
    }

    /** The panel rules for a path that must draw one: rows a contiguous run of the menu, the last element at hi. */
    private static void panelOk(String[] path, String what) {
        HelpCards.Panel pn = HelpCards.panel(path);
        check(pn != null, what + ": panel(" + Arrays.toString(path) + ") is null");
        if (pn == null) return;
        String[] all = HelpCards.MENUS.get(String.join(HelpCards.chipSep(), Arrays.copyOf(path, path.length - 1)));
        check(all != null, what + ": no MENUS entry for " + Arrays.toString(path));
        if (all == null) return;
        check(pn.rows.length == Math.min(HelpCards.PANEL_ROWS, all.length),
                what + ": " + pn.rows.length + " rows, want " + Math.min(HelpCards.PANEL_ROWS, all.length));
        check(pn.hi >= 0 && pn.hi < pn.rows.length, what + ": hi " + pn.hi + " is outside the " + pn.rows.length
                + " rows shown");
        if (pn.hi >= 0 && pn.hi < pn.rows.length) {
            check(pn.rows[pn.hi].equals(path[path.length - 1]), what + ": row " + pn.hi + " is <" + pn.rows[pn.hi]
                    + ">, want <" + path[path.length - 1] + ">");
        }
        check(pn.title.equals(path[path.length - 2]), what + ": title <" + pn.title + ">, want <"
                + path[path.length - 2] + ">");
        int start = pn.rows.length == 0 ? -1 : Arrays.asList(all).indexOf(pn.rows[0]);
        check(start >= 0 && start + pn.rows.length <= all.length
                && Arrays.equals(pn.rows, Arrays.copyOfRange(all, start, start + pn.rows.length)),
                what + ": rows " + Arrays.toString(pn.rows) + " are no run of " + Arrays.toString(all));
    }

    public static void main(String[] args) {
        // 1 every page: at least one card, 1 or 2 lines a card, every step kept in order, joined cards included.
        Set<String> slots = new HashSet<>();
        List<String> shots = new ArrayList<>();
        Map<String, String> anim = HelpCards.animated(HelpPages.TITLES);
        for (int p = 0; p < HelpPages.TITLES.length; p++) {
            String[] steps = HelpPages.steps(p);
            String[][] c = HelpCards.cards(steps);
            check(c.length >= 1, "page " + p + " (" + HelpPages.TITLES[p] + ") gives no card");
            for (int k = 0; k < c.length; k++) {
                check(c[k].length >= 1 && c[k].length <= 2,
                        "page " + p + " card " + k + " has " + c[k].length + " lines, want 1 or 2");
                if (c[k].length == 2) {
                    check(c[k][1].startsWith("•"), "page " + p + " card " + k + ": a second line that is no bullet");
                }
                String s = HelpCards.slotName(p, k);
                check(s.matches("[a-z0-9_]+"), "slot " + s + " is not a valid resource name");
                check(slots.add(s), "slot " + s + " is used twice");
                shots.add(s + "  " + HelpPages.TITLES[p] + " card " + (k + 1) + "/" + c.length + ": "
                        + (c[k].length > 0 ? c[k][0] : "") + (anim.containsValue(s) ? " [animated]" : ""));
            }
            check(Arrays.equals(flat(c), steps), "page " + p + ": the cards " + Arrays.deepToString(c)
                    + " do not give back the steps " + Arrays.toString(steps));
        }
        check(HelpPages.steps(0) != HelpPages.steps(0), "steps() returns the shared array, not a copy");

        // 2 the split rule.
        rule(new String[] {"A", "• b", "• c"}, new String[][] {{"A", "• b"}, {"• c"}});
        rule(new String[] {"• a", "B"}, new String[][] {{"• a"}, {"B"}});
        rule(new String[] {"A", "B"}, new String[][] {{"A"}, {"B"}});
        rule(new String[] {"A", "• b", "C", "• d"}, new String[][] {{"A", "• b"}, {"C", "• d"}});
        rule(new String[] {}, new String[][] {});
        rule(null, new String[][] {});

        // 3 slot names.
        check(HelpCards.slotName(2, 0).equals("help_p2_c0"), "slotName(2, 0) is " + HelpCards.slotName(2, 0));
        check(!HelpCards.slotName(1, 11).equals(HelpCards.slotName(11, 1)), "slotName(1, 11) == slotName(11, 1)");
        check(!HelpCards.slotName(0, 0).equals(HelpCards.slotName(1, 0)), "slotName(0, 0) == slotName(1, 0)");

        // 4 the position label.
        check(HelpCards.position(0, 5).equals("1 of 5"), "position(0, 5) is " + HelpCards.position(0, 5));
        check(HelpCards.position(4, 5).equals("5 of 5"), "position(4, 5) is " + HelpCards.position(4, 5));

        // 5 the swipe index clamps at both ends.
        next(0, 5, -1, 0);
        next(4, 5, 1, 4);
        next(2, 5, 1, 3);
        next(2, 5, -1, 1);
        next(3, 5, 0, 3);
        next(0, 1, 1, 0);
        next(0, 1, -1, 0);
        next(0, 0, 1, 0);

        // 6 the animated first cards: each ANIMATED_TOPICS title in TITLES maps to its own first card's slot.
        check(!anim.isEmpty(), "no animated topic is among the Help titles");
        List<String> titles = Arrays.asList(HelpPages.TITLES);
        for (String topic : HelpCards.ANIMATED_TOPICS) {
            int p = titles.indexOf(topic);
            if (p < 0) {
                check(!anim.containsKey(topic), "animated() maps " + topic + ", which is no Help title");
                continue;
            }
            check(HelpCards.slotName(p, 0).equals(anim.get(topic)),
                    "animated " + topic + " is " + anim.get(topic) + ", want " + HelpCards.slotName(p, 0));
        }
        check(new HashSet<>(anim.values()).size() == anim.size(), "two animated topics share a slot");
        check(slots.containsAll(anim.values()), "an animated slot is no card's slot");

        // 7 the button labels.
        check(!HelpCards.BACK.isEmpty() && !HelpCards.NEXT.isEmpty() && !HelpCards.BACK.equals(HelpCards.NEXT),
                "BACK <" + HelpCards.BACK + "> and NEXT <" + HelpCards.NEXT + "> must be two labels");

        // 8 path and text on real steps, and on steps with no path.
        pathText("Profile › Security › Use a security key: ", new String[] {"Profile", "Security", "Use a security key"},
                "Add a key that you touch");
        pathText("Profile › Lock — keep on this device: ", new String[] {"Profile", "Lock — keep on this device"},
                "Lock the phone");
        pathText("Profile › Report an issue › View what's sent: ",
                new String[] {"Profile", "Report an issue", "View what's sent"}, "Read a report");
        pathText("Sign in on any Nowhere phone", new String[0], "Sign in on any Nowhere phone");
        pathText("The apps you keep come back with you.", new String[0], "The apps you keep");
        check(HelpCards.path(null).length == 0, "path(null) is not empty");
        check(HelpCards.path("Profile: x").length == 0, "path(\"Profile: x\") has a path of one part");
        check(HelpCards.path("Profile › Security without a colon").length == 0, "a step with no \": \" has a path");

        // 9 the panel for Use a security key, and the nulls.
        String[] key = {"Profile", "Security", "Use a security key"};
        panelOk(key, "Use a security key");
        HelpCards.Panel kp = HelpCards.panel(key);
        check(kp != null && kp.rows.length <= HelpCards.PANEL_ROWS, "the security key panel shows more than "
                + HelpCards.PANEL_ROWS + " rows");
        check(HelpCards.panel(new String[] {"Profile", "Nowhere", "X"}) == null, "an unknown menu draws a panel");
        check(HelpCards.panel(new String[] {"Profile", "Security", "No such row"}) == null, "an unknown row draws a panel");
        check(HelpCards.panel(new String[0]) == null, "an empty path draws a panel");
        check(HelpCards.panel(null) == null, "a null path draws a panel");

        // 10 every HelpPages step with a path draws a panel, so a renamed row or menu fails here.
        int pathed = 0;
        for (int p = 0; p < HelpPages.TITLES.length; p++) {
            for (String st : HelpPages.steps(p)) {
                String[] pa = HelpCards.path(st);
                if (pa.length == 0) continue;
                pathed++;
                panelOk(pa, "page " + p + " step <" + st + ">");
            }
        }
        check(pathed >= 10, "only " + pathed + " HelpPages steps have a path");

        // 11 the window sweep: every row of every menu is shown and highlighted in its own window.
        for (Map.Entry<String, String[]> e : HelpCards.MENUS.entrySet()) {
            String[] parts = e.getKey().split(HelpCards.chipSep(), -1);
            check(parts[0].equals(HelpCards.ROOT), "MENUS key <" + e.getKey() + "> does not start at " + HelpCards.ROOT);
            check(e.getValue().length >= 1, "MENUS <" + e.getKey() + "> has no row");
            check(new HashSet<>(Arrays.asList(e.getValue())).size() == e.getValue().length,
                    "MENUS <" + e.getKey() + "> lists a row twice");
            for (String r : e.getValue()) {
                String[] pa = Arrays.copyOf(parts, parts.length + 1);
                pa[parts.length] = r;
                panelOk(pa, "MENUS <" + e.getKey() + "> row <" + r + ">");
            }
        }
        check(!HelpCards.MENUS.containsKey("Profile › Preferences")
                || !String.join("\n", HelpCards.MENUS.get("Profile › Preferences")).contains("Preset"),
                "MENUS lists a Preset row in Preferences");

        // 12 one icon per topic: a single BMP symbol, no two alike.
        check(HelpCards.TOPIC_ICONS.length == HelpPages.TITLES.length, "TOPIC_ICONS has " + HelpCards.TOPIC_ICONS.length
                + " entries for " + HelpPages.TITLES.length + " titles");
        check(new HashSet<>(Arrays.asList(HelpCards.TOPIC_ICONS)).size() == HelpCards.TOPIC_ICONS.length,
                "two topics share an icon");
        for (int p = 0; p < HelpCards.TOPIC_ICONS.length; p++) {
            String g = HelpCards.TOPIC_ICONS[p];
            boolean one = g.length() == 1 && !Character.isSurrogate(g.charAt(0));
            check(one, "TOPIC_ICONS[" + p + "] <" + g + "> is not one BMP character");
            if (one) {
                int ty = Character.getType(g.charAt(0));
                check(ty == Character.OTHER_SYMBOL || ty == Character.MATH_SYMBOL,
                        "TOPIC_ICONS[" + p + "] <" + g + "> is no symbol (type " + ty + ")");
            }
            if (p < HelpPages.TITLES.length) check(HelpCards.icon(p).equals(g), "icon(" + p + ") is not TOPIC_ICONS[" + p + "]");
        }

        // 13 the chip separator and the dots.
        check(HelpCards.chipSep().equals(" › "), "chipSep() is <" + HelpCards.chipSep() + ">");
        check(HelpCards.dots(1, 3).equals("○ ● ○"), "dots(1, 3) is <" + HelpCards.dots(1, 3) + ">");
        check(HelpCards.dots(0, 1).equals("●"), "dots(0, 1) is <" + HelpCards.dots(0, 1) + ">");
        check(HelpCards.dots(0, 0).isEmpty(), "dots(0, 0) is <" + HelpCards.dots(0, 0) + ">");

        if (fails > 0) {
            System.out.println("HelpCardsCases: " + fails + " failed");
            System.exit(1);
        }
        System.out.println("HelpCardsCases: all cases pass");
        System.out.println("shot list (" + shots.size() + " slots):");
        for (String s : shots) System.out.println("  " + s);
        for (String[] labels : HelpCards.MENUS.values()) {
            for (String l : labels) System.out.println("menu-label\t" + l);
        }
    }
}
