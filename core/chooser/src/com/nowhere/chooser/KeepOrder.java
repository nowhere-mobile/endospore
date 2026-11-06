package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;

/**
 * NWP-20261012-06: the order of "Your apps" and the per-app "Wake for notifications" choice, as pure text rules
 * (docs/product-decisions.md, 2026-10-12).
 *
 * ORDER. Kept apps in Your apps can be dragged into order, and that order is the order the automatic install works
 * through. It is the line order of nowhere-appkeep, which seals and roams with the profile, so the order is kept with
 * the profile and no second file can disagree with it. "Download first" (nowhere-appfirst) is retired: the apps it
 * marked move to the top of the keep order once ({@link #reorder} with the marks as the order), then the file goes.
 *
 * WAKE. nowhere-appwake, beside nowhere-appkeep in the chooser's files dir (so it seals and roams the same way),
 * holds the user's explicit choices only, one per line: {@code <pkg>\t<on|off>}. An app with no line follows the
 * messaging rule (UnarchiveService.isMessagingApp). Wake only: nothing here touches battery optimisation.
 *
 * Pure Java, no Android types, so core/chooser/tests/keep-order runs every rule under a plain JDK
 * (core/vendor-common/bin/test-keep-order-java.sh). The file I/O and the locking live in StoreInstaller.
 */
final class KeepOrder {
    private KeepOrder() {}

    static final String WAKE_ON = "on";
    static final String WAKE_OFF = "off";

    // NWP-20261125-26: Your apps' own not-saved words (a failed wake or order write). They belong to this screen, not
    // to SettingsSaveCopy (NOWHERE-1495). They claim nothing: the check or the order goes back to what is stored.
    static final String WAKE_NOT_SAVED = "Couldn't save that — nothing changed. Try again.";
    static final String ORDER_NOT_SAVED = "Couldn't save the new order — nothing changed. Try again.";

    /** The package a keep line names: field 1, as every keep-set reader splits it. */
    static String keyOf(String line) {
        return line.split("\t", 2)[0].trim();
    }

    /** A whole file as text, one '\n' after every line BufferedReader.readLine returns. StoreInstaller reads the
     *  keep-set and nowhere-appwake through this, so the line ends it puts back are what reorder splits on: drop them
     *  and the next drag would write the whole keep-set back as one line. */
    static String readText(java.io.File f) throws java.io.IOException {
        StringBuilder sb = new StringBuilder();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String ln;
            while ((ln = r.readLine()) != null) sb.append(ln).append((char) 10);
        }
        return sb.toString();
    }

    /** The non-blank lines of a file's text, as BufferedReader.readLine would return them. */
    static List<String> lines(String text) {
        List<String> out = new ArrayList<>();
        if (text == null) return out;
        for (String ln : text.split("\r\n|\r|\n", -1)) if (!ln.trim().isEmpty()) out.add(ln);
        return out;
    }

    /**
     * The keep-set text re-emitted in {@code order}: each existing line VERBATIM (its mode and any {@code group:}
     * token untouched -- never round-tripped through the mode parser), the packages {@code order} names first, in that
     * order, then every line it does not name in its old order. A name with no line is ignored; a package with two
     * lines keeps both, together, at its place. Blank lines are dropped, as removeKeepLines drops them. Nothing is ever
     * added or lost: the output holds exactly the input's non-blank lines.
     */
    static String reorder(String text, List<String> order) {
        LinkedHashMap<String, List<String>> byPkg = new LinkedHashMap<>();
        for (String ln : lines(text)) byPkg.computeIfAbsent(keyOf(ln), k -> new ArrayList<>()).add(ln);
        StringBuilder sb = new StringBuilder();
        LinkedHashSet<String> done = new LinkedHashSet<>();
        if (order != null) {
            for (String p : order) {
                if (p == null) continue;
                String k = p.trim();
                List<String> ls = byPkg.get(k);
                if (ls == null || !done.add(k)) continue;
                for (String ln : ls) sb.append(ln).append('\n');
            }
        }
        for (Map.Entry<String, List<String>> e : byPkg.entrySet()) {
            if (done.contains(e.getKey())) continue;
            for (String ln : e.getValue()) sb.append(ln).append('\n');
        }
        return sb.toString();
    }

    /** The "Download first" marks in nowhere-appfirst, in the order they were marked, each once. */
    static List<String> marks(String text) {
        LinkedHashSet<String> s = new LinkedHashSet<>();
        for (String ln : lines(text)) s.add(ln.trim());
        return new ArrayList<>(s);
    }

    /** The Your apps rows with the kept ones first, in keep-set order, then every other row in the order given. */
    static List<String> keptFirst(List<String> rows, Collection<String> keepOrder) {
        LinkedHashSet<String> inRows = new LinkedHashSet<>(rows);
        List<String> out = new ArrayList<>(rows.size());
        LinkedHashSet<String> kept = new LinkedHashSet<>();
        for (String p : keepOrder) if (inRows.contains(p) && kept.add(p)) out.add(p);
        for (String p : rows) if (!kept.contains(p)) out.add(p);
        return out;
    }

    /** nowhere-appwake parsed: pkg -> the user's choice. A malformed line is skipped; a later line wins. */
    static LinkedHashMap<String, Boolean> parseWake(String text) {
        LinkedHashMap<String, Boolean> m = new LinkedHashMap<>();
        for (String ln : lines(text)) {
            String[] f = ln.split("\t", -1);
            if (f.length != 2) continue;
            String pkg = f[0].trim(), v = f[1].trim();
            if (pkg.isEmpty()) continue;
            if (WAKE_ON.equals(v)) { m.remove(pkg); m.put(pkg, Boolean.TRUE); }
            else if (WAKE_OFF.equals(v)) { m.remove(pkg); m.put(pkg, Boolean.FALSE); }
        }
        return m;
    }

    /** nowhere-appwake's text with pkg's choice set to on, every other choice kept. */
    static String setWake(String text, String pkg, boolean on) {
        LinkedHashMap<String, Boolean> m = parseWake(text);
        m.remove(pkg);
        m.put(pkg, on);
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, Boolean> e : m.entrySet())
            sb.append(e.getKey()).append('\t').append(e.getValue() ? WAKE_ON : WAKE_OFF).append('\n');
        return sb.toString();
    }

    /** Whether a restored pkg is woken: the user's choice when there is one, else the messaging rule -- asked only
     *  then, because it is PackageManager work. */
    static boolean wakeFor(Map<String, Boolean> overrides, String pkg, BooleanSupplier messaging) {
        Boolean v = overrides.get(pkg);
        return v != null ? v : messaging.getAsBoolean();
    }
}
