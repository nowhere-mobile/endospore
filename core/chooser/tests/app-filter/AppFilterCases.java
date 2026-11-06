package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;

// NWP-20261016-48: the cases for AppFilter -- the Your apps search (fold, terms, key, matches), the reorder pause, the
// count line under the field, the A to Z order of the rows after the kept block, and (NWP-20261111-13) the rows with no
// launcher icon and their picker's modes. Package names and labels are
// made up or public app names; nothing here is a real profile.
public final class AppFilterCases {
    static int fails = 0, runs = 0;

    static void eq(String name, Object want, Object got) {
        runs++;
        if (!String.valueOf(want).equals(String.valueOf(got))) {
            fails++;
            System.out.println("FAIL " + name + "\n     want: " + show(want) + "\n     got:  " + show(got));
        }
    }

    static String show(Object o) { return String.valueOf(o).replace("\t", "\\t").replace("\n", "\\n"); }

    static List<String> l(String... s) { return Arrays.asList(s); }

    /** An installed row as the list thread builds it for AppFilter.launcherless. */
    static String[] row(String pkg, boolean sys, boolean upd, boolean src) {
        return new String[] { pkg, sys ? "1" : "0", upd ? "1" : "0", src ? "1" : "0" };
    }

    static String deep(List<String[]> rows) { return Arrays.deepToString(rows.toArray()); }

    /** Whether query q finds the row (label, pkg), through the same three calls ProfileActivity makes. */
    static boolean finds(String q, String label, String pkg) {
        return AppFilter.matches(AppFilter.terms(q), AppFilter.key(label, pkg));
    }

    public static void main(String[] a) {
        final String YT = "com.google.android.youtube";

        // ---- an empty search matches every row ----
        eq("terms: an empty query has none", 0, AppFilter.terms("").length);
        eq("terms: a blank query has none", 0, AppFilter.terms("  \t ").length);
        eq("terms: a null query has none", 0, AppFilter.terms(null).length);
        eq("matches: no terms matches a row", true, finds("", "YouTube", YT));
        eq("matches: a blank query matches a row", true, finds("   ", "YouTube", YT));
        eq("matches: no terms matches even a row with no key", true, AppFilter.matches(new String[0], null));
        eq("matches: a term never matches a row with no key", false, AppFilter.matches(AppFilter.terms("a"), null));

        // ---- case ----
        eq("case: lower-case query, mixed-case label", true, finds("youtube", "YouTube", YT));
        eq("case: upper-case query", true, finds("YOUTUBE", "YouTube", "x.y"));
        eq("case: a different word does not match", false, finds("vimeo", "YouTube", YT));

        // ---- accents, on either side ----
        eq("accents: plain query, accented label", true, finds("pokemon", "Pok\u00e9mon GO", "com.nianticlabs.pokemongo"));
        eq("accents: accented query, plain label", true, finds("pok\u00e9mon", "Pokemon Sleep", "x.sleep"));
        eq("accents: a decomposed accent in the label", true, finds("pokemon", "Poke\u0301mon", "x.p"));
        eq("accents: cafe matches Caf\u00e9", true, finds("cafe", "Caf\u00e9 Racer", "x.cafe"));
        eq("accents: n matches \u00f1", true, finds("espana", "Espa\u00f1a TV", "x.tv"));

        // ---- the letters NFKD leaves whole, each mapped ----
        eq("letters: \u00f8", true, finds("oresund", "\u00d8resund Bridge", "x.bridge"));
        eq("letters: \u0142 (and \u00f3, \u017a)", true, finds("lodz", "\u0141\u00f3d\u017a Transit", "x.transit"));
        eq("letters: \u00df", true, finds("strasse", "Stra\u00dfe", "x.street"));
        eq("letters: capital \u1e9e", true, finds("strasse", "STRA\u1e9eE", "x.street"));
        eq("letters: \u00e6", true, finds("aeble", "\u00c6ble", "x.apple"));
        eq("letters: \u0153", true, finds("oeuvre", "\u0152uvre", "x.art"));
        eq("letters: \u0111", true, finds("dakovo", "\u0110akovo", "x.town"));
        eq("letters: the dotless \u0131", true, finds("kirmizi", "K\u0131rm\u0131z\u0131", "x.red"));
        eq("fold: the mapped letters", "ss ae oe o l d i", AppFilter.fold("\u00df \u00c6 \u0152 \u00d8 \u0141 \u0110 \u0131"));

        // ---- Turkish default locale: no dotless-i fold ----
        Locale was = Locale.getDefault();
        Locale.setDefault(new Locale("tr", "TR"));
        try {
            eq("turkish: instagram finds INSTAGRAM", true, finds("instagram", "INSTAGRAM", "com.instagram.android"));
            eq("turkish: INSTAGRAM finds Instagram", true, finds("INSTAGRAM", "Instagram", "com.instagram.android"));
            eq("turkish: istanbul finds \u0130stanbul", true, finds("istanbul", "\u0130stanbul Kart", "x.kart"));
            eq("turkish: fold is the same as under any locale", "instagram", AppFilter.fold("INSTAGRAM"));
        } finally {
            Locale.setDefault(was);
        }

        // ---- compatibility forms (NFKD, not NFD) ----
        eq("width: full-width letters", true, finds("youtube", "\uff39\uff4f\uff55\uff34\uff55\uff42\uff45", "x.fw"));
        eq("ligature: \ufb01", true, finds("file", "\ufb01le manager", "x.files"));
        eq("fold: a full-width word folds to its plain letters", "youtube", AppFilter.fold("\uff39\uff4f\uff55\uff34\uff55\uff42\uff45"));

        // ---- substring, not prefix ----
        eq("substring: tube finds YouTube", true, finds("tube", "YouTube", YT));
        eq("substring: ube finds YouTube", true, finds("ube", "YouTube", "x.y"));

        // ---- the package is searched too ----
        eq("package: com.amazon", true, finds("com.amazon", "Amazon Shopping", "com.amazon.mShop.android.shopping"));
        eq("package: mshop (case-free)", true, finds("mshop", "Amazon Shopping", "com.amazon.mShop.android.shopping"));
        eq("package: a fragment found only in the package", true, finds("nianticlabs", "Pok\u00e9mon GO", "com.nianticlabs.pokemongo"));

        // ---- every term must match, in any order ----
        final String MAPS = "com.google.android.apps.maps";
        eq("terms: goo maps", true, finds("goo maps", "Maps", MAPS));
        eq("terms: maps goo", true, finds("maps goo", "Maps", MAPS));
        eq("terms: goo zzz does not", false, finds("goo zzz", "Maps", MAPS));
        eq("terms: zzz maps does not", false, finds("zzz maps", "Maps", MAPS));
        eq("terms: one in the label, one in the package", true, finds("maps com.google", "Maps", MAPS));
        eq("terms: two words of a label", true, finds("shopping amazon", "Amazon Shopping", "x.s"));

        // ---- no match runs from the label into the package ----
        eq("straddle: rcom does not match Bar + com.foo", false, finds("rcom", "Bar", "com.foo"));
        eq("straddle: bar com does", true, finds("bar com", "Bar", "com.foo"));
        eq("key: label and package joined by a line break", "my bank\ncom.bank.app", AppFilter.key("My  Bank", "com.bank.app"));
        eq("key: a null label", "\nx.y", AppFilter.key(null, "x.y"));

        // ---- white space ----
        eq("fold: runs of white space are one space, none at the ends", "google maps", AppFilter.fold("  Google \t  Maps \n"));
        eq("fold: a no-break space is a space", "google maps", AppFilter.fold("Google\u00a0Maps"));
        eq("fold: null is empty", "", AppFilter.fold(null));
        eq("terms: split at the collapsed spaces", "[goo, maps]", Arrays.toString(AppFilter.terms("  goo   maps ")));
        eq("terms: a query is folded", "[pokemon, go]", Arrays.toString(AppFilter.terms("POK\u00c9MON  GO")));

        // ---- the reorder pause ----
        eq("reorderable: kept, no search", true, AppFilter.reorderable(true, false));
        eq("reorderable: kept, searching", false, AppFilter.reorderable(true, true));
        eq("reorderable: not kept, no search", false, AppFilter.reorderable(false, false));
        eq("reorderable: not kept, searching", false, AppFilter.reorderable(false, true));

        // ---- the count line ----
        eq("count: hidden with no search", null, AppFilter.countLine("", 52, 52, true));
        eq("count: hidden with a blank search", null, AppFilter.countLine("   ", 52, 52, true));
        eq("count: hidden while the list is loading", null, AppFilter.countLine("goo", 0, 0, false));
        eq("count: nothing matches, and bundled apps are not listed",
                "No app matches \u201czzz\u201d. Apps that came with the phone, and Google Play services, are not listed here.",
                AppFilter.countLine("  zzz ", 0, 52, false));
        eq("count: one of one", "1 of 1 app", AppFilter.countLine("goo", 1, 1, false));
        eq("count: three of 52", "3 of 52 apps", AppFilter.countLine("goo", 3, 52, false));
        eq("count: a kept row among the matches says to clear the search to reorder",
                "3 of 52 apps \u00b7 clear the search to reorder", AppFilter.countLine("goo", 3, 52, true));
        eq("count: no kept row among the matches, no reorder line", "52 of 52 apps", AppFilter.countLine("a", 52, 52, false));

        // ---- the order: the kept block as given, every other row A to Z ----
        Map<String, String> lab = new HashMap<>();
        lab.put("o.zoom", "Zoom");
        lab.put("o.amazon", "amazon");
        lab.put("o.apfel", "\u00c4pfel");
        lab.put("o.bank", "Bank");
        LinkedHashSet<String> kept = new LinkedHashSet<>(l("k.zulu", "k.alpha"));
        eq("order: the kept block keeps its order, the rest A to Z ignoring case and accents",
                "[k.zulu, k.alpha, o.amazon, o.apfel, o.bank, o.zoom]",
                AppFilter.otherRowsAtoZ(l("k.zulu", "k.alpha", "o.zoom", "o.bank", "o.amazon", "o.apfel"), kept, lab));
        eq("order: no kept rows, all A to Z", "[o.amazon, o.apfel, o.bank, o.zoom]",
                AppFilter.otherRowsAtoZ(l("o.zoom", "o.bank", "o.amazon", "o.apfel"), new HashSet<String>(), lab));
        eq("order: only kept rows, unchanged", "[k.zulu, k.alpha]",
                AppFilter.otherRowsAtoZ(l("k.zulu", "k.alpha"), kept, lab));
        Map<String, String> same = new HashMap<>();
        same.put("b.notes", "Notes");
        same.put("a.notes", "Notes");
        eq("order: the same label, by package", "[a.notes, b.notes]",
                AppFilter.otherRowsAtoZ(l("b.notes", "a.notes"), new HashSet<String>(), same));
        Map<String, String> cased = new HashMap<>();
        cased.put("a.lower", "notes");
        cased.put("b.upper", "Notes");
        eq("order: labels that fold the same, by the label as shown", "[b.upper, a.lower]",
                AppFilter.otherRowsAtoZ(l("a.lower", "b.upper"), new HashSet<String>(), cased));
        Map<String, String> some = new HashMap<>();
        some.put("x.alpha", "Alpha");
        some.put("e.empty", "");
        eq("order: a row with no label, or an empty one, sorts by its package, among the labels",
                "[x.alpha, e.empty, z.nolabel]",
                AppFilter.otherRowsAtoZ(l("z.nolabel", "x.alpha", "e.empty"), new HashSet<String>(), some));
        eq("order: no labels at all, by package", "[a.b, c.d]",
                AppFilter.otherRowsAtoZ(l("c.d", "a.b"), new HashSet<String>(), null));
        eq("order: no row is added or dropped", 6,
                AppFilter.otherRowsAtoZ(l("k.zulu", "o.zoom", "k.alpha", "o.bank", "o.amazon", "o.apfel"), kept, lab).size());
        eq("order: a kept row found late still leads, in the order given", "[k.zulu, k.alpha, o.bank, o.zoom]",
                AppFilter.otherRowsAtoZ(l("o.zoom", "k.zulu", "o.bank", "k.alpha"), kept, lab));

        // ---- L1: the rows with no launcher icon (NWP-20261111-13, Q140) ----
        final String SELF = "com.nowhere.chooser", GMS = "com.google.android.gms", GSF = "com.google.android.gsf";
        List<String[]> inst = new ArrayList<>();
        inst.add(row("x.keyboard", false, false, true));
        inst.add(row(GMS, false, false, true));
        inst.add(row("x.iconpack", false, false, true));
        inst.add(row(GSF, false, false, true));
        inst.add(row(SELF, false, false, true));
        inst.add(row("s.bundled", true, false, true));
        inst.add(row("s.updated", false, true, true));
        inst.add(row("x.noapk", false, false, false));
        inst.add(row("a.widget", false, false, true));
        inst.add(row("l.launcher", false, false, true));
        LinkedHashSet<String> seenL = new LinkedHashSet<>(l("l.launcher"));
        eq("launcherless: a keyboard, an icon pack and a widget app are listed, in the order installed; gms, gsf, the "
                + "chooser, a system app, an updated system app, an app with no APK and an app the launcher pass found are not",
                "[x.keyboard, x.iconpack, a.widget]", AppFilter.launcherless(inst, seenL, SELF, GMS, GSF));
        eq("launcherless: seen is read, not changed", "[l.launcher]", seenL);
        eq("launcherless: a keyboard already seen is not listed again", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row("x.keyboard", false, false, true)),
                        new HashSet<String>(l("x.keyboard")), SELF, GMS, GSF));
        eq("launcherless: a keyboard alone is listed", "[x.keyboard]",
                AppFilter.launcherless(java.util.Collections.singletonList(row("x.keyboard", false, false, true)),
                        new HashSet<String>(), SELF, GMS, GSF));
        eq("launcherless: gms alone is not listed", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row(GMS, false, false, true)),
                        new HashSet<String>(), SELF, GMS, GSF));
        eq("launcherless: gsf alone is not listed", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row(GSF, false, false, true)),
                        new HashSet<String>(), SELF, GMS, GSF));
        eq("launcherless: the chooser itself is not listed", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row(SELF, false, false, true)),
                        new HashSet<String>(), SELF, GMS, GSF));
        eq("launcherless: a system app is not listed", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row("s.bundled", true, false, true)),
                        new HashSet<String>(), SELF, GMS, GSF));
        eq("launcherless: an updated system app is not listed", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row("s.updated", false, true, true)),
                        new HashSet<String>(), SELF, GMS, GSF));
        eq("launcherless: an app with no source dir is not listed", "[]",
                AppFilter.launcherless(java.util.Collections.singletonList(row("x.noapk", false, false, false)),
                        new HashSet<String>(), SELF, GMS, GSF));
        List<String[]> rev = new ArrayList<>();
        rev.add(row("z.three", false, false, true));
        rev.add(row("m.two", false, false, true));
        rev.add(row("a.one", false, false, true));
        eq("launcherless: the order is the order installed, not sorted", "[z.three, m.two, a.one]",
                AppFilter.launcherless(rev, new HashSet<String>(), SELF, GMS, GSF));

        // ---- L2: the keep-mode picker's rows (the four are showKeepModeDialog's literals before NWP-20261111-13) ----
        eq("keepModes: with an icon, the four modes in the picker's order",
                "[[Off — removed at logoff, null], "
                + "[On-demand — icon only, downloads when you tap it, ondemand], "
                + "[Auto — downloads by itself after you sign in, auto], "
                + "[Keep installed — ready to use the moment you sign in, installed]]",
                deep(AppFilter.keepModes(true)));
        eq("keepModes: with no icon, exactly Off and Keep installed",
                "[[Off — removed at logoff, null], [Keep installed — ready to use the moment you sign in, installed]]",
                deep(AppFilter.keepModes(false)));
        boolean deferred = false;
        for (String[] m : AppFilter.keepModes(false)) if ("ondemand".equals(m[1]) || "auto".equals(m[1])) deferred = true;
        eq("keepModes: with no icon, neither On-demand nor Auto", false, deferred);

        // ---- L3: a launcher-less row that is not kept goes to the A-to-Z part ----
        Map<String, String> nl = new HashMap<>();
        nl.put("x.keyboard", "Gboard");
        nl.put("o.zoom", "Zoom");
        eq("order: a launcher-less row not kept is listed A to Z after the kept block", "[k.one, x.keyboard, o.zoom]",
                AppFilter.otherRowsAtoZ(l("k.one", "o.zoom", "x.keyboard"), new LinkedHashSet<String>(l("k.one")), nl));

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
