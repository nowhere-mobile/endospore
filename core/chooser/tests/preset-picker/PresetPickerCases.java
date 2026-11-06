package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** NWP-20261122-02: the preset picker's pure half (PresetPicker), run by core/vendor-common/bin/test-preset-picker-java.sh.
 *  Lifted.prefValueIn is ProfileActivity's reader, lifted by the suite. Exit 1 on any failed case. */
final class PresetPickerCases {
    private static int fails = 0;

    private static void check(boolean ok, String name) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) fails++;
    }

    private static Map<String, String> std() { return ProfilePresets.valuesOf(ProfilePresets.STANDARD); }

    private static Map<String, String> put(Map<String, String> m, String k, String v) {
        Map<String, String> c = new LinkedHashMap<>(m);
        c.put(k, v);
        return c;
    }

    private static int labelIndex(String label) {
        return Arrays.asList(WipeChoice.LABELS).indexOf(label);
    }

    public static void main(String[] args) {
        // 1. Every preset has exactly two link lines; Custom has none.
        for (String p : ProfilePresets.PRESETS) check(PresetPicker.links(p).size() == 2, "1 " + p + " has two link lines");
        check(PresetPicker.links(ProfilePresets.CUSTOM).isEmpty(), "1 Custom has no link lines");
        check(PresetPicker.links(null).isEmpty() && PresetPicker.links("Nope").isEmpty(), "1 null and unknown have none");

        // 2. The lines, verbatim (h50 #8 for Unshielded and Standard; section (d) for the other three).
        check(PresetPicker.links(ProfilePresets.UNSHIELDED).equals(Arrays.asList(
                "Suggested: don't tie this profile to this phone", "Suggested: Location on")), "2 Unshielded's lines");
        check(PresetPicker.links(ProfilePresets.STANDARD).equals(Arrays.asList(
                "Suggested: don't tie this profile to this phone", "Suggested: Location off")), "2 Standard's lines");
        for (String p : Arrays.asList(ProfilePresets.HARDENED, ProfilePresets.ISOLATED, ProfilePresets.ZERO))
            check(PresetPicker.links(p).equals(Arrays.asList(
                    "Suggested: tie this profile to this phone", "Suggested: Location off")), "2 " + p + "'s lines");
        check(PresetPicker.choices().equals(Arrays.asList("Unshielded", "Standard", "Hardened", "Isolated", "Zero", "Custom")),
                "2 choices are the five presets, then Custom");

        // 3. A new profile (no files) is Standard.
        check(PresetPicker.current("", "", "").equals(std()), "3 current of empty texts is Standard");
        check(PresetPicker.current(null, null, null).equals(std()), "3 current of null texts is Standard");
        check(ProfilePresets.STANDARD.equals(ProfilePresets.match(PresetPicker.current("", "", ""))), "3 it matches Standard");

        // 4. wipe is the WipeChoice index of wipe= and wipesaved=.
        check("0".equals(PresetPicker.current("wipe=1\nwipesaved=1\n", "", "").get("wipe")), "4 wipe=1 + wipesaved=1 is index 0");
        int day = labelIndex("After 1 day");
        check(day > 0 && String.valueOf(day).equals(PresetPicker.current("wipe=24\n", "", "").get("wipe")),
                "4 wipe=24 is the After 1 day index");
        check("1".equals(PresetPicker.current("wipe=1\n", "", "").get("wipe")), "4 wipe=1 alone is After 1 hour");
        Map<String, String> c4 = PresetPicker.current("idle=0\nholdlock=0\n", "media.default=prefetch\napps.default.play=auto\n", "");
        check("0".equals(c4.get("idle")) && "0".equals(c4.get("holdlock")) && "prefetch".equals(c4.get("media.default"))
                && "auto".equals(c4.get("apps.default.play")) && "off".equals(c4.get("apps.default.aurora")),
                "4 stored values are read; absent ones are defaults");
        check("".equals(PresetPicker.current("holdlock=1\n", "", "").get("holdlock")), "4 holdlock other than 0 is On");
        check("0".equals(PresetPicker.current("holdaudio=0\n", "", "").get("holdaudio")), "4 holdaudio=0 is Off");
        check("".equals(PresetPicker.current("holdaudio=1\n", "", "").get("holdaudio")), "4 holdaudio other than 0 is On");
        check("2".equals(PresetPicker.current("idle=2\n", "", "").get("idle")), "4 an off-table idle stays as stored");
        check("15".equals(PresetPicker.current("idle=x\n", "", "").get("idle")), "4 an unparseable idle reads 15");
        check("auto".equals(PresetPicker.current("", "apps.default.napps=\n", "").get("apps.default.napps")),
                "4 an empty config value is the fallback");

        // 5. The write plan for Standard -> Zero names every changed row and no other.
        List<String> plan = new ArrayList<>();
        for (PresetPicker.Write w : PresetPicker.plan(std(), ProfilePresets.valuesOf(ProfilePresets.ZERO))) plan.add(w.toString());
        check(plan.equals(Arrays.asList("nowhere-prefs|idle|5", "nowhere-prefs|holdlock|0", "nowhere-prefs|holdaudio|0",
                "nowhere-prefs|wipe|0", "nowhere-reclaim|reclaim|86400000", "nowhere-config|apps.default.napps|off")),
                "5 Standard -> Zero plans exactly the six changed rows: " + plan);
        check(PresetPicker.plan(std(), std()).isEmpty(), "5 Standard -> Standard plans nothing");
        check(PresetPicker.plan(std(), null).isEmpty(), "5 a null target plans nothing");

        // 6. Every ROWS key has a write mapping and a reader.
        Map<String, String> all = new LinkedHashMap<>();
        for (ProfilePresets.Row r : ProfilePresets.ROWS) all.put(r.key, "changed");
        boolean six;
        try {
            six = PresetPicker.plan(std(), all).size() == ProfilePresets.ROWS.size()
                    && PresetPicker.current("", "", "").keySet().equals(all.keySet());
        } catch (IllegalStateException e) {
            six = false;
        }
        check(six, "6 every ROWS key is read by current and written by plan");

        // 7. unapplied.
        check(PresetPicker.unapplied(std(), std()).isEmpty(), "7 equal maps leave nothing unapplied");
        check(PresetPicker.unapplied(std(), put(std(), "idle", "5")).equals(Arrays.asList("idle")), "7 the differing key");

        // 8. shown.
        check(ProfilePresets.CUSTOM.equals(PresetPicker.shown(std(), "Custom\n")), "8 LAST Custom shows Custom over a match");
        check(ProfilePresets.STANDARD.equals(PresetPicker.shown(std(), "Zero")), "8 LAST Zero shows the match");
        check(ProfilePresets.STANDARD.equals(PresetPicker.shown(std(), "")), "8 no LAST shows the match");
        check(ProfilePresets.CUSTOM.equals(PresetPicker.shown(put(std(), "idle", "60"), "")), "8 no match shows Custom");

        // 9. The replace prompt.
        check((PresetPicker.replaceMessage() + " " + PresetPicker.REPLACE + " / " + PresetPicker.CANCEL + ".")
                .equals(ProfilePresets.REPLACE_ASK), "9 message + Replace / Cancel is REPLACE_ASK");
        check("This replaces your saved Custom settings.".equals(PresetPicker.replaceMessage()), "9 the message");

        // 10. The private reader is prefValueIn's rule.
        String[] texts = { "", "idle=5", "idle=5\r\nwipe=24\r\n", "idle= 30 \nidle=60\n", "xidle=5\nidle=15",
                "holdlock=0\rwipe=1\r", "wipe=\n" };
        boolean ten = true;
        for (String t : texts)
            ten &= Lifted.prefValueIn(t, "idle").isEmpty()
                    ? PresetPicker.current(t, "", "").get("idle").equals("15")
                    : PresetPicker.current(t, "", "").get("idle").equals(String.valueOf(Integer.parseInt(Lifted.prefValueIn(t, "idle"))));
        ten &= PresetPicker.current("holdlock=0\rwipe=1\r", "", "").get("holdlock").equals("0")
                && "0".equals(Lifted.prefValueIn("holdlock=0\rwipe=1\r", "holdlock"));
        check(ten, "10 current reads prefs as prefValueIn does");

        // 11. reclaim as reclaimIdleMs reads it.
        check("0".equals(PresetPicker.current("", "", "0").get("reclaim")), "11 0 (Never) is kept");
        check("86400000".equals(PresetPicker.current("", "", " 86400000 \n").get("reclaim")), "11 the first line, trimmed");
        check("259200000".equals(PresetPicker.current("", "", "-5").get("reclaim")), "11 a negative is the default");
        check("259200000".equals(PresetPicker.current("", "", "x").get("reclaim")), "11 a non-number is the default");

        // 12. guardAction.
        Map<String, String> hard = ProfilePresets.valuesOf(ProfilePresets.HARDENED);
        Map<String, String> std5 = put(std(), "idle", "5");
        PresetPicker.Guard g;
        g = PresetPicker.guardAction("Standard", std(), PresetPicker.change("idle", "15"), hard);
        check(g.action == PresetPicker.Action.WRITE_ONLY && g.save == null, "12 noop-on-preset-with-saved");
        g = PresetPicker.guardAction("Standard", std(), PresetPicker.change("idle", "15", "holdlock", ""), hard);
        check(g.action == PresetPicker.Action.WRITE_ONLY && g.save == null, "12 noop-idle-dialog-shape");
        g = PresetPicker.guardAction("Standard", std(), PresetPicker.change("idle", "15"), null);
        check(g.action == PresetPicker.Action.WRITE_ONLY && g.save == null, "12 noop-no-saved");
        g = PresetPicker.guardAction("Standard", std(), PresetPicker.change("idle", "5"), hard);
        check(g.action == PresetPicker.Action.ASK && std5.equals(g.save), "12 real-on-preset-with-saved");
        g = PresetPicker.guardAction("Standard", std(), PresetPicker.change("idle", "5"), null);
        check(g.action == PresetPicker.Action.WRITE_AND_SAVE && std5.equals(g.save), "12 real-on-preset-no-saved");
        Map<String, String> cust = put(std(), "holdlock", "0");
        g = PresetPicker.guardAction("Custom", cust, PresetPicker.change("idle", "5"), hard);
        check(g.action == PresetPicker.Action.WRITE_AND_SAVE && put(cust, "idle", "5").equals(g.save), "12 real-on-custom");
        g = PresetPicker.guardAction("Custom", cust, PresetPicker.change("holdlock", "0"), hard);
        check(g.action == PresetPicker.Action.WRITE_ONLY && g.save == null, "12 noop-on-custom");
        g = PresetPicker.guardAction("Custom", put(std(), "idle", "2"), PresetPicker.change("holdlock", "0"), hard);
        check(g.action == PresetPicker.Action.WRITE_ONLY && g.save == null, "12 incomplete-after");
        g = PresetPicker.guardAction("Standard", std(), PresetPicker.change("idle", "5"), std5);
        check(g.action == PresetPicker.Action.WRITE_ONLY && g.save == null, "12 saved-equals-after");

        // 13. unchanged.
        check(PresetPicker.unchanged(std(), PresetPicker.change("idle", "15")), "13 an equal change is unchanged");
        check(!PresetPicker.unchanged(std(), PresetPicker.change("idle", "5")), "13 one ROWS key differs");
        check(PresetPicker.unchanged(std(), PresetPicker.change("netloc", "1")), "13 a non-ROWS key does not count");

        // 14. NWP-20261126-09: the card's scale is choices() without Custom, in order; Custom is not on it.
        List<String> noCustom = new ArrayList<>(PresetPicker.choices());
        check(noCustom.remove(ProfilePresets.CUSTOM) && PresetPicker.SCALE.equals(noCustom),
                "14 SCALE is choices() minus Custom, in order");
        check(PresetPicker.SCALE.equals(Arrays.asList("Unshielded", "Standard", "Hardened", "Isolated", "Zero")),
                "14 SCALE goes from Unshielded to Zero");
        check(!PresetPicker.SCALE.contains(ProfilePresets.CUSTOM), "14 Custom is not on the scale");
        check("Custom".equals(PresetPicker.choices().get(PresetPicker.choices().size() - 1)), "14 choices() ends with Custom");

        // 15. scalePos.
        String[] five = { "Unshielded", "Standard", "Hardened", "Isolated", "Zero" };
        for (int i = 0; i < five.length; i++) check(PresetPicker.scalePos(five[i]) == i, "15 scalePos(" + five[i] + ") is " + i);
        check(PresetPicker.scalePos(ProfilePresets.CUSTOM) == -1, "15 scalePos(Custom) is -1");
        check(PresetPicker.scalePos(null) == -1 && PresetPicker.scalePos("Nope") == -1, "15 scalePos of null and unknown is -1");

        // 16. The dropdown: five rows with their lines, then Custom only with a saved Custom.
        List<String> r5 = PresetPicker.dropdownRows(false), r6 = PresetPicker.dropdownRows(true);
        boolean rowsOk = r5.size() == 5 && r6.size() == 6 && "Custom".equals(r6.get(5));
        String[] claims = { "secure", "safe", "protect", "private", "privacy", "anonym" };
        for (int i = 0; i < five.length && rowsOk; i++) {
            String d = PresetPicker.description(five[i]);
            rowsOk = !d.isEmpty() && r5.get(i).equals(five[i] + " — " + d) && r6.get(i).equals(r5.get(i));
            for (String w : claims) rowsOk &= !d.toLowerCase(java.util.Locale.ROOT).contains(w);
        }
        check(rowsOk, "16 dropdownRows: '<name> — <line>' for the five, a line with no claim word, Custom last only when saved: " + r6);
        check(PresetPicker.dropdownNames(false).equals(PresetPicker.SCALE)
                && PresetPicker.dropdownNames(true).equals(PresetPicker.choices()), "16 dropdownNames matches the rows");
        check(PresetPicker.description(ProfilePresets.CUSTOM).isEmpty() && PresetPicker.description(null).isEmpty(),
                "16 Custom and null have no line");
        check(PresetPicker.description("Standard").startsWith("This phone's defaults"), "16 Standard is this phone's defaults");
        // A line that names a new app's start mode names the one the table sets for every source it covers.
        Map<String, String> un = ProfilePresets.valuesOf(ProfilePresets.UNSHIELDED);
        String ud = PresetPicker.description(ProfilePresets.UNSHIELDED);
        check(!ud.contains("new apps start") && ud.contains("new store apps start on Auto, others On-demand")
                && "auto".equals(un.get("apps.default.napps")) && "auto".equals(un.get("apps.default.play"))
                && "auto".equals(un.get("apps.default.aurora")) && "auto".equals(un.get("apps.default.gos"))
                && "ondemand".equals(un.get("apps.default.other")),
                "16 Unshielded's line: store apps Auto, everything else On-demand, as the table sets: " + ud);
        Map<String, String> zv = ProfilePresets.valuesOf(ProfilePresets.ZERO);
        boolean zeroOff = PresetPicker.description(ProfilePresets.ZERO).contains("new apps start Off");
        for (String k : new String[]{ "napps", "play", "aurora", "gos", "other" })
            zeroOff &= "off".equals(zv.get("apps.default." + k));
        check(zeroOff, "16 Zero's line: every new app starts Off, as the table sets");
        check("Custom".equals(PresetPicker.rowOf(ProfilePresets.CUSTOM))
                && PresetPicker.rowOf("Zero").equals("Zero — " + PresetPicker.description("Zero")), "16 rowOf");

        // 17. changeCount is the preview's line count.
        Map<String, String> zero = ProfilePresets.valuesOf(ProfilePresets.ZERO);
        check(PresetPicker.changeCount(std(), zero) == ProfilePresets.previewLines(std(), zero).size()
                && PresetPicker.changeCount(std(), zero) == 6, "17 Standard -> Zero counts its six preview lines");
        Map<String, String> unsh = ProfilePresets.valuesOf(ProfilePresets.UNSHIELDED);
        check(PresetPicker.changeCount(zero, unsh) == ProfilePresets.previewLines(zero, unsh).size()
                && PresetPicker.changeCount(zero, unsh) > 6, "17 Zero -> Unshielded counts its preview lines");
        check(PresetPicker.changeCount(std(), std()) == 0 && PresetPicker.changeCount(std(), null) == 0,
                "17 no change and a null target count 0");

        // 18. countLine.
        check("No settings will change.".equals(PresetPicker.countLine(0)), "18 countLine(0)");
        check("1 setting will change.".equals(PresetPicker.countLine(1)), "18 countLine(1)");
        check("7 settings will change.".equals(PresetPicker.countLine(7)), "18 countLine(7)");

        // 19. cardShown: a throwaway (LOCAL, not offline) has no card; a stored session has it, online or offline.
        check(!PresetPicker.cardShown(true, false), "19 a throwaway shows no card");
        check(PresetPicker.cardShown(true, true), "19 an offline stored session shows the card");
        check(PresetPicker.cardShown(false, false), "19 a stored session shows the card");
        check("Privacy level".equals(PresetPicker.CARD_TITLE), "19 the card's title");

        if (fails > 0) {
            System.out.println(fails + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
