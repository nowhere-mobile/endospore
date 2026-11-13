package com.nowhere.chooser;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261130-11: the gate's Help combo screen, run by test-gate-help-combo-java.sh. The screen is built against the
 *  stubs beside this file, which record text, descriptions, clicks and colours. Every failure prints "FAIL T<n>: ...". */
public final class GateHelpComboCases {
    private static int fails = 0;
    private static final Context C = new Context();

    private static void check(String id, boolean ok, String what) {
        if (!ok) {
            fails++;
            System.out.println("  FAIL " + id + ": " + what);
        }
    }

    private interface Case { void run() throws Exception; }

    private static void run(String id, Case c) {
        try {
            c.run();
        } catch (Exception | Error e) {
            check(id, false, "threw " + e);
        }
    }

    /** B4 (decision 2026-10-31, Part B). T11 compares this copy with HelpPagesCases.B4_WORDS. */
    private static final String[] B4 = {
        "protect", "secure", "safe", "encrypt", "private", "privacy", "anonymous", "untrace", "track",
        "can't see", "can’t see", "never see", "nobody", "no one",
    };

    private static final String LOG_OFF_STEP = "Profile › Log off: sign out. A saved profile saves to your store first.";

    private static final class RecNav implements GateHelpScreen.Nav {
        final List<String> events = new ArrayList<>();
        View shown;
        @Override public void show(View v) { shown = v; events.add("show"); }
        @Override public void close() { events.add("close"); }
        @Override public void openTile(int i) { events.add("tile:" + i); }
        @Override public void openForgot() { events.add("forgot"); }
    }

    private static List<View> walk(View root) {
        List<View> out = new ArrayList<>();
        walk(root, out);
        return out;
    }

    private static void walk(View v, List<View> out) {
        out.add(v);
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) walk(g.getChildAt(i), out);
        }
    }

    private static int indexOfText(List<View> t, String text) {
        for (int i = 0; i < t.size(); i++) {
            if (t.get(i) instanceof TextView && text.contentEquals(((TextView) t.get(i)).getText())) return i;
        }
        return -1;
    }

    private static boolean holdsText(View root, String text) {
        return root != null && indexOfText(walk(root), text) >= 0;
    }

    private static View byText(View root, String text) {
        List<View> t = walk(root);
        int i = indexOfText(t, text);
        return i < 0 ? null : t.get(i);
    }

    private static View byDescription(View root, String d) {
        for (View v : walk(root)) {
            CharSequence cd = v.getContentDescription();
            if (cd != null && d.contentEquals(cd)) return v;
        }
        return null;
    }

    private static GateHelpArtView art(List<View> t) {
        for (View v : t) if (v instanceof GateHelpArtView) return (GateHelpArtView) v;
        return null;
    }

    private static List<GateHelpTileGrid> grids(List<View> t) {
        List<GateHelpTileGrid> out = new ArrayList<>();
        for (View v : t) if (v instanceof GateHelpTileGrid) out.add((GateHelpTileGrid) v);
        return out;
    }

    private static Canvas drawn(GateHelpArtView a) {
        Canvas cv = new Canvas();
        a.layout(0, 0, 600, 300);
        a.draw(cv);
        return cv;
    }

    private static List<View> trees(GatePalette p) {
        List<View> roots = new ArrayList<>();
        roots.add(GateHelpScreen.home(C, p, new RecNav()));
        for (int i = 0; i < GateHelpHome.INTRO.length; i++) roots.add(GateHelpScreen.intro(C, p, i, new RecNav()));
        return roots;
    }

    // --- T1, T2, T3: the home screen's structure and its controls

    private static void structure() {
        run("T1", () -> {
            View home = GateHelpScreen.home(C, GatePalette.DARK, new RecNav());
            List<View> t = walk(home);
            int a = art(t) == null ? -1 : t.indexOf(art(t));
            int title = indexOfText(t, GateHelpHome.HERO_TITLE), body = indexOfText(t, GateHelpHome.HERO_BODY);
            int watch = indexOfText(t, GateHelpHome.WATCH);
            int grid = grids(t).isEmpty() ? -1 : t.indexOf(grids(t).get(0));
            check("T1", a >= 0 && a < title && title < body && body < watch && watch < grid,
                    "hero art " + a + ", title " + title + ", body " + body + ", watch " + watch + ", grid " + grid
                            + ": want that order, all present");
            check("T1", art(t) != null && art(t).kind == GateHelpHome.ART_HERO, "the first art is not the hero");
            check("T1", "How Nowhere works".equals(GateHelpHome.HERO_TITLE), "hero title " + GateHelpHome.HERO_TITLE);
            check("T1", "Watch the 3 steps".equals(GateHelpHome.WATCH), "watch label " + GateHelpHome.WATCH);
            check("T1", watch >= 0 && t.get(watch) instanceof Button, "Watch the 3 steps is not a button");
        });
        run("T2", () -> {
            List<GateHelpTileGrid> g = grids(walk(GateHelpScreen.home(C, GatePalette.DARK, new RecNav())));
            check("T2", g.size() == 1, g.size() + " grids, want 1");
            GateHelpTileGrid grid = g.get(0);
            check("T2", grid.getChildCount() == 2, grid.getChildCount() + " rows, want 2");
            List<String> labels = new ArrayList<>();
            for (int r = 0; r < grid.getChildCount(); r++) {
                ViewGroup row = (ViewGroup) grid.getChildAt(r);
                check("T2", row.getChildCount() == 3, "row " + r + " has " + row.getChildCount() + " tiles, want 3");
                for (int c = 0; c < row.getChildCount(); c++) {
                    for (View v : walk(row.getChildAt(c))) {
                        if (v instanceof TextView) labels.add(((TextView) v).getText().toString());
                    }
                }
            }
            check("T2", labels.equals(Arrays.asList("Signing in", "Your apps", "Saving", "Lock or log off",
                    "Calls and SIMs", "Owner")), "tile labels " + labels);
            check("T2", labels.equals(Arrays.asList(GateHelpHome.TILES)), "tile labels are not GateHelpHome.TILES");
        });
        run("T3", () -> {
            RecNav nav = new RecNav();
            View home = GateHelpScreen.home(C, GatePalette.DARK, nav);
            GateHelpTileGrid grid = grids(walk(home)).get(0);
            int i = 0;
            for (int r = 0; r < grid.getChildCount(); r++) {
                ViewGroup row = (ViewGroup) grid.getChildAt(r);
                for (int c = 0; c < row.getChildCount(); c++, i++) {
                    nav.events.clear();
                    check("T3", row.getChildAt(c).performClick(), "tile " + i + " has no click");
                    check("T3", nav.events.equals(Arrays.asList("tile:" + i)), "tile " + i + " gives " + nav.events);
                }
            }
            nav.events.clear();
            View forgot = byDescription(home, GateHelpHome.forgotDescription());
            check("T3", forgot != null && forgot.performClick() && nav.events.equals(Arrays.asList("forgot")),
                    "the Forgot card does not call openForgot: " + nav.events);
            nav.events.clear();
            View back = byText(home, GateHelpHome.BACK);
            check("T3", back != null && back.performClick() && nav.events.equals(Arrays.asList("close")),
                    "Back does not call close: " + nav.events);
            nav.events.clear();
            View watch = byText(home, GateHelpHome.WATCH);
            check("T3", watch != null && watch.performClick() && holdsText(nav.shown, GateHelpHome.INTRO[0][0]),
                    "Watch does not open the first intro step");
        });
    }

    // --- T4, T5, T6, T9, T10: the words each control opens

    private static void mapping() {
        run("T4", () -> {
            int[] page = { 0, -1, -1, 3, -1, 2 };
            String[] shortTitle = { null, "Your apps", "Saving", null, "Calls and SIMs", null };
            for (int i = 0; i < 6; i++) {
                String title = page[i] >= 0 ? GateHelpPages.TITLES[page[i]] : shortTitle[i];
                check("T4", title.equals(GateHelpHome.tileTitle(i)), "tile " + i + " title " + GateHelpHome.tileTitle(i));
                if (page[i] >= 0) {
                    check("T4", GateHelpPages.body(page[i]).equals(GateHelpHome.tileBody(i)),
                            "tile " + i + " is not GateHelpPages page " + page[i]);
                } else {
                    check("T4", GateHelpHome.tileBody(i) != null, "tile " + i + " has no body");
                }
            }
            check("T4", GateHelpHome.tileBody(1) != null && GateHelpHome.tileBody(1).contains("Your apps")
                    && GateHelpHome.tileBody(2) != null && GateHelpHome.tileBody(2).contains("Back up now")
                    && GateHelpHome.tileBody(4) != null && GateHelpHome.tileBody(4).contains("SIM lines"),
                    "a short page has another tile's body");
            for (int bad : new int[] { -1, 6 }) {
                boolean threw = false;
                try {
                    GateHelpHome.tileBody(bad);
                } catch (RuntimeException e) {
                    threw = true;
                }
                check("T4", threw, "tileBody(" + bad + ") answers");
            }
        });
        run("T5", () -> {
            Set<String> seen = new HashSet<>();
            Set<Integer> reached = new HashSet<>();
            for (int i = 0; i < 6; i++) {
                String b = GateHelpHome.tileBody(i);
                check("T5", b != null && !b.trim().isEmpty(), "tile " + i + " has an empty body");
                check("T5", seen.add(String.valueOf(b)), "tile " + i + " has the body of another tile");
                for (int p = 0; p < GateHelpPages.TITLES.length; p++) {
                    if (GateHelpPages.body(p).equals(b) || GateHelpHome.tileAlso(i) == p) reached.add(p);
                }
            }
            for (int p = 0; p < GateHelpPages.TITLES.length; p++) {
                check("T5", reached.contains(p), "no tile reaches the gate page \"" + GateHelpPages.TITLES[p] + "\"");
            }
            check("T5", GateHelpPages.TITLES[1].equals(GateHelpHome.alsoLabel(0)), "alsoLabel(0) " + GateHelpHome.alsoLabel(0));
        });
        run("T6", () -> {
            for (int i : new int[] { 1, 2, 4 }) {
                check("T6", GateHelpHome.tileBody(i) != null && GateHelpHome.tileBody(i).contains("Profile › Help"),
                        "tile " + i + " does not name Profile › Help");
            }
        });
        run("T9", () -> check("T9", Arrays.asList(GateHelpPages.body(3).split("\n\n")).contains(LOG_OFF_STEP),
                "GateHelpPages.body(3) has no step \"" + LOG_OFF_STEP + "\""));
        run("T10", () -> {
            check("T10", GateHelpHome.forgotBody().contains("12-word recovery code"), "the Forgot page has no recovery code");
            check("T10", "Forgot your passphrase?".equals(GateHelpHome.FORGOT_TITLE), "Forgot title " + GateHelpHome.FORGOT_TITLE);
            List<View> t = walk(GateHelpScreen.home(C, GatePalette.DARK, new RecNav()));
            int grid = t.indexOf(grids(t).get(0));
            int forgot = t.indexOf(byDescription(t.get(0), GateHelpHome.forgotDescription()));
            int back = indexOfText(t, GateHelpHome.BACK);
            int lastTile = grid + walk(grids(t).get(0)).size() - 1;
            check("T10", lastTile < forgot && forgot < back, "tiles end " + lastTile + ", card " + forgot + ", Back " + back);
            check("T10", indexOfText(t, GateHelpHome.FORGOT_TITLE) >= 0 && indexOfText(t, GateHelpHome.FORGOT_SUB) >= 0,
                    "the Forgot card does not show its title and its line");
        });
    }

    // --- T7, T8: the intro

    private static void intro() {
        run("T7", () -> {
            check("T7", GateHelpHome.INTRO.length == 3, GateHelpHome.INTRO.length + " steps, want 3");
            check("T7", GateHelpHome.INTRO_ART.length == GateHelpHome.INTRO.length, "INTRO_ART is not one per step");
            for (int i = 0; i < GateHelpHome.INTRO.length; i++) {
                String[] s = GateHelpHome.INTRO[i];
                check("T7", s.length == 3, "step " + i + " is " + s.length + " strings, want a title and two lines");
                for (String x : s) check("T7", x != null && !x.trim().isEmpty(), "step " + i + " has an empty string");
                List<View> t = walk(GateHelpScreen.intro(C, GatePalette.DARK, i, new RecNav()));
                int a = art(t) == null ? -1 : t.indexOf(art(t));
                int title = indexOfText(t, s[0]), l1 = indexOfText(t, s[1]), l2 = indexOfText(t, s[2]);
                View dotsV = byDescription(t.get(0), GateHelpHome.dotsDescription(i));
                int dots = t.indexOf(dotsV), next = indexOfText(t, GateHelpHome.nextLabel(i));
                int skip = indexOfText(t, GateHelpHome.SKIP);
                check("T7", a >= 0 && a < title && title < l1 && l1 < l2 && l2 < dots && dots < next && next < skip,
                        "step " + i + ": art " + a + ", title " + title + ", lines " + l1 + " " + l2 + ", dots " + dots
                                + ", next " + next + ", skip " + skip + ": want that order, all present");
                check("T7", art(t) != null && art(t).kind == GateHelpHome.INTRO_ART[i], "step " + i + " has the wrong art");
            }
            check("T7", GateHelpHome.INTRO[0][0].equals("Your profile on any phone")
                    && GateHelpHome.INTRO[1][0].equals("Saving") && GateHelpHome.INTRO[2][0].equals("Lock or log off"),
                    "the three steps are not the chosen three");
        });
        run("T8", () -> {
            RecNav nav = new RecNav();
            for (int i = 0; i < 3; i++) {
                View v = GateHelpScreen.intro(C, GatePalette.DARK, i, nav);
                nav.shown = null;
                byText(v, GateHelpHome.nextLabel(i)).performClick();
                String want = i < 2 ? GateHelpHome.INTRO[i + 1][0] : GateHelpHome.HERO_TITLE;
                check("T8", holdsText(nav.shown, want), "Next on step " + i + " does not reach \"" + want + "\"");
                nav.shown = null;
                View skip = byText(v, GateHelpHome.SKIP);
                check("T8", skip != null && skip.performClick() && holdsText(nav.shown, GateHelpHome.HERO_TITLE),
                        "Skip on step " + i + " does not reach the home screen");
                for (GatePalette p : new GatePalette[] { GatePalette.DARK, GatePalette.LIGHT }) {
                    View root = GateHelpScreen.intro(C, p, i, new RecNav());
                    ViewGroup dots = (ViewGroup) byDescription(root, GateHelpHome.dotsDescription(i));
                    check("T8", dots != null && dots.getChildCount() == 3, "step " + i + " has no 3 dots");
                    for (int d = 0; d < dots.getChildCount(); d++) {
                        int fill = ((GradientDrawable) dots.getChildAt(d).getBackground()).fill;
                        check("T8", fill == (d == i ? p.accent : p.dotOff), "step " + i + " dot " + d + " colour");
                    }
                }
            }
            check("T8", "Next".equals(GateHelpHome.nextLabel(0)) && "Done".equals(GateHelpHome.nextLabel(2)), "the Next labels");
        });
    }

    // --- T11: B4

    private static void b4Strings(Set<String> out) throws Exception {
        for (Field f : GateHelpHome.class.getDeclaredFields()) {
            if (!Modifier.isStatic(f.getModifiers()) || f.isSynthetic()) continue;
            f.setAccessible(true);
            Object v = f.get(null);
            if (v instanceof String) out.add((String) v);
            if (v instanceof String[]) out.addAll(Arrays.asList((String[]) v));
            if (v instanceof String[][]) for (String[] r : (String[][]) v) if (r != null) out.addAll(Arrays.asList(r));
        }
        for (int i = 0; i < GateHelpHome.TILES.length; i++) {
            out.add(GateHelpHome.tileDescription(i));
            out.add(GateHelpHome.tileBody(i));
        }
        for (int i = 0; i < GateHelpHome.INTRO.length; i++) {
            out.add(GateHelpHome.nextLabel(i));
            out.add(GateHelpHome.nextDescription(i));
            out.add(GateHelpHome.dotsDescription(i));
        }
        out.add(GateHelpHome.forgotDescription());
        out.add(GateHelpHome.forgotBody());
        for (GatePalette p : new GatePalette[] { GatePalette.DARK, GatePalette.LIGHT }) {
            for (View root : trees(p)) {
                for (View v : walk(root)) {
                    if (v instanceof TextView) out.add(((TextView) v).getText().toString());
                    if (v.getContentDescription() != null) out.add(v.getContentDescription().toString());
                    if (v instanceof GateHelpArtView) out.addAll(drawn((GateHelpArtView) v).texts);
                }
            }
        }
    }

    private static void b4() {
        run("T11", () -> {
            Set<String> strings = new TreeSet<>();
            b4Strings(strings);
            check("T11", strings.size() > 30, "only " + strings.size() + " strings read");
            for (String s : strings) {
                String low = s.toLowerCase(Locale.ROOT);
                for (String w : B4) check("T11", !low.contains(w), "\"" + s + "\" holds the B4 word \"" + w + "\"");
            }
            for (String name : new String[] { "GateHelpScreen", "GateHelpTileGrid", "GateHelpArtView" }) {
                Matcher m = Pattern.compile("\"([^\"]*)\"").matcher(source(name));
                while (m.find()) {
                    String low = m.group(1).toLowerCase(Locale.ROOT);
                    for (String w : B4) check("T11", !low.contains(w), name + " holds the literal \"" + m.group(1) + "\"");
                }
            }
            String cases = read(new File(System.getProperty("gatehelp.helpcases")));
            int a = cases.indexOf("B4_WORDS = {");
            Set<String> theirs = new LinkedHashSet<>();
            Matcher m = Pattern.compile("\"([^\"]*)\"").matcher(cases.substring(a, cases.indexOf("};", a)));
            while (m.find()) theirs.add(m.group(1));
            check("T11", a >= 0 && theirs.equals(new LinkedHashSet<>(Arrays.asList(B4))),
                    "the local B4 list is not HelpPagesCases.B4_WORDS: " + theirs);
        });
    }

    // --- T12, T13: both palettes

    private static double luminance(int c) {
        double[] v = new double[3];
        for (int i = 0; i < 3; i++) {
            double s = ((c >> (16 - 8 * i)) & 0xFF) / 255.0;
            v[i] = s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
    }

    private static double contrast(int a, int b) {
        double x = luminance(a), y = luminance(b);
        return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
    }

    private static void floor(String name, int fg, int bg, double min) {
        check("T12", contrast(fg, bg) >= min, name + " is " + contrast(fg, bg) + ":1, want " + min);
    }

    private static void palettes() {
        run("T12", () -> {
            for (GatePalette p : new GatePalette[] { GatePalette.DARK, GatePalette.LIGHT }) {
                GateHelpArt.Roles r = GateHelpArt.of(p);
                check("T12", r.cardFill == p.panel && r.cardEdge == p.panelLn && r.accent == p.accent && r.ink == p.ink
                        && r.body == p.hint && r.onAccent == p.onAccent && r.screen == p.bg && r.dotOff == p.dotOff,
                        "a role is not the palette field of its row");
                String n = p == GatePalette.DARK ? "dark " : "light ";
                floor(n + "accent on card", r.accent, r.cardFill, 3.0);
                floor(n + "accent text on screen", r.accent, r.screen, 4.5);
                floor(n + "ink on card", r.ink, r.cardFill, 4.5);
                floor(n + "body on card", r.body, r.cardFill, 4.5);
                floor(n + "button text", r.onAccent, r.accent, 4.5);
                floor(n + "ink on screen", r.ink, r.screen, 4.5);
                floor(n + "body on screen", r.body, r.screen, 4.5);
            }
            GateHelpArt.Roles d = GateHelpArt.of(GatePalette.DARK), l = GateHelpArt.of(GatePalette.LIGHT);
            check("T12", d.cardFill != l.cardFill && d.ink != l.ink && d.screen != l.screen && d.accent != l.accent,
                    "the two palettes give one look");
        });
        run("T13", () -> {
            for (GatePalette p : new GatePalette[] { GatePalette.DARK, GatePalette.LIGHT }) {
                Set<Integer> roles = new HashSet<>(Arrays.asList(p.panel, p.panelLn, p.accent, p.ink, p.hint, p.onAccent,
                        p.bg, p.dotOff));
                for (View root : trees(p)) {
                    int arts = 0;
                    for (View v : walk(root)) {
                        List<Integer> seen = new ArrayList<>();
                        if (v instanceof TextView) seen.add(((TextView) v).getCurrentTextColor());
                        Drawable bg = v.getBackground();
                        if (bg instanceof GradientDrawable) {
                            seen.add(((GradientDrawable) bg).fill);
                            if (((GradientDrawable) bg).hasStroke) seen.add(((GradientDrawable) bg).stroke);
                        }
                        if (v instanceof ImageView) {
                            check("T13", ((ImageView) v).getImageTintList() != null, "an icon has no tint");
                            if (((ImageView) v).getImageTintList() != null) {
                                seen.add(((ImageView) v).getImageTintList().getDefaultColor());
                            }
                        }
                        if (v instanceof GateHelpArtView) {
                            arts++;
                            Canvas cv = drawn((GateHelpArtView) v);
                            check("T13", cv.colors.size() >= 8, "an art view draws " + cv.colors.size() + " parts");
                            seen.addAll(cv.colors);
                        }
                        for (int c : seen) {
                            check("T13", roles.contains(c), "a colour outside the roles: " + Integer.toHexString(c));
                        }
                    }
                    check("T13", arts == 1, arts + " art views in a screen, want 1");
                }
            }
            Pattern literal = Pattern.compile("0[xX][0-9a-fA-F]{6,8}|Color\\.|\"#[0-9a-fA-F]{3,8}\"");
            for (String name : new String[] { "GateHelpScreen", "GateHelpTileGrid", "GateHelpArtView" }) {
                check("T13", !literal.matcher(source(name)).find(), name + " holds a colour literal");
            }
        });
    }

    // --- T14: labels

    private static void labels() {
        run("T14", () -> {
            for (GatePalette p : new GatePalette[] { GatePalette.DARK, GatePalette.LIGHT }) {
                for (View root : trees(p)) {
                    Set<String> seen = new HashSet<>();
                    int clickable = 0;
                    for (View v : walk(root)) {
                        String d = v.getContentDescription() == null ? "" : v.getContentDescription().toString();
                        if (v.isClickable()) {
                            clickable++;
                            String shown = v instanceof TextView ? ((TextView) v).getText().toString() : "a tile or card";
                            check("T14", !d.trim().isEmpty(), "the control \"" + shown + "\" has no description");
                        }
                        if (v instanceof GateHelpArtView) check("T14", !d.trim().isEmpty(), "an art view has no description");
                        if (!d.isEmpty()) check("T14", seen.add(d), "the description \"" + d + "\" is on two views");
                    }
                    check("T14", clickable >= 2, "a screen has " + clickable + " controls");
                }
            }
            View home = GateHelpScreen.home(C, GatePalette.DARK, new RecNav());
            GateHelpTileGrid grid = grids(walk(home)).get(0);
            for (int r = 0; r < grid.getChildCount(); r++) {
                ViewGroup row = (ViewGroup) grid.getChildAt(r);
                for (int c = 0; c < row.getChildCount(); c++) {
                    ViewGroup tile = (ViewGroup) row.getChildAt(c);
                    String want = GateHelpHome.tileDescription(r * 3 + c);
                    check("T14", tile.getContentDescription() != null && want.contentEquals(tile.getContentDescription()),
                            "tile " + (r * 3 + c) + " is labelled " + tile.getContentDescription());
                    check("T14", want.startsWith(GateHelpHome.TILES[r * 3 + c]), "a tile's description omits its label");
                    for (int k = 0; k < tile.getChildCount(); k++) {
                        check("T14", tile.getChildAt(k).getImportantForAccessibility() == View.IMPORTANT_FOR_ACCESSIBILITY_NO,
                                "TalkBack reads a part of tile " + (r * 3 + c) + " twice");
                    }
                }
            }
        });
    }

    // --- T15, T16, T17: source checks

    private static String read(File f) throws Exception {
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    private static String stripComments(String s) {
        StringBuilder out = new StringBuilder();
        for (String line : s.split("\n")) {
            String t = line.trim();
            if (t.startsWith("*") || t.startsWith("/*")) continue;
            int c = line.indexOf("//");
            out.append(c < 0 ? line : line.substring(0, c)).append('\n');
        }
        return out.toString();
    }

    private static String source(String cls) throws Exception {
        return stripComments(read(new File(System.getProperty("gatehelp.src"), cls + ".java")));
    }

    private static String method(String all, String signature) {
        int a = all.indexOf(signature);
        if (a < 0) return "";
        int b = all.indexOf("\n    }\n", a);
        return b < 0 ? "" : all.substring(a, b);
    }

    private static void sourceChecks() {
        run("T15", () -> {
            String[] refused = { "startActivity", "Intent", "WebView", "Uri.", "getSharedPreferences", "DaemonSocket",
                "sendDaemon", "profileName", "Bitmap", "R.raw" };
            for (String name : new String[] { "GateHelpScreen", "GateHelpTileGrid", "GateHelpArtView", "GateHelpHome",
                "GateHelpArt" }) {
                String s = source(name);
                for (String r : refused) check("T15", !s.contains(r), name + " holds " + r);
            }
        });
        run("T16", () -> {
            String grid = source("GateHelpTileGrid");
            int a = grid.indexOf("ICONS = {");
            List<String> icons = new ArrayList<>();
            Matcher m = Pattern.compile("R\\.drawable\\.(\\w+)").matcher(a < 0 ? "" : grid.substring(a, grid.indexOf("}", a)));
            while (m.find()) icons.add(m.group(1));
            check("T16", icons.equals(Arrays.asList(GateHelpHome.TILE_ICONS)), "ICONS " + icons + " is not TILE_ICONS "
                    + Arrays.toString(GateHelpHome.TILE_ICONS));
            check("T16", GateHelpHome.TILE_ICONS.length == 6, "not six tile icons");
            check("T16", source("GateHelpScreen").contains("R.drawable.ic_help_key"), "the Forgot card has no ic_help_key");
            File res = new File(System.getProperty("gatehelp.res"));
            List<String> names = new ArrayList<>(Arrays.asList(GateHelpHome.TILE_ICONS));
            names.add("ic_help_key");
            for (String n : names) {
                File f = new File(res, "drawable/" + n + ".xml");
                check("T16", f.isFile(), "no " + f);
                if (!f.isFile()) continue;
                String x = read(f);
                check("T16", x.contains("<vector") && !x.contains("<bitmap"), n + " is not a vector");
                Field id = R.drawable.class.getDeclaredField(n);
                check("T16", id.getInt(null) > 0, n + " has no id");
            }
            GateHelpTileGrid g = grids(walk(GateHelpScreen.home(C, GatePalette.DARK, new RecNav()))).get(0);
            for (int r = 0; r < 2; r++) {
                for (int c = 0; c < 3; c++) {
                    int want = R.drawable.class.getDeclaredField(GateHelpHome.TILE_ICONS[r * 3 + c]).getInt(null);
                    int got = 0;
                    for (View v : walk(((ViewGroup) g.getChildAt(r)).getChildAt(c))) {
                        if (v instanceof ImageView) got = ((ImageView) v).imageResource();
                    }
                    check("T16", got == want, "tile " + (r * 3 + c) + " shows icon id " + got + ", want " + want);
                }
            }
            for (File f : walkFiles(res)) {
                String n = f.getName();
                check("T16", !(n.startsWith("ic_help_") && !n.endsWith(".xml")), f + " is not a vector");
            }
        });
        run("T17", () -> {
            String all = stripComments(read(new File(System.getProperty("gatehelp.chooser"))));
            String show = method(all, "private void showGateHelp()");
            String nav = method(all, "private GateHelpScreen.Nav gateHelpNav()");
            String page = method(all, "private void showGateHelpPage(");
            for (String k : new String[] { "GateHelpScreen.home(", "GatePalette.active()", "gateHelpNav()" }) {
                check("T17", show.contains(k), "showGateHelp has no " + k);
            }
            check("T17", !show.contains("AlertDialog"), "showGateHelp still opens a dialog");
            for (String k : new String[] { "setContentView(v)", "setContentView(gateView)", "GateHelpHome.tileTitle(",
                "GateHelpHome.tileBody(", "GateHelpHome.tileAlso(", "GateHelpHome.forgotBody()" }) {
                check("T17", nav.contains(k), "gateHelpNav has no " + k);
            }
            for (String k : new String[] { "GateHelpPages.moreLine()", "GateHelpHome.BACK", ".setNeutralButton(" }) {
                check("T17", page.contains(k), "showGateHelpPage has no " + k);
            }
            check("T17", all.contains("helpIcon.setOnClickListener(v -> showGateHelp());"), "the ? does not open showGateHelp");
        });
    }

    private static List<File> walkFiles(File dir) {
        List<File> out = new ArrayList<>();
        File[] kids = dir.listFiles();
        if (kids == null) return out;
        for (File f : kids) {
            if (f.isDirectory()) out.addAll(walkFiles(f));
            else out.add(f);
        }
        return out;
    }

    public static void main(String[] args) {
        structure();
        mapping();
        intro();
        b4();
        palettes();
        labels();
        sourceChecks();
        if (fails > 0) {
            System.out.println(fails + " case(s) failed");
            System.exit(1);
        }
        System.out.println("GateHelpComboCases: all cases pass");
    }
}
