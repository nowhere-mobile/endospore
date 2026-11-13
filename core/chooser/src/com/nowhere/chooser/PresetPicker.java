package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * NWP-20261122-02: the preset picker's pure half. Since NWP-20261126-09 the picker is the Privacy level card on
 * Profile home (ProfileActivity.addPrivacyLevelCard, docs/product-decisions.md 2026-11-03 "the presets picker moves to
 * Profile home, and Store settings moves to Owner settings"): a five-step scale and a dropdown of the five presets of
 * ProfilePresets, each with one line, and Custom when one is saved. This class holds the card's texts and scale, turns
 * the profile's three files into the table's current map, says which writes a pick needs and how many settings it
 * changes, holds the two consent lines each preset shows, and decides what a hand change on a Security or
 * Configuration screen does to the saved Custom.
 *
 * Decisions (docs/product-decisions.md): 2026-10-31 "the profile presets table is approved ..." (a throwaway hides the
 * picker; the preview says which way each link points); 2026-10-26 "a profile's Custom preset is saved ..." (Custom is
 * saved and roams, leaving it saves it, choosing it restores it, a hand change on a preset with a different saved
 * Custom asks REPLACE_ASK); 2026-11-01 "twenty-two answers to harvests 50, 51 and 52 ..." h50 #8 (the Unshielded and
 * Standard link lines). docs/profile-presets.md sections (b), (d) and Custom.
 *
 * A preset never writes the tie or the Location services keys (section (d)): links() only names the screens.
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-preset-picker-java.sh).
 */
final class PresetPicker {
    private PresetPicker() {}

    /** ProfileActivity.PREFS_FILE: idle=, holdlock=, holdaudio=, wipe= and wipesaved=. */
    static final String PREFS_FILE = "nowhere-prefs";
    /** ProfileActivity.CFG_FILE: media.default and apps.default.*. */
    static final String CONFIG_FILE = "nowhere-config";
    /** The file reclaimIdleMs reads and setReclaimIdleMs writes: one line of milliseconds. */
    static final String RECLAIM_FILE = "nowhere-reclaim";
    /** The saved Custom, ProfilePresets.formatCustom's text, beside nowhere-prefs in the chooser's files directory, so
     *  it is sealed and roams with the profile. Absent = no saved Custom. */
    static final String CUSTOM_FILE = "nowhere-preset-custom";
    /** One line: the name the picker last applied. Only "Custom" counts (shown()). */
    static final String LAST_FILE = "nowhere-preset-last";

    /** The Profile home card's title. */
    static final String CARD_TITLE = "Privacy level";
    static final String NO_CUSTOM = "No Custom settings are saved yet.";
    static final String NOTHING_CHANGES = "Nothing changes.";
    static final String APPLY_FAILED = "Couldn't apply every setting.";
    static final String REPLACE = "Replace";
    static final String CANCEL = "Cancel";

    static final String TIE_YES = "Suggested: tie this profile to this phone";
    static final String TIE_NO = "Suggested: don't tie this profile to this phone";
    static final String LOC_ON = "Suggested: Location on";
    static final String LOC_OFF = "Suggested: Location off";

    /** showIdlePicker's `int cur = 15;` (IDLE_LOGOFF_MS) when no idle= is set. */
    static final String IDLE_DEFAULT = "15";
    /** cfg's and cfgStatic's fallbacks: media on-demand, nApps auto, every other store off. */
    static final String MEDIA_DEFAULT = "ondemand";
    static final String NAPPS_DEFAULT = "auto";
    static final String STORE_DEFAULT = "off";
    /** RECLAIM_DEFAULT_MS (RECLAIM_3D), reclaimIdleMs's fallback. */
    static final String RECLAIM_DEFAULT = "259200000";

    /** showConfiguration's Offline media segments, in screen order. */
    static final List<String> MEDIA_SCREEN_VALUES =
            Collections.unmodifiableList(Arrays.asList("essential", "prefetch", "ondemand"));
    /** appDefaultRow's segments, in screen order. */
    static final List<String> APPDEF_SCREEN_VALUES =
            Collections.unmodifiableList(Arrays.asList("off", "ondemand", "auto", "installed"));

    private static final String REPLACE_TAIL = " " + REPLACE + " / " + CANCEL + ".";
    private static final Map<String, List<String>> LINKS;

    /** The card's scale: the five presets in the table's order, most convenient first. Custom is not on it. */
    static final List<String> SCALE = Collections.unmodifiableList(new ArrayList<>(ProfilePresets.PRESETS));

    /** The dropdown's one line per preset. Each names only values the table sets (docs/profile-presets.md section
     *  (b)) and makes no claim of protection (docs/privacy-claims.md). Drafts for the maintainer to edit. */
    private static final Map<String, String> DESCRIPTIONS;

    static {
        if (!ProfilePresets.REPLACE_ASK.endsWith(REPLACE_TAIL))
            throw new IllegalStateException("REPLACE_ASK does not end with" + REPLACE_TAIL);
        Map<String, List<String>> m = new LinkedHashMap<>();
        m.put(ProfilePresets.UNSHIELDED, Arrays.asList(TIE_NO, LOC_ON));
        m.put(ProfilePresets.STANDARD, Arrays.asList(TIE_NO, LOC_OFF));
        m.put(ProfilePresets.HARDENED, Arrays.asList(TIE_YES, LOC_OFF));
        m.put(ProfilePresets.ISOLATED, Arrays.asList(TIE_YES, LOC_OFF));
        m.put(ProfilePresets.ZERO, Arrays.asList(TIE_YES, LOC_OFF));
        for (String p : ProfilePresets.PRESETS)
            if (!m.containsKey(p)) throw new IllegalStateException(p + ": no link lines");
        for (Map.Entry<String, List<String>> e : m.entrySet()) e.setValue(Collections.unmodifiableList(e.getValue()));
        LINKS = Collections.unmodifiableMap(m);
        Map<String, String> d = new LinkedHashMap<>();
        d.put(ProfilePresets.UNSHIELDED,
                "Never stands by; wipes only at power-off; new store apps start on Auto, others On-demand");
        d.put(ProfilePresets.STANDARD, "This phone's defaults: stands by after 15 minutes; wipes after 12 hours");
        d.put(ProfilePresets.HARDENED, "Stands by after 5 minutes; wipes after 6 hours");
        d.put(ProfilePresets.ISOLATED, "Stands by after 5 minutes; wipes after 1 hour");
        d.put(ProfilePresets.ZERO, "Stands by after 5 minutes; wipes once saved; new apps start Off");
        for (String p : SCALE)
            if (!d.containsKey(p)) throw new IllegalStateException(p + ": no description");
        DESCRIPTIONS = Collections.unmodifiableMap(d);
    }

    /** The REPLACE_ASK sentence without its two button words. */
    static String replaceMessage() {
        String a = ProfilePresets.REPLACE_ASK;
        return a.substring(0, a.length() - REPLACE_TAIL.length());
    }

    /** A preset's two consent lines, tie first, then location; none for Custom, null or an unknown name. */
    static List<String> links(String preset) {
        List<String> l = preset == null ? null : LINKS.get(preset);
        return l == null ? Collections.<String>emptyList() : l;
    }

    /** The five presets, then Custom. */
    static List<String> choices() {
        List<String> c = new ArrayList<>(SCALE);
        c.add(ProfilePresets.CUSTOM);
        return Collections.unmodifiableList(c);
    }

    /** The filled step of the card's scale: 0 (Unshielded) to 4 (Zero); -1 for Custom, null or an unknown name. */
    static int scalePos(String shown) {
        return SCALE.indexOf(shown);
    }

    /** A preset's one line; "" for Custom, null or an unknown name. */
    static String description(String preset) {
        String d = preset == null ? null : DESCRIPTIONS.get(preset);
        return d == null ? "" : d;
    }

    /** What the dropdown's rows pick, in row order: the five presets, then Custom only when one is saved. */
    static List<String> dropdownNames(boolean savedCustom) {
        List<String> c = new ArrayList<>(SCALE);
        if (savedCustom) c.add(ProfilePresets.CUSTOM);
        return Collections.unmodifiableList(c);
    }

    /** One dropdown row: "<name> — <description>" for a preset, the name alone for Custom. */
    static String rowOf(String name) {
        String d = description(name);
        return d.isEmpty() ? name : name + " — " + d;
    }

    /** The dropdown's rows, as dropdownNames orders them. */
    static List<String> dropdownRows(boolean savedCustom) {
        List<String> out = new ArrayList<>();
        for (String n : dropdownNames(savedCustom)) out.add(rowOf(n));
        return Collections.unmodifiableList(out);
    }

    /** How many settings a pick changes: one per preview line (none for a null target). */
    static int changeCount(Map<String, String> current, Map<String, String> toApply) {
        return ProfilePresets.previewLines(current, toApply).size();
    }

    /** The count dialog's sentence. */
    static String countLine(int n) {
        if (n == 0) return "No settings will change.";
        if (n == 1) return "1 setting will change.";
        return n + " settings will change.";
    }

    /** Profile home shows the card for a stored session, online or offline, and never for a throwaway, which is LOCAL
     *  and not offline (the 2026-10-31 decision hides the picker there; A7). */
    static boolean cardShown(boolean local, boolean offline) {
        return !local || offline;
    }

    /** ProfileActivity.prefValueIn's rule: the first line that starts with key=, trimmed, or "". */
    private static String prefValue(String text, String key) {
        if (text == null || text.isEmpty()) return "";
        String p = key + "=";
        for (String line : text.split("\r\n|\r|\n", -1)) {
            if (line.startsWith(p)) return line.substring(p.length()).trim();
        }
        return "";
    }

    /** The table's current map from the three files' texts (null = absent or unreadable, read as empty). Every ROWS key
     *  is present; an absent key reads as the screens read it. A stored value that is not an option stays as stored. */
    static Map<String, String> current(String prefsText, String configText, String reclaimText) {
        Map<String, String> cfg = SettingsText.parseConfig(configText == null ? "" : configText);
        Map<String, String> out = new LinkedHashMap<>();
        for (ProfilePresets.Row r : ProfilePresets.ROWS) {
            String k = r.key;
            if (k.equals("idle")) out.put(k, idle(prefValue(prefsText, "idle")));
            else if (k.equals("holdlock")) out.put(k, "0".equals(prefValue(prefsText, "holdlock")) ? "0" : "");
            else if (k.equals("holdaudio")) out.put(k, "0".equals(prefValue(prefsText, "holdaudio")) ? "0" : "");
            else if (k.equals("wipe"))
                out.put(k, String.valueOf(WipeChoice.selected(prefValue(prefsText, "wipe"),
                        prefValue(prefsText, WipeOnSave.PREF))));
            else if (k.equals("reclaim")) out.put(k, reclaim(reclaimText));
            else if (k.equals("media.default")) out.put(k, cfgOr(cfg, k, MEDIA_DEFAULT));
            else if (k.equals("apps.default.napps")) out.put(k, cfgOr(cfg, k, NAPPS_DEFAULT));
            else if (k.startsWith("apps.default.")) out.put(k, cfgOr(cfg, k, STORE_DEFAULT));
            else throw new IllegalStateException(k + ": PresetPicker cannot read this row");
        }
        return Collections.unmodifiableMap(out);
    }

    /** showIdlePicker: an empty or unparseable idle= highlights 15 minutes; a number shows as that number. */
    private static String idle(String v) {
        if (v.isEmpty()) return IDLE_DEFAULT;
        try {
            return String.valueOf(Integer.parseInt(v));
        } catch (NumberFormatException e) {
            return IDLE_DEFAULT;
        }
    }

    /** reclaimIdleMs: the first line, trimmed, when it is a number >= 0; else RECLAIM_DEFAULT_MS. */
    private static String reclaim(String text) {
        if (text == null || text.isEmpty()) return RECLAIM_DEFAULT;
        try {
            long v = Long.parseLong(text.split("\r\n|\r|\n", -1)[0].trim());
            if (v >= 0) return Long.toString(v);
        } catch (NumberFormatException ignore) {
        }
        return RECLAIM_DEFAULT;
    }

    /** cfg: a missing or empty value is the fallback. */
    private static String cfgOr(Map<String, String> cfg, String key, String dflt) {
        String v = cfg.get(key);
        return v == null || v.isEmpty() ? dflt : v;
    }

    /** What the card shows: Custom when the picker last applied Custom, else the preset current matches. */
    static String shown(Map<String, String> current, String lastText) {
        if (lastText != null && ProfilePresets.CUSTOM.equals(lastText.trim())) return ProfilePresets.CUSTOM;
        return ProfilePresets.match(current);
    }

    /** An ordered map of key/value pairs. */
    static Map<String, String> change(String... kv) {
        if (kv.length % 2 != 0) throw new IllegalArgumentException("change: odd number of strings");
        Map<String, String> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    /** A copy of current with change put over it. */
    static Map<String, String> with(Map<String, String> current, Map<String, String> change) {
        Map<String, String> m = new LinkedHashMap<>(current);
        m.putAll(change);
        return m;
    }

    /** One write the picker makes: the file and the key/value its existing writer takes. */
    static final class Write {
        final String file;
        final String key;
        final String value;

        Write(String file, String key, String value) {
            this.file = file;
            this.key = key;
            this.value = value;
        }

        @Override public String toString() { return file + "|" + key + "|" + value; }
    }

    /** One Write per row whose target value differs from current, in row order. The activity calls setPref for idle,
     *  holdlock and holdaudio, writeWipePref (wipe= and wipesaved= in one write) for wipe, cfgPut for the config rows and
     *  setReclaimIdleMs for reclaim. A row this class cannot write throws. */
    static List<Write> plan(Map<String, String> current, Map<String, String> target) {
        List<Write> out = new ArrayList<>();
        if (target == null) return out;
        for (ProfilePresets.Row r : ProfilePresets.ROWS) {
            String to = target.get(r.key);
            if (to == null || to.equals(current.get(r.key))) continue;
            out.add(new Write(fileOf(r.key), r.key, to));
        }
        return Collections.unmodifiableList(out);
    }

    private static String fileOf(String key) {
        if (key.equals("idle") || key.equals("holdlock") || key.equals("holdaudio") || key.equals("wipe"))
            return PREFS_FILE;
        if (key.equals("reclaim")) return RECLAIM_FILE;
        if (key.equals("media.default") || key.startsWith("apps.default.")) return CONFIG_FILE;
        throw new IllegalStateException(key + ": PresetPicker cannot write this row");
    }

    /** The keys of target whose value in after differs: what an Apply did not land. */
    static List<String> unapplied(Map<String, String> target, Map<String, String> after) {
        List<String> out = new ArrayList<>();
        if (target == null) return out;
        for (Map.Entry<String, String> e : target.entrySet())
            if (!e.getValue().equals(after == null ? null : after.get(e.getKey()))) out.add(e.getKey());
        return out;
    }

    /** True when change leaves every ROWS key of current as it is. */
    static boolean unchanged(Map<String, String> current, Map<String, String> change) {
        Map<String, String> after = with(current, change);
        for (ProfilePresets.Row r : ProfilePresets.ROWS)
            if (!Objects.equals(after.get(r.key), current.get(r.key))) return false;
        return true;
    }

    /** What a hand change does: write only, write and save the Custom in save, or ask REPLACE_ASK first. */
    enum Action { WRITE_ONLY, WRITE_AND_SAVE, ASK }

    /** guardAction's answer. save is the Custom to keep after the write (WRITE_AND_SAVE) or after Replace (ASK). */
    static final class Guard {
        final Action action;
        final Map<String, String> save;

        Guard(Action action, Map<String, String> save) {
            this.action = action;
            this.save = save;
        }
    }

    /** The hand-change decision. A change that moves no table value writes and saves nothing; otherwise
     *  ProfilePresets.handChange decides, and a saved Custom that would stay the same is not written again. */
    static Guard guardAction(String shownBefore, Map<String, String> current, Map<String, String> change,
            Map<String, String> savedCustom) {
        if (unchanged(current, change)) return new Guard(Action.WRITE_ONLY, null);
        ProfilePresets.HandChange h = ProfilePresets.handChange(shownBefore, with(current, change), savedCustom);
        if (h.askReplace) return new Guard(Action.ASK, h.savedCustomIfReplaced);
        if (Objects.equals(h.savedCustomAfter, savedCustom)) return new Guard(Action.WRITE_ONLY, null);
        return new Guard(Action.WRITE_AND_SAVE, h.savedCustomAfter);
    }
}
