package com.nowhere.chooser;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Cases for ProfilePresets (NWP-20261119-12), run by core/vendor-common/bin/test-profile-presets-java.sh.
 *  --dump-doc and --dump-store print the rows as TSV for the suite's doc pin and code pin. */
public class ProfilePresetsCases {
    static int failed;

    static void check(String what, Object got, Object want) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("  ok    " + what);
        } else {
            failed++;
            System.out.println("  FAIL  " + what + ": got <" + got + ">, want <" + want + ">");
        }
    }

    static final List<String> KEYS = Arrays.asList("idle", "holdlock", "holdaudio", "wipe", "media.default", "reclaim",
            "apps.default.napps", "apps.default.play", "apps.default.aurora", "apps.default.gos", "apps.default.other");

    /** A map of the eleven keys in KEYS order. */
    static Map<String, String> m(String... v) {
        Map<String, String> out = new LinkedHashMap<>();
        for (int i = 0; i < v.length; i++) out.put(KEYS.get(i), v[i]);
        return out;
    }

    static Map<String, String> with(Map<String, String> base, String k, String v) {
        Map<String, String> out = new LinkedHashMap<>(base);
        if (v == null) out.remove(k); else out.put(k, v);
        return out;
    }

    public static void main(String[] a) {
        if (a.length == 1 && a[0].equals("--dump-doc")) { dumpDoc(); return; }
        if (a.length == 1 && a[0].equals("--dump-store")) { dumpStore(); return; }

        final String D1 = "86400000", D3 = "259200000", W1 = "604800000";
        Map<String, String> wantU = m("0", "", "", "5", "prefetch", "0", "auto", "auto", "auto", "auto", "ondemand");
        Map<String, String> wantS = m("15", "", "", "3", "ondemand", D3, "auto", "off", "off", "off", "off");
        Map<String, String> wantH = m("5", "0", "0", "2", "ondemand", D1, "ondemand", "off", "off", "off", "off");
        Map<String, String> wantI = m("5", "0", "0", "1", "ondemand", D1, "ondemand", "off", "off", "off", "off");
        Map<String, String> wantZ = m("5", "0", "0", "0", "ondemand", D1, "off", "off", "off", "off", "off");

        // The names, the rows, and each preset's eleven values.
        check("PRESETS in table order", ProfilePresets.PRESETS,
                Arrays.asList("Unshielded", "Standard", "Hardened", "Isolated", "Zero"));
        check("CUSTOM is \"Custom\"", ProfilePresets.CUSTOM, "Custom");
        check("eleven rows", ProfilePresets.ROWS.size(), 11);
        check("valuesOf(Unshielded)", ProfilePresets.valuesOf(ProfilePresets.UNSHIELDED), wantU);
        check("valuesOf(Standard)", ProfilePresets.valuesOf(ProfilePresets.STANDARD), wantS);
        check("valuesOf(Hardened)", ProfilePresets.valuesOf(ProfilePresets.HARDENED), wantH);
        check("valuesOf(Isolated)", ProfilePresets.valuesOf(ProfilePresets.ISOLATED), wantI);
        check("valuesOf(Zero)", ProfilePresets.valuesOf(ProfilePresets.ZERO), wantZ);
        for (String p : ProfilePresets.PRESETS)
            check("valuesOf(" + p + ") keys in row order",
                    new java.util.ArrayList<>(ProfilePresets.valuesOf(p).keySet()), KEYS);
        boolean threw = false;
        try { ProfilePresets.valuesOf(ProfilePresets.STANDARD).put("idle", "5"); } catch (UnsupportedOperationException e) { threw = true; }
        check("valuesOf is unmodifiable", threw, true);
        check("valuesOf(Custom) is null", ProfilePresets.valuesOf(ProfilePresets.CUSTOM), null);
        check("valuesOf(null) is null", ProfilePresets.valuesOf(null), null);
        check("valuesOf(\"standard\") is null (case matters)", ProfilePresets.valuesOf("standard"), null);
        check("optionLabel(wipe, 3)", ProfilePresets.optionLabel("wipe", "3"), "After 12 hours");
        check("optionLabel(holdlock, \"\")", ProfilePresets.optionLabel("holdlock", ""), "On (checked)");
        check("optionLabel(holdaudio, \"0\")", ProfilePresets.optionLabel("holdaudio", "0"), "Off (unchecked)");
        check("optionLabel(reclaim, 1 week)", ProfilePresets.optionLabel("reclaim", W1), "1 week");
        check("optionLabel of an unknown key is null", ProfilePresets.optionLabel("backups", "0"), null);

        // match: each column, a one-row difference of each kind, a missing key, extra keys.
        for (String p : ProfilePresets.PRESETS) check("match(valuesOf(" + p + "))", ProfilePresets.match(ProfilePresets.valuesOf(p)), p);
        check("match(Hardened) is Hardened, not Isolated", ProfilePresets.match(wantH), "Hardened");
        check("match(Standard with idle=30) is Custom", ProfilePresets.match(with(wantS, "idle", "30")), "Custom");
        check("match(Standard with holdlock=0) is Custom", ProfilePresets.match(with(wantS, "holdlock", "0")), "Custom");
        check("match(Standard with holdaudio=0) is Custom", ProfilePresets.match(with(wantS, "holdaudio", "0")), "Custom");
        check("match(Standard with wipe=2) is Custom", ProfilePresets.match(with(wantS, "wipe", "2")), "Custom");
        check("match(Standard with media.default=essential) is Custom",
                ProfilePresets.match(with(wantS, "media.default", "essential")), "Custom");
        check("match(Standard with reclaim=1 week) is Custom", ProfilePresets.match(with(wantS, "reclaim", W1)), "Custom");
        check("match(Standard with apps.default.other=auto) is Custom",
                ProfilePresets.match(with(wantS, "apps.default.other", "auto")), "Custom");
        check("match(Zero with apps.default.napps=ondemand) is Custom, not Isolated",
                ProfilePresets.match(with(wantZ, "apps.default.napps", "ondemand")), "Custom");
        check("match(Standard without holdlock) is Custom (a missing key never matches)",
                ProfilePresets.match(with(wantS, "holdlock", null)), "Custom");
        check("match(empty) is Custom", ProfilePresets.match(new LinkedHashMap<>()), "Custom");
        check("match(null) is Custom", ProfilePresets.match(null), "Custom");
        check("match(Standard plus an unknown key) is Standard", ProfilePresets.match(with(wantS, "locale", "de")), "Standard");

        // previewLines: the changed rows only, in row order, in option labels.
        check("previewLines(Standard -> Zero)", ProfilePresets.previewLines(wantS, wantZ), Arrays.asList(
                "Security > Auto standby when idle: After 15 minutes \u2192 After 5 minutes",
                "Security > Auto standby when idle > \"Before standby, wait for:\" > \"app installs\": "
                        + "On (checked) \u2192 Off (unchecked)",
                "Security > Auto standby when idle > \"Before standby, wait for:\" > \"audio playing\": "
                        + "On (checked) \u2192 Off (unchecked)",
                "Security > Auto-wipe when left locked (dialog \"Erase a locked session after\"): "
                        + "After 12 hours \u2192 Right away, once saved",
                "Preferences > Your apps > Re-archive idle apps: 3 days \u2192 1 day",
                "Preferences > Configuration > Your apps > nApps (\"What a newly installed app starts as\"): "
                        + "Auto \u2192 Off"));
        check("previewLines(Isolated -> Zero) is two lines", ProfilePresets.previewLines(wantI, wantZ).size(), 2);
        check("previewLines(x, x) is empty", ProfilePresets.previewLines(wantH, wantH), Arrays.asList());
        check("previewLines(x, null) is empty", ProfilePresets.previewLines(wantH, null), Arrays.asList());
        check("previewLines without a current idle says not set",
                ProfilePresets.previewLines(with(wantS, "idle", null), wantS),
                Arrays.asList("Security > Auto standby when idle: not set \u2192 After 15 minutes"));
        check("previewLines of an off-list current value shows it as stored",
                ProfilePresets.previewLines(with(wantS, "idle", "2"), wantS),
                Arrays.asList("Security > Auto standby when idle: 2 \u2192 After 15 minutes"));

        // formatCustom / parseCustom.
        String textH = "idle=5\nholdlock=0\nholdaudio=0\nwipe=2\nmedia.default=ondemand\nreclaim=86400000\napps.default.napps=ondemand\n"
                + "apps.default.play=off\napps.default.aurora=off\napps.default.gos=off\napps.default.other=off\n";
        check("formatCustom(Hardened)", ProfilePresets.formatCustom(wantH), textH);
        Map<String, String> mine = m("30", "0", "", "4", "essential", W1, "installed", "ondemand", "auto", "off", "ondemand");
        check("mine matches no preset", ProfilePresets.match(mine), "Custom");
        for (Map<String, String> x : Arrays.asList(wantU, wantS, wantH, wantI, wantZ, mine))
            check("parseCustom(formatCustom(x)) == x", ProfilePresets.parseCustom(ProfilePresets.formatCustom(x)), x);
        String textS = ProfilePresets.formatCustom(wantS);
        check("formatCustom(Standard) has an empty holdlock= line", textS.contains("\nholdlock=\n"), true);
        check("parseCustom: holdlock= is On", ProfilePresets.parseCustom(textS).get("holdlock"), "");
        check("parseCustom: holdlock=0 is Off", ProfilePresets.parseCustom(textH).get("holdlock"), "0");
        check("formatCustom(Standard) has an empty holdaudio= line", textS.contains("\nholdaudio=\n"), true);
        check("parseCustom: holdaudio= is On", ProfilePresets.parseCustom(textS).get("holdaudio"), "");
        check("parseCustom: holdaudio=0 is Off", ProfilePresets.parseCustom(textH).get("holdaudio"), "0");
        check("formatCustom drops an extra key", ProfilePresets.formatCustom(with(wantH, "locale", "de")), textH);
        check("formatCustom(null) is null", ProfilePresets.formatCustom(null), null);
        check("formatCustom of a map with a row missing is null", ProfilePresets.formatCustom(with(wantH, "reclaim", null)), null);
        check("formatCustom of a junk value is null", ProfilePresets.formatCustom(with(wantH, "wipe", "9")), null);
        check("parseCustom(null) is null", ProfilePresets.parseCustom(null), null);
        check("parseCustom(\"\") is null", ProfilePresets.parseCustom(""), null);
        check("parseCustom(junk) is null", ProfilePresets.parseCustom("\u0000\u00ff garbage\n=\n"), null);
        check("parseCustom with a row missing is null", ProfilePresets.parseCustom(textH.replace("reclaim=86400000\n", "")), null);
        check("parseCustom idle=7 is null", ProfilePresets.parseCustom(textH.replace("idle=5", "idle=7")), null);
        check("parseCustom wipe=9 is null", ProfilePresets.parseCustom(textH.replace("wipe=2", "wipe=9")), null);
        check("parseCustom media.default=essentially is null",
                ProfilePresets.parseCustom(textH.replace("media.default=ondemand", "media.default=essentially")), null);
        check("parseCustom apps.default.gos= (empty) is null",
                ProfilePresets.parseCustom(textH.replace("apps.default.gos=off", "apps.default.gos=")), null);
        check("parseCustom with a repeated key is null", ProfilePresets.parseCustom(textH + "idle=5\n"), null);
        check("parseCustom with a line with no = is null", ProfilePresets.parseCustom(textH + "idle\n"), null);
        Map<String, String> extra = ProfilePresets.parseCustom("# saved\n\n" + textH + "foo=bar\n");
        check("parseCustom skips # and blank lines and drops an unknown key", extra, wantH);
        check("parseCustom's map has eleven keys", extra == null ? -1 : extra.size(), 11);
        check("parseCustom accepts CRLF", ProfilePresets.parseCustom(textH.replace("\n", "\r\n")), wantH);

        // choose: leaving Custom saves it, choosing Custom restores it.
        Map<String, String> older = m("60", "", "", "1", "prefetch", "0", "off", "off", "off", "off", "off");
        ProfilePresets.Choice c = ProfilePresets.choose("Custom", "Zero", mine, null);
        check("choose(Custom -> Zero) applies Zero", c.valuesToApply, wantZ);
        check("choose(Custom -> Zero) saves current as Custom", c.savedCustomAfter, mine);
        c = ProfilePresets.choose("Custom", "Zero", mine, older);
        check("choose(Custom -> Zero) replaces an older saved Custom", c.savedCustomAfter, mine);
        c = ProfilePresets.choose("Zero", "Custom", wantZ, mine);
        check("choose(Zero -> Custom) applies the saved Custom", c.valuesToApply, mine);
        check("choose(Zero -> Custom) keeps the saved Custom", c.savedCustomAfter, mine);
        ProfilePresets.Choice c1 = ProfilePresets.choose("Custom", "Zero", mine, null);
        ProfilePresets.Choice c2 = ProfilePresets.choose(ProfilePresets.match(c1.valuesToApply), "Custom",
                c1.valuesToApply, c1.savedCustomAfter);
        check("Custom -> Zero -> Custom: Zero is shown in between", ProfilePresets.match(c1.valuesToApply), "Zero");
        check("Custom -> Zero -> Custom restores the values exactly", c2.valuesToApply, mine);
        check("Custom -> Zero -> Custom: back on Custom", ProfilePresets.match(c2.valuesToApply), "Custom");
        c = ProfilePresets.choose("Standard", "Custom", wantS, null);
        check("choose(-> Custom) with none saved applies nothing", c.valuesToApply, null);
        check("choose(-> Custom) with none saved saves nothing", c.savedCustomAfter, null);
        c = ProfilePresets.choose("Standard", "Hardened", wantS, mine);
        check("choose(Standard -> Hardened) applies Hardened", c.valuesToApply, wantH);
        check("choose(Standard -> Hardened) keeps the saved Custom", c.savedCustomAfter, mine);
        c = ProfilePresets.choose("Custom", "Zero", with(mine, "wipe", null), older);
        check("choose(Custom -> Zero) with an incomplete current keeps the old saved Custom", c.savedCustomAfter, older);
        c = ProfilePresets.choose("Standard", "Bogus", wantS, mine);
        check("choose(-> an unknown preset) applies nothing", c.valuesToApply, null);
        check("choose(-> an unknown preset) keeps the saved Custom", c.savedCustomAfter, mine);

        // handChange: on Custom it saves; on a preset it asks only before it replaces a different saved Custom.
        Map<String, String> after = with(wantS, "idle", "30");
        ProfilePresets.HandChange h = ProfilePresets.handChange("Custom", after, older);
        check("handChange on Custom does not ask", h.askReplace, false);
        check("handChange on Custom saves after", h.savedCustomAfter, after);
        h = ProfilePresets.handChange("Standard", after, null);
        check("handChange on a preset with none saved does not ask", h.askReplace, false);
        check("handChange on a preset with none saved saves after", h.savedCustomAfter, after);
        h = ProfilePresets.handChange("Standard", after, new LinkedHashMap<>(after));
        check("handChange on a preset with an equal saved Custom does not ask", h.askReplace, false);
        check("handChange on a preset with an equal saved Custom keeps it", h.savedCustomAfter, after);
        h = ProfilePresets.handChange("Standard", after, mine);
        check("handChange on a preset with a different saved Custom asks", h.askReplace, true);
        check("handChange that asks changes nothing (Cancel keeps the saved Custom)", h.savedCustomAfter, mine);
        check("handChange that asks gives after for Replace", h.savedCustomIfReplaced, after);
        h = ProfilePresets.handChange("Bogus", after, mine);
        check("handChange on an unknown name asks before it replaces", h.askReplace, true);
        h = ProfilePresets.handChange("Standard", with(after, "wipe", null), mine);
        check("handChange with an incomplete after does not ask", h.askReplace, false);
        check("handChange with an incomplete after keeps the saved Custom", h.savedCustomAfter, mine);
        check("REPLACE_ASK", ProfilePresets.REPLACE_ASK, "This replaces your saved Custom settings. Replace / Cancel.");

        // The row guard: a preset value that is not an option does not load.
        threw = false;
        try {
            new ProfilePresets.Row("x", "X", new String[]{ "A", "B" }, new String[]{ "a", "b" }, "a", "a", "c", "b", "b");
        } catch (IllegalStateException e) { threw = true; }
        check("a preset value that is not an option throws", threw, true);

        if (failed > 0) { System.out.println(failed + " case(s) FAILED"); System.exit(1); }
        System.out.println("all cases passed");
    }

    /** One TSV line per row, as the doc's columns: label, options, today's default, then the five presets. */
    static void dumpDoc() {
        int std = ProfilePresets.PRESETS.indexOf(ProfilePresets.STANDARD);
        for (ProfilePresets.Row r : ProfilePresets.ROWS) {
            StringBuilder sb = new StringBuilder(r.label).append('\t').append(String.join("; ", r.optionLabels));
            sb.append('\t').append(r.labelOf(r.presetValues.get(std)));
            for (String v : r.presetValues) sb.append('\t').append(r.labelOf(v));
            System.out.println(sb);
        }
    }

    /** One TSV line per row: key, option values joined by ",", option labels joined by "; ", Standard's value. */
    static void dumpStore() {
        int std = ProfilePresets.PRESETS.indexOf(ProfilePresets.STANDARD);
        for (ProfilePresets.Row r : ProfilePresets.ROWS)
            System.out.println(r.key + "\t" + String.join(",", r.optionValues) + "\t" + String.join("; ", r.optionLabels)
                    + "\t" + r.presetValues.get(std));
    }
}
