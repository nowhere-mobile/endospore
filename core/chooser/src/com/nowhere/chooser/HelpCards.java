package com.nowhere.chooser;

/**
 * Profile › Help as step cards (NWP-20261122-08; decision 2026-11-02, docs/product-decisions.md, "Help at the gate
 * covers the gate and Owner settings only, and Profile Help becomes picture step cards ..."). A topic is a short run
 * of cards the user swipes through; each card is one picture and one or two lines. ProfileActivity.showHelpPage draws
 * them; this class holds the rules, so javac runs them off the build host (test-help-cards-java.sh).
 *
 * A card's picture is the drawable named slotName(page, card). Until its WebP lands there is no such drawable, and the
 * screen collapses the slot, so the card is its text alone. Pure: java.lang and java.util only.
 *
 * Decision 2026-11-03 (docs/product-decisions.md, "... Profile Help's cards show where to tap", NWP-20261103-24) makes
 * each card show where to tap: its path as chips and a drawn panel of the menu with the row to tap highlighted, made
 * from the step's path (path, text, MENUS, panel; NWP-20261126-08). A card whose picture has landed shows the picture
 * in place of the panel, so the decided animations keep their slots. A step with no path shows its topic's icon.
 */
final class HelpCards {
    private HelpCards() {}

    /** The card buttons' labels, so every string on the card screen comes from HelpPages or HelpCards. */
    static final String BACK = "Back";
    static final String NEXT = "Next";

    /**
     * The topics whose first card carries one of the decided short animations (animated WebP, silent, looping):
     * "Your apps" keeping an app, "Saving and storage" Back up now, "Locking and signing out" locking. The fourth
     * decided animation, signing in, has no Profile topic: it belongs to the gate's pages, outside this screen.
     */
    static final String[] ANIMATED_TOPICS = {"Your apps", "Saving and storage", "Locking and signing out"};

    /**
     * One card per step, in order. A step that starts with "•" joins the card before it as that card's second line
     * when that card has only one line; otherwise it starts a card of its own. So no card has more than two lines, and
     * the cards read in order give back every step. A null steps gives no cards.
     */
    static String[][] cards(String[] steps) {
        java.util.ArrayList<String[]> out = new java.util.ArrayList<>();
        if (steps == null) return new String[0][];
        for (String s : steps) {
            String[] last = out.isEmpty() ? null : out.get(out.size() - 1);
            if (s.startsWith("•") && last != null && last.length == 1) {
                out.set(out.size() - 1, new String[] {last[0], s});
            } else {
                out.add(new String[] {s});
            }
        }
        return out.toArray(new String[0][]);
    }

    /** The drawable name of a card's picture: lower case, a valid resource name, unique across pages and cards. */
    static String slotName(int page, int card) {
        return "help_p" + page + "_c" + card;
    }

    /** The position label under a card: "<i+1> of <n>". */
    static String position(int i, int n) {
        return (i + 1) + " of " + n;
    }

    /** The card a swipe or a Back / Next tap lands on: i + dir, clamped to [0, n-1]. No cards gives 0. */
    static int next(int i, int n, int dir) {
        if (n <= 0) return 0;
        return Math.max(0, Math.min(n - 1, i + dir));
    }

    /**
     * Title -> the slot of that topic's first card, for each ANIMATED_TOPICS title present in titles. The page index
     * comes from the titles passed in, never a fixed number. The capture slice names its animated WebPs from this map.
     */
    static java.util.Map<String, String> animated(String[] titles) {
        java.util.LinkedHashMap<String, String> m = new java.util.LinkedHashMap<>();
        java.util.List<String> t = java.util.Arrays.asList(titles);
        for (String topic : ANIMATED_TOPICS) {
            int p = t.indexOf(topic);
            if (p >= 0) m.put(topic, slotName(p, 0));
        }
        return m;
    }

    /** The first element of every path: the Profile hub. */
    static final String ROOT = "Profile";
    /** A drawn panel shows at most this many rows of its menu. */
    static final int PANEL_ROWS = 4;
    /** The dot of the shown card, and of every other card. */
    static final String DOT_ON = "●";
    static final String DOT_OFF = "○";

    /** The separator between two path elements, in a step and between two chips. */
    static String chipSep() {
        return " › ";
    }

    /**
     * A step's path: "Profile › Security › Use a security key: add ..." gives {"Profile", "Security", "Use a security
     * key"}. A step that does not start with "Profile › ", has no ": ", or whose prefix has fewer than two parts, has
     * no path: an empty array.
     */
    static String[] path(String step) {
        if (step == null || !step.startsWith(ROOT + chipSep())) return new String[0];
        int c = step.indexOf(": ");
        if (c < 0) return new String[0];
        String[] p = step.substring(0, c).split(chipSep(), -1);
        return p.length < 2 ? new String[0] : p;
    }

    /**
     * A step's text on its card: the step without its path and ": ", its first letter upper case, since the chips
     * carry the path and the line starts a sentence. A step with no path is unchanged.
     */
    static String text(String step) {
        String[] p = path(step);
        if (p.length == 0) return step;
        String t = step.substring(step.indexOf(": ") + 2);
        if (t.isEmpty()) return t;
        return Character.toUpperCase(t.charAt(0)) + t.substring(1);
    }

    /**
     * Each menu a path can point into, keyed by its path joined with chipSep(): the menu's row and button labels in
     * screen order, as ProfileActivity draws them for a stored, online session. "Profile" is showConfirm's Lock and
     * Log off buttons, then its stored menu; Preferences has no Preset row (NWP-20261103-25). test-help-cards-java.sh
     * fails when a label is no string literal in ProfileActivity, so this map cannot drift from the screen.
     */
    static final java.util.Map<String, String[]> MENUS;
    static {
        java.util.LinkedHashMap<String, String[]> m = new java.util.LinkedHashMap<>();
        m.put("Profile", new String[] {"Lock — keep on this device", "Log off", "Storage", "Security", "Preferences",
                "Your data", "Report an issue", "Help"});
        m.put("Profile › Security", new String[] {"Change passphrase", "Use a security key", "Session PIN",
                "Tie to this phone", "Auto standby when idle", "Auto-wipe when left locked", "Always-on VPN"});
        m.put("Profile › Preferences", new String[] {"Your apps", "Apps this device is holding", "Offline media",
                "Configuration", "Time zone", "Mobile data", "Hotspot & tethering", "Location services"});
        m.put("Profile › Your data", new String[] {"Back up now", "Export a copy", "Restore a snapshot"});
        m.put("Profile › Storage", new String[] {"Start or extend a plan", "Plans & buying storage",
                "What's using space"});
        m.put("Profile › Report an issue", new String[] {"View what's sent", "Send report"});
        MENUS = java.util.Collections.unmodifiableMap(m);
    }

    /** A drawn menu panel: the menu's screen name, a window of its rows in screen order, and the row to tap. */
    static final class Panel {
        final String title;
        final String[] rows;
        final int hi;

        Panel(String title, String[] rows, int hi) {
            this.title = title;
            this.rows = rows;
            this.hi = hi;
        }
    }

    /**
     * The panel a path draws: the menu is MENUS of the path without its last element, the row to tap is the last
     * element. At most PANEL_ROWS rows show, a window that holds the row to tap, with one row above it when there is
     * one. An empty path, an unknown menu or a row that is not in the menu gives null: the card shows the topic icon.
     */
    static Panel panel(String[] path) {
        if (path == null || path.length < 2) return null;
        String key = String.join(chipSep(), java.util.Arrays.copyOf(path, path.length - 1));
        String[] all = MENUS.get(key);
        if (all == null) return null;
        int at = java.util.Arrays.asList(all).indexOf(path[path.length - 1]);
        if (at < 0) return null;
        int shown = Math.min(PANEL_ROWS, all.length);
        int start = Math.max(0, Math.min(at - 1, all.length - shown));
        return new Panel(path[path.length - 2], java.util.Arrays.copyOfRange(all, start, start + shown), at - start);
    }

    /** One glyph per HelpPages.TITLES entry, in order, drawn in a circle: a single BMP symbol each, no emoji. */
    static final String[] TOPIC_ICONS = {
        "⇄", // Your profile on any phone
        "▦", // Your apps
        "⇩", // Saving and storage
        "⇥", // Locking and signing out
        "☏", // Calls, texts and SIMs
        "◎", // Privacy controls
    };

    /** Topic page's icon. An index outside the pages throws. */
    static String icon(int page) {
        return TOPIC_ICONS[page];
    }

    /** The dots under a card: n dots, DOT_ON at i and DOT_OFF elsewhere, one space between. No cards gives "". */
    static String dots(int i, int n) {
        String[] d = new String[Math.max(0, n)];
        for (int k = 0; k < d.length; k++) d[k] = k == i ? DOT_ON : DOT_OFF;
        return String.join(" ", d);
    }
}
