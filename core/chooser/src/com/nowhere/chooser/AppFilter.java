package com.nowhere.chooser;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * NWP-20261016-48: the search on Your apps, and the order of the apps listed after the kept ones, as pure text rules
 * (docs/product-decisions.md, 2026-10-16).
 *
 * SEARCH. Chester, 2026-10-16: "your apps - can we add a filter on top? I've about 50 apps and getting harder to find
 * the app I am looking for". A field pinned above the list filters it as you type: every term typed must appear,
 * anywhere and in any order, in the app's label as the row shows it or in its package name, ignoring case and accents.
 * Text only, so a mode change never makes a row appear or vanish. While a search is active the kept rows cannot be
 * reordered: a move among the matches has no single meaning in the whole install order (DECIDED 2026-10-12), so the
 * handles hide and the line under the field says to clear the search.
 *
 * FOLDING is per character and locale-free: String.toLowerCase() with no locale folds 'I' to a dotless i on a Turkish
 * phone, and "instagram" no longer finds "Instagram". It runs after NFKD with the combining marks dropped, so an
 * accented letter matches its plain one and a full-width or ligature form matches its plain letters. The few Latin
 * letters NFKD leaves whole are mapped by hand: sharp s to ss, ae and oe ligatures to two letters, slashed o, barred
 * l, stroked d and the dotless i to their plain letter.
 *
 * ORDER. The kept rows keep the order the user dragged (KeepOrder.keptFirst); every other row is listed A to Z.
 *
 * NO ICON (NWP-20261111-13, Q140, DECIDED 2026-10-20). An installed app with no launcher icon -- a keyboard, an icon
 * pack, a plugin, a widget-only app -- is a row like any other (launcherless picks them), and its picker offers only
 * Off and Keep installed (keepModes): On-demand and Auto rely on an icon placeholder it cannot show. gms and gsf stay
 * out; reconcilePlayStack owns them.
 *
 * Pure Java, no Android types, so core/chooser/tests/app-filter runs every rule under a plain JDK
 * (core/vendor-common/bin/test-app-filter-java.sh). The views stay in ProfileActivity, and so does the query: it says
 * which apps the profile has, so it is never logged and never written to the chooser's files dir, which seals and roams.
 */
final class AppFilter {
    private AppFilter() {}

    /** The text as the search compares it: NFKD with the combining marks dropped, lower-cased one character at a time
     *  with no locale, the letters NFKD leaves whole spelled plainly, every run of white space one space, and none at
     *  either end. Null is the empty string. */
    static String fold(CharSequence s) {
        if (s == null) return "";
        String d = Normalizer.normalize(s, Normalizer.Form.NFKD);
        StringBuilder b = new StringBuilder(d.length());
        boolean gap = false;
        for (int i = 0; i < d.length(); i++) {
            char c = d.charAt(i);
            if (Character.getType(c) == Character.NON_SPACING_MARK) continue;
            if (Character.isWhitespace(c) || Character.isSpaceChar(c)) { gap = b.length() > 0; continue; }
            if (gap) { b.append(' '); gap = false; }
            c = Character.toLowerCase(c);
            switch (c) {
                case 0x00df: b.append("ss"); break; // ß
                case 0x00e6: b.append("ae"); break; // æ
                case 0x0153: b.append("oe"); break; // œ
                case 0x00f8: b.append('o'); break; // ø
                case 0x0142: b.append('l'); break; // ł
                case 0x0111: b.append('d'); break; // đ
                case 0x0131: b.append('i'); break; // ı
                default: b.append(c);
            }
        }
        return b.toString();
    }

    /** The search's terms: the folded query split at its spaces. A blank or null query has none, and matches every row. */
    static String[] terms(CharSequence q) {
        String f = fold(q);
        return f.isEmpty() ? new String[0] : f.split(" ");
    }

    /** What a row is searched by: its label as shown and its package, each folded, joined by a line break. A term never
     *  holds a line break (fold turns one into the space terms are split at), so no match runs from label into package. */
    static String key(CharSequence label, String pkg) {
        return fold(label) + "\n" + fold(pkg);
    }

    /** Whether a row matches: every term appears in its key. No terms matches every row. */
    static boolean matches(String[] terms, String key) {
        String k = key == null ? "" : key;
        for (String t : terms) if (!k.contains(t)) return false;
        return true;
    }

    /** Whether a row's drag handle shows: the row is kept, and no search is active. */
    static boolean reorderable(boolean kept, boolean searching) {
        return kept && !searching;
    }

    /** The line under the field, or null to hide it: there is no search, or no rows yet (the list is still loading).
     *  Bundled apps and the Play providers are not Your apps rows, so a search that finds nothing says so. */
    static String countLine(CharSequence q, int shown, int total, boolean keptShown) {
        if (terms(q).length == 0 || total == 0) return null;
        if (shown == 0) return "No app matches \u201c" + q.toString().trim() + "\u201d. Apps that came with the phone, "
                + "and Google Play services, are not listed here.";
        String s = shown + " of " + total + (total == 1 ? " app" : " apps");
        return keptShown ? s + " \u00b7 clear the search to reorder" : s;
    }

    /** Your apps' rows in the order the screen lists them. The kept rows lead, in the order given -- KeepOrder.keptFirst's,
     *  the order the user dragged, which is the order apps install in (DECIDED 2026-10-12). Every other row follows, A to
     *  Z by its label folded as the search folds it, then by the label as shown, then by package, so the order is the same
     *  on every visit; a row with no label sorts by its package. No row is added or dropped. */
    static List<String> otherRowsAtoZ(List<String> rows, Collection<String> kept, Map<String, String> labels) {
        List<String> out = new ArrayList<>(rows.size());
        List<String> rest = new ArrayList<>();
        for (String p : rows) {
            if (kept.contains(p)) out.add(p);
            else rest.add(p);
        }
        final Map<String, String> shown = new HashMap<>();
        final Map<String, String> folded = new HashMap<>();
        for (String p : rest) {
            String l = labels == null ? null : labels.get(p);
            if (l == null || l.isEmpty()) l = p;
            shown.put(p, l);
            folded.put(p, fold(l));
        }
        rest.sort((a, b) -> {
            int c = folded.get(a).compareTo(folded.get(b));
            if (c == 0) c = shown.get(a).compareTo(shown.get(b));
            return c != 0 ? c : a.compareTo(b);
        });
        out.addAll(rest);
        return out;
    }

    /** NWP-20261111-13: the Your apps rows the launcher pass cannot find. Each installed row is {pkg, system "1"/"0",
     *  updated system "1"/"0", source dir present "1"/"0"}, in the order PackageManager listed them. Returns, in that
     *  order, every pkg not in seen, not self, not gms or gsf (reconcilePlayStack owns them), not a system app, not an
     *  updated system app, and with a source dir -- the launcher pass's own filters. seen is read, never changed: the
     *  caller adds what it lists, as the other passes do. */
    static List<String> launcherless(List<String[]> installed, Set<String> seen, String self, String gms, String gsf) {
        List<String> out = new ArrayList<>();
        for (String[] r : installed) {
            if (r == null || r.length < 4 || r[0] == null || r[0].isEmpty()) continue;
            String p = r[0];
            if (seen.contains(p) || out.contains(p)) continue;
            if (p.equals(self)) continue;
            if (p.equals(gms) || p.equals(gsf)) continue;
            if ("1".equals(r[1])) continue;
            if ("1".equals(r[2])) continue;
            if (!"1".equals(r[3])) continue;
            out.add(p);
        }
        return out;
    }

    /** NWP-20261111-13: the keep-mode picker's rows as {label, mode}, mode null for Off. With a launcher icon, the four
     *  in the order the picker has always listed them; without one, Off and Keep installed only -- On-demand and Auto
     *  rely on an icon placeholder, and would never bring the app back (Q140). The mode words are ProfileActivity's
     *  MODE_ONDEMAND, MODE_AUTO and MODE_INSTALLED. */
    static List<String[]> keepModes(boolean hasIcon) {
        List<String[]> out = new ArrayList<>(4);
        out.add(new String[] { "Off — removed at logoff", null });
        if (hasIcon) {
            out.add(new String[] { "On-demand — icon only, downloads when you tap it", "ondemand" });
            out.add(new String[] { "Auto — downloads by itself after you sign in", "auto" }); // #130: the default for new keeps
        }
        out.add(new String[] { "Keep installed — ready to use the moment you sign in", "installed" });
        return out;
    }
}
