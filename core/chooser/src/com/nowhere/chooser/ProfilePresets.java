package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * NWP-20261119-12: the profile presets table as code. Five named postures (Unshielded, Standard, Hardened, Isolated,
 * Zero, most convenient to most private), each giving a value for every row of the approved table, plus Custom.
 *
 * Every row, option and value is section (b) of docs/profile-presets.md, approved 2026-10-31 (docs/product-decisions.md,
 * entry "the profile presets table is approved ...", Part A): no Backups-while-apps-set-up row (A3), and no preset uses
 * Essential for Offline media (A4). The saved Custom and its transitions are the 2026-10-26 entry "a profile's Custom
 * preset is saved ...". core/vendor-common/bin/test-profile-presets-java.sh diffs the rows against that table and pins
 * Standard to the code's defaults, so a value copied wrong fails CI (Q080: "a test that fails when a qualifying
 * setting has no value in every preset").
 *
 * Values are in the storage vocabulary the screens write: idle is the idle= minutes in nowhere-prefs; holdlock is the
 * holdlock= value (empty = On, "0" = Off); holdaudio is the holdaudio= value, the same way; wipe is the WipeChoice
 * index, from which the picker writes wipe= and wipesaved=; media.default and apps.default.* are the nowhere-config values; reclaim is the nowhere-reclaim
 * milliseconds. Turning a profile's files into a current map (absent keys as their defaults) is the caller's job.
 *
 * A new profile starts as Standard, with no saved Custom. A throwaway session hides the picker (A7). The saved Custom
 * file's name, the picker, the preview with its consent links and the replace prompt belong to the picker slice.
 * Pure java.util so a javac suite can compile it off the build host.
 */
final class ProfilePresets {
    private ProfilePresets() {}

    static final String UNSHIELDED = "Unshielded";
    static final String STANDARD = "Standard";
    static final String HARDENED = "Hardened";
    static final String ISOLATED = "Isolated";
    static final String ZERO = "Zero";
    static final String CUSTOM = "Custom";

    /** The five presets in table order. Custom is not one of them. */
    static final List<String> PRESETS =
            Collections.unmodifiableList(Arrays.asList(UNSHIELDED, STANDARD, HARDENED, ISOLATED, ZERO));

    /** The decided ask before a hand change on a preset replaces a different saved Custom. */
    static final String REPLACE_ASK = "This replaces your saved Custom settings. Replace / Cancel.";

    /** One table row: its key, the doc's "Screen > label", its options and each preset's value. */
    static final class Row {
        final String key;
        final String label;
        final List<String> optionLabels;
        final List<String> optionValues;
        /** The stored value in each preset, in PRESETS order. */
        final List<String> presetValues;

        Row(String key, String label, String[] optionLabels, String[] optionValues, String... presetValues) {
            if (optionLabels.length != optionValues.length || optionLabels.length < 2)
                throw new IllegalStateException(key + ": option labels and values differ in size");
            if (presetValues.length != PRESETS.size())
                throw new IllegalStateException(key + ": " + presetValues.length + " preset values, want " + PRESETS.size());
            List<String> vals = Arrays.asList(optionValues);
            for (String v : presetValues)
                if (!vals.contains(v)) throw new IllegalStateException(key + ": preset value \"" + v + "\" is not an option");
            this.key = key;
            this.label = label;
            this.optionLabels = Collections.unmodifiableList(Arrays.asList(optionLabels.clone()));
            this.optionValues = Collections.unmodifiableList(Arrays.asList(optionValues.clone()));
            this.presetValues = Collections.unmodifiableList(Arrays.asList(presetValues.clone()));
        }

        /** The option label of a stored value, or null when the value is not an option. */
        String labelOf(String value) {
            int i = optionValues.indexOf(value);
            return i < 0 ? null : optionLabels.get(i);
        }
    }

    private static final String[] APPDEF_LABELS = { "Off", "On-demand", "Auto", "Installed" };
    private static final String[] APPDEF_VALUES = { "off", "ondemand", "auto", "installed" };
    private static final String APPDEF_HEAD = "Preferences > Configuration > Your apps > ";
    private static final String APPDEF_TAIL = " (\"What a newly installed app starts as\")";

    /** The table's rows, in the doc's order. */
    static final List<Row> ROWS = Collections.unmodifiableList(Arrays.asList(
            new Row("idle", "Security > Auto standby when idle",
                    new String[]{ "After 5 minutes", "After 15 minutes", "After 30 minutes", "After 1 hour", "Never" },
                    new String[]{ "5", "15", "30", "60", "0" },
                    "0", "15", "5", "5", "5"),
            new Row("holdlock",
                    "Security > Auto standby when idle > \"Before standby, wait for:\" > \"app installs\"",
                    new String[]{ "On (checked)", "Off (unchecked)" },
                    new String[]{ "", "0" },
                    "", "", "0", "0", "0"),
            new Row("holdaudio",
                    "Security > Auto standby when idle > \"Before standby, wait for:\" > \"audio playing\"",
                    new String[]{ "On (checked)", "Off (unchecked)" },
                    new String[]{ "", "0" },
                    "", "", "0", "0", "0"),
            new Row("wipe", "Security > Auto-wipe when left locked (dialog \"Erase a locked session after\")",
                    new String[]{ "Right away, once saved", "After 1 hour", "After 6 hours", "After 12 hours",
                            "After 1 day", "Only on power-off" },
                    new String[]{ "0", "1", "2", "3", "4", "5" },
                    "5", "3", "2", "1", "0"),
            new Row("media.default",
                    "Preferences > Configuration > Offline media (\"What a new app's media starts as\")",
                    new String[]{ "Auto", "Essential", "On-demand" },
                    new String[]{ "prefetch", "essential", "ondemand" },
                    "prefetch", "ondemand", "ondemand", "ondemand", "ondemand"),
            new Row("reclaim", "Preferences > Your apps > Re-archive idle apps",
                    new String[]{ "Never", "1 day", "3 days", "1 week" },
                    new String[]{ "0", "86400000", "259200000", "604800000" },
                    "0", "259200000", "86400000", "86400000", "86400000"),
            new Row("apps.default.napps", APPDEF_HEAD + "nApps" + APPDEF_TAIL, APPDEF_LABELS, APPDEF_VALUES,
                    "auto", "auto", "ondemand", "ondemand", "off"),
            new Row("apps.default.play", APPDEF_HEAD + "Play Store" + APPDEF_TAIL, APPDEF_LABELS, APPDEF_VALUES,
                    "auto", "off", "off", "off", "off"),
            new Row("apps.default.aurora", APPDEF_HEAD + "Aurora Store" + APPDEF_TAIL, APPDEF_LABELS, APPDEF_VALUES,
                    "auto", "off", "off", "off", "off"),
            new Row("apps.default.gos", APPDEF_HEAD + "GrapheneOS App Store" + APPDEF_TAIL, APPDEF_LABELS,
                    APPDEF_VALUES,
                    "auto", "off", "off", "off", "off"),
            new Row("apps.default.other", APPDEF_HEAD + "Everything else" + APPDEF_TAIL, APPDEF_LABELS,
                    APPDEF_VALUES,
                    "ondemand", "off", "off", "off", "off")));

    /** The row with this key, or null. */
    static Row row(String key) {
        for (Row r : ROWS) if (r.key.equals(key)) return r;
        return null;
    }

    /** The option label of a stored value of a row, or null when the key or the value is unknown. */
    static String optionLabel(String key, String value) {
        Row r = row(key);
        return r == null ? null : r.labelOf(value);
    }

    /** A preset's value for every row, in row order; null for Custom, null or an unknown name. */
    static Map<String, String> valuesOf(String preset) {
        int p = preset == null ? -1 : PRESETS.indexOf(preset);
        if (p < 0) return null;
        Map<String, String> m = new LinkedHashMap<>();
        for (Row r : ROWS) m.put(r.key, r.presetValues.get(p));
        return Collections.unmodifiableMap(m);
    }

    /** The preset whose every row equals current, else Custom. A missing key never matches; extra keys are ignored. */
    static String match(Map<String, String> current) {
        if (current == null) return CUSTOM;
        for (String p : PRESETS) if (matches(p, current)) return p;
        return CUSTOM;
    }

    private static boolean matches(String preset, Map<String, String> current) {
        for (Map.Entry<String, String> e : valuesOf(preset).entrySet())
            if (!e.getValue().equals(current.get(e.getKey()))) return false;
        return true;
    }

    /** One line per row that target changes, in row order: "label: from -> to", in option labels. A row target lacks
     *  is no change. A current value that is not an option shows as stored; a missing one shows as "not set". */
    static List<String> previewLines(Map<String, String> current, Map<String, String> target) {
        if (target == null) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        for (Row r : ROWS) {
            String to = target.get(r.key);
            if (to == null) continue;
            String from = current == null ? null : current.get(r.key);
            if (to.equals(from)) continue;
            out.add(r.label + ": " + shown(r, from) + " → " + shown(r, to));
        }
        return Collections.unmodifiableList(out);
    }

    private static String shown(Row r, String value) {
        if (value == null) return "not set";
        String l = r.labelOf(value);
        return l == null ? value : l;
    }

    /** The table's rows of m, in row order, or null when a row is missing or holds a value that is not an option. */
    static Map<String, String> tableValues(Map<String, String> m) {
        if (m == null) return null;
        Map<String, String> out = new LinkedHashMap<>();
        for (Row r : ROWS) {
            String v = m.get(r.key);
            if (v == null || !r.optionValues.contains(v)) return null;
            out.put(r.key, v);
        }
        return Collections.unmodifiableMap(out);
    }

    /** The saved Custom as text, one key=value per line in row order; null when m is not complete. Extra keys drop. */
    static String formatCustom(Map<String, String> m) {
        Map<String, String> t = tableValues(m);
        if (t == null) return null;
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : t.entrySet()) sb.append(e.getKey()).append('=').append(e.getValue()).append('\n');
        return sb.toString();
    }

    /** A saved Custom read back from formatCustom's text. Blank and # lines are skipped and unknown keys dropped. A
     *  missing row, a value that is not an option, a repeated key or a line with no '=' gives null, never a part. */
    static Map<String, String> parseCustom(String text) {
        if (text == null) return null;
        Map<String, String> seen = new LinkedHashMap<>();
        for (String ln : text.split("\n", -1)) {
            ln = ln.trim();
            if (ln.isEmpty() || ln.startsWith("#")) continue;
            int eq = ln.indexOf('=');
            if (eq < 0) return null;
            String k = ln.substring(0, eq).trim();
            if (row(k) == null) continue;
            if (seen.containsKey(k)) return null;
            seen.put(k, ln.substring(eq + 1).trim());
        }
        return tableValues(seen);
    }

    /** What choose() gives: the values to apply (null = nothing to apply) and the saved Custom to keep (null = none). */
    static final class Choice {
        final Map<String, String> valuesToApply;
        final Map<String, String> savedCustomAfter;

        Choice(Map<String, String> valuesToApply, Map<String, String> savedCustomAfter) {
            this.valuesToApply = valuesToApply;
            this.savedCustomAfter = savedCustomAfter;
        }
    }

    /** The picker moves from fromShown to toPreset. Leaving Custom for a preset saves current first (an incomplete
     *  current keeps the old saved Custom); choosing Custom restores savedCustom, or applies nothing when none is
     *  saved; an unknown toPreset applies nothing. */
    static Choice choose(String fromShown, String toPreset, Map<String, String> current, Map<String, String> savedCustom) {
        if (CUSTOM.equals(toPreset)) return new Choice(savedCustom, savedCustom);
        Map<String, String> apply = valuesOf(toPreset);
        if (apply == null) return new Choice(null, savedCustom);
        Map<String, String> saved = savedCustom;
        if (CUSTOM.equals(fromShown)) {
            Map<String, String> now = tableValues(current);
            if (now != null) saved = now;
        }
        return new Choice(apply, saved);
    }

    /** What handChange() gives. When askReplace is true the caller shows REPLACE_ASK and changes nothing: Cancel keeps
     *  savedCustomAfter and drops the hand change; Replace writes it and keeps savedCustomIfReplaced. */
    static final class HandChange {
        final boolean askReplace;
        final Map<String, String> savedCustomAfter;
        final Map<String, String> savedCustomIfReplaced;

        HandChange(boolean askReplace, Map<String, String> savedCustomAfter, Map<String, String> savedCustomIfReplaced) {
            this.askReplace = askReplace;
            this.savedCustomAfter = savedCustomAfter;
            this.savedCustomIfReplaced = savedCustomIfReplaced;
        }
    }

    /** A hand change made while shownBefore was shown leaves the values at after. On Custom the saved Custom becomes
     *  after; on a preset (or an unknown name) it is saved without asking when none is saved or the saved one equals
     *  after, and asks first when the saved one differs. An incomplete after changes nothing. */
    static HandChange handChange(String shownBefore, Map<String, String> after, Map<String, String> savedCustom) {
        Map<String, String> now = tableValues(after);
        if (now == null) return new HandChange(false, savedCustom, null);
        if (CUSTOM.equals(shownBefore) || savedCustom == null || now.equals(tableValues(savedCustom)))
            return new HandChange(false, now, null);
        return new HandChange(true, savedCustom, now);
    }
}
