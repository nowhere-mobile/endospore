package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Option;
import com.nowhere.chooser.PopupSheet.Picker;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261201-28: the shared sheet's rules and the Privacy level models. Each failure line names its case. */
final class PopupSheetCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static Button b(String label, Style style) {
        return new Button(label, style);
    }

    private static Confirm conf(Tone tone, Button... buttons) {
        return new Confirm(tone, "Title", "One sentence.", Collections.singletonList(new Line("A line", null)),
                Arrays.asList(buttons));
    }

    private static Option opt(String name, boolean current) {
        return new Option(name, Collections.singletonList("A chip"), "A description", current);
    }

    private static Confirm routine() {
        return conf(Tone.ROUTINE, b("Do it", Style.GREEN_FILLED), b(PopupSheet.NOT_NOW, Style.OUTLINED));
    }

    private static Confirm warning() {
        return conf(Tone.WARNING, b("Try saving again", Style.GREEN_FILLED), b("Sign out anyway", Style.RED_OUTLINED));
    }

    private static Confirm destructive() {
        return conf(Tone.DESTRUCTIVE, b("Delete profile", Style.RED_FILLED), b("Keep profile", Style.OUTLINED));
    }

    /** The named reason fires, and with it only the reasons in also. */
    private static void fires(String name, List<String> got, String reason, String... also) {
        List<String> allowed = new ArrayList<>(Arrays.asList(also));
        allowed.add(reason);
        check(name + " fires", got.contains(reason));
        for (String g : got) check(name + " fires nothing else (" + g + ")", allowed.contains(g));
    }

    private static void rules() {
        check("clean routine", PopupSheet.violations(routine()).isEmpty());
        check("clean warning", PopupSheet.violations(warning()).isEmpty());
        check("clean destructive", PopupSheet.violations(destructive()).isEmpty());
        check("clean information",
                PopupSheet.violations(conf(Tone.ROUTINE, b(PopupSheet.GOT_IT, Style.GREEN_FILLED))).isEmpty());
        check("clean picker",
                PopupSheet.violations(new Picker("T", Arrays.asList(opt("A", true), opt("B", false)))).isEmpty());

        for (String word : new String[] { "OK", "Okay", "Cancel", " ok ", "CANCEL", "okay" }) {
            fires("R_OK_CANCEL " + word, PopupSheet.violations(conf(Tone.ROUTINE, b("Do it", Style.GREEN_FILLED),
                    b(word, Style.OUTLINED))), PopupSheet.R_OK_CANCEL);
        }
        check("R_OK_CANCEL not on a longer label", PopupSheet.violations(conf(Tone.ROUTINE,
                b("Cancel plan", Style.GREEN_FILLED), b(PopupSheet.NOT_NOW, Style.OUTLINED))).isEmpty());

        String amp = PopupSheet.R_AMPERSAND;
        fires("R_AMPERSAND title", PopupSheet.violations(new Confirm(Tone.ROUTINE, "A & B", "c", null,
                routine().buttons)), amp);
        fires("R_AMPERSAND context", PopupSheet.violations(new Confirm(Tone.ROUTINE, "t", "A & B", null,
                routine().buttons)), amp);
        fires("R_AMPERSAND line", PopupSheet.violations(new Confirm(Tone.ROUTINE, "t", "c",
                Collections.singletonList(new Line("A & B", null)), routine().buttons)), amp);
        fires("R_AMPERSAND button", PopupSheet.violations(conf(Tone.ROUTINE, b("Save & go", Style.GREEN_FILLED),
                b(PopupSheet.NOT_NOW, Style.OUTLINED))), amp);
        fires("R_AMPERSAND picker title", PopupSheet.violations(new Picker("A & B",
                Collections.singletonList(opt("A", false)))), amp);
        fires("R_AMPERSAND option name", PopupSheet.violations(new Picker("T",
                Collections.singletonList(opt("A & B", false)))), amp);
        fires("R_AMPERSAND chip", PopupSheet.violations(new Picker("T", Collections.singletonList(
                new Option("A", Collections.singletonList("A & B"), "d", false)))), amp);
        fires("R_AMPERSAND description", PopupSheet.violations(new Picker("T", Collections.singletonList(
                new Option("A", null, "A & B", false)))), amp);

        for (String verb : PopupSheet.DESTRUCTIVE_VERBS) {
            fires("R_GREEN_DESTRUCTIVE " + verb, PopupSheet.violations(conf(Tone.ROUTINE,
                    b(verb + " it", Style.GREEN_FILLED), b(PopupSheet.NOT_NOW, Style.OUTLINED))),
                    PopupSheet.R_GREEN_DESTRUCTIVE);
        }
        fires("R_GREEN_DESTRUCTIVE any case", PopupSheet.violations(conf(Tone.ROUTINE, b("  delete it", Style.GREEN_FILLED),
                b(PopupSheet.NOT_NOW, Style.OUTLINED))), PopupSheet.R_GREEN_DESTRUCTIVE);
        check("R_GREEN_DESTRUCTIVE reads the first word only", PopupSheet.violations(conf(Tone.ROUTINE,
                b("Keep and wipe later", Style.GREEN_FILLED), b(PopupSheet.NOT_NOW, Style.OUTLINED))).isEmpty());
        check("the verb list is the agreed twelve", PopupSheet.DESTRUCTIVE_VERBS.size() == 12);

        fires("R_ROUTINE_BUTTONS no green", PopupSheet.violations(conf(Tone.ROUTINE, b("Do it", Style.OUTLINED))),
                PopupSheet.R_ROUTINE_BUTTONS);
        fires("R_ROUTINE_BUTTONS two green", PopupSheet.violations(conf(Tone.ROUTINE, b("Do it", Style.GREEN_FILLED),
                b("Do that", Style.GREEN_FILLED))), PopupSheet.R_ROUTINE_BUTTONS);
        fires("R_ROUTINE_BUTTONS a red outline", PopupSheet.violations(conf(Tone.ROUTINE, b("Do it", Style.GREEN_FILLED),
                b("Risk it", Style.RED_OUTLINED))), PopupSheet.R_ROUTINE_BUTTONS);
        fires("R_ROUTINE_BUTTONS no buttons", PopupSheet.violations(conf(Tone.ROUTINE)), PopupSheet.R_ROUTINE_BUTTONS);

        fires("R_WARNING_BUTTONS no green", PopupSheet.violations(conf(Tone.WARNING, b("Risk it", Style.RED_OUTLINED))),
                PopupSheet.R_WARNING_BUTTONS);
        fires("R_WARNING_BUTTONS no red outline", PopupSheet.violations(conf(Tone.WARNING,
                b("Try again", Style.GREEN_FILLED), b(PopupSheet.NOT_NOW, Style.OUTLINED))), PopupSheet.R_WARNING_BUTTONS);
        fires("R_WARNING_BUTTONS a red filled", PopupSheet.violations(conf(Tone.WARNING,
                b("Try again", Style.GREEN_FILLED), b("Risk it", Style.RED_OUTLINED), b("Delete", Style.RED_FILLED))),
                PopupSheet.R_WARNING_BUTTONS);

        fires("R_DESTRUCTIVE_GREEN", PopupSheet.violations(conf(Tone.DESTRUCTIVE, b("Delete it", Style.RED_FILLED),
                b("Keep it", Style.OUTLINED), b("Save first", Style.GREEN_FILLED))), PopupSheet.R_DESTRUCTIVE_GREEN);
        fires("R_DESTRUCTIVE_ORDER not first", PopupSheet.violations(conf(Tone.DESTRUCTIVE, b("Keep it", Style.OUTLINED),
                b("Delete it", Style.RED_FILLED))), PopupSheet.R_DESTRUCTIVE_ORDER);
        fires("R_DESTRUCTIVE_ORDER no Keep", PopupSheet.violations(conf(Tone.DESTRUCTIVE, b("Delete it", Style.RED_FILLED),
                b(PopupSheet.NOT_NOW, Style.OUTLINED))), PopupSheet.R_DESTRUCTIVE_ORDER);
        fires("R_DESTRUCTIVE_ORDER two red", PopupSheet.violations(conf(Tone.DESTRUCTIVE, b("Delete it", Style.RED_FILLED),
                b("Keep it", Style.OUTLINED), b("Erase it", Style.RED_FILLED))), PopupSheet.R_DESTRUCTIVE_ORDER);
        fires("R_DESTRUCTIVE_ORDER alone", PopupSheet.violations(conf(Tone.DESTRUCTIVE, b("Delete it", Style.RED_FILLED))),
                PopupSheet.R_DESTRUCTIVE_ORDER);

        fires("R_GOT_IT_TONE warning", PopupSheet.violations(conf(Tone.WARNING, b(PopupSheet.GOT_IT, Style.GREEN_FILLED))),
                PopupSheet.R_GOT_IT_TONE, PopupSheet.R_WARNING_BUTTONS);
        fires("R_GOT_IT_TONE destructive", PopupSheet.violations(conf(Tone.DESTRUCTIVE, b(PopupSheet.GOT_IT, Style.OUTLINED))),
                PopupSheet.R_GOT_IT_TONE, PopupSheet.R_DESTRUCTIVE_ORDER);

        fires("R_TWO_CURRENT", PopupSheet.violations(new Picker("T", Arrays.asList(opt("A", true), opt("B", true)))),
                PopupSheet.R_TWO_CURRENT);

        fires("R_EMPTY null confirm", PopupSheet.violations((Confirm) null), PopupSheet.R_EMPTY);
        fires("R_EMPTY null picker", PopupSheet.violations((Picker) null), PopupSheet.R_EMPTY);
        check("R_EMPTY null tone", PopupSheet.violations(new Confirm(null, null, null, null, null))
                .contains(PopupSheet.R_EMPTY));
        check("null strings and elements do not throw", PopupSheet.violations(new Confirm(Tone.DESTRUCTIVE, null, null,
                Arrays.asList((Line) null, new Line(null, null)),
                Arrays.asList((Button) null, new Button(null, null), new Button(null, Style.RED_FILLED))))
                .contains(PopupSheet.R_DESTRUCTIVE_ORDER));
        check("null picker parts do not throw", PopupSheet.violations(new Picker(null,
                Arrays.asList((Option) null, new Option(null, null, null, false)))).isEmpty());
    }

    private static Map<String, String> custom(String... kv) {
        Map<String, String> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    private static List<String> names(Picker p) {
        List<String> out = new ArrayList<>();
        for (Option o : p.options) out.add(o.name);
        return out;
    }

    private static int currents(Picker p) {
        int n = 0;
        for (Option o : p.options) if (o.current) n++;
        return n;
    }

    private static void chipsOf(String preset, String idle, String wipe) {
        check("chips of " + preset,
                Arrays.asList(idle, wipe).equals(PresetSheet.chips(ProfilePresets.valuesOf(preset))));
    }

    private static void picker() {
        Picker p = PresetSheet.picker(false, ProfilePresets.STANDARD, null);
        check("picker title", PresetPicker.CARD_TITLE.equals(p.title));
        check("picker has the five presets", ProfilePresets.PRESETS.equals(names(p)));
        check("picker marks the shown preset", currents(p) == 1 && p.options.get(1).current);
        check("picker clean", PopupSheet.violations(p).isEmpty());
        for (Option o : p.options) {
            check("picker description of " + o.name, PresetPicker.description(o.name).equals(o.description));
            check("picker chips of " + o.name, PresetSheet.chips(ProfilePresets.valuesOf(o.name)).equals(o.chips));
        }
        Map<String, String> saved = custom("idle", "30", "wipe", "4");
        Picker withCustom = PresetSheet.picker(true, ProfilePresets.CUSTOM, saved);
        List<String> six = new ArrayList<>(ProfilePresets.PRESETS);
        six.add(ProfilePresets.CUSTOM);
        check("picker lists Custom when saved", six.equals(names(withCustom)));
        check("picker marks Custom", currents(withCustom) == 1 && withCustom.options.get(5).current);
        check("picker Custom has the saved chips",
                Arrays.asList("Standby 30 min", "Wipe 1 day").equals(withCustom.options.get(5).chips));
        check("picker Custom has no description", withCustom.options.get(5).description.isEmpty());
        check("picker with Custom shown but not saved marks none", currents(PresetSheet.picker(false, ProfilePresets.CUSTOM, null)) == 0);

        chipsOf(ProfilePresets.UNSHIELDED, "Standby never", "Wipe at power-off");
        chipsOf(ProfilePresets.STANDARD, "Standby 15 min", "Wipe 12 h");
        chipsOf(ProfilePresets.HARDENED, "Standby 5 min", "Wipe 6 h");
        chipsOf(ProfilePresets.ISOLATED, "Standby 5 min", "Wipe 1 h");
        chipsOf(ProfilePresets.ZERO, "Standby 5 min", "Wipe once saved");
        check("chips idle 60", Collections.singletonList("Standby 1 h").equals(PresetSheet.chips(custom("idle", "60"))));
        check("chips wipe 4", Collections.singletonList("Wipe 1 day").equals(PresetSheet.chips(custom("wipe", "4"))));
        check("chips unknown", PresetSheet.chips(custom("idle", "7", "wipe", "9")).isEmpty());
        check("chips null", PresetSheet.chips(null).isEmpty());
    }

    private static void flow() {
        for (String preset : ProfilePresets.PRESETS) {
            for (int n : new int[] { 0, 1, 5 }) {
                Confirm c = PresetSheet.count(preset, n);
                check("count no violations " + preset + " " + n, PopupSheet.violations(c).isEmpty());
                check("count words " + preset + " " + n, preset.equals(c.title) && c.tone == Tone.ROUTINE
                        && PresetPicker.countLine(n).equals(c.context)
                        && "Review the changes".equals(c.buttons.get(0).label)
                        && PopupSheet.NOT_NOW.equals(c.buttons.get(1).label));
            }
            Map<String, String> from = ProfilePresets.valuesOf(ProfilePresets.ZERO.equals(preset)
                    ? ProfilePresets.UNSHIELDED : ProfilePresets.ZERO);
            List<String> real = ProfilePresets.previewLines(from, ProfilePresets.valuesOf(preset));
            for (int bits = 0; bits < 4; bits++) {
                boolean[] offered = { (bits & 1) != 0, (bits & 2) != 0 };
                List<String> links = PresetPicker.links(preset);
                Confirm c = PresetSheet.preview(preset, real, links, offered);
                check("preview no violations " + preset + " " + bits, PopupSheet.violations(c).isEmpty());
                check("preview words " + preset, preset.equals(c.title) && c.tone == Tone.ROUTINE
                        && PresetSheet.PREVIEW_CONTEXT.equals(c.context)
                        && ("Apply " + preset).equals(c.buttons.get(0).label)
                        && c.buttons.get(0).style == Style.GREEN_FILLED
                        && PopupSheet.NOT_NOW.equals(c.buttons.get(1).label));
                check("preview has every line and link " + preset, c.lines.size() == real.size() + 2);
                Line tie = c.lines.get(real.size());
                Line loc = c.lines.get(real.size() + 1);
                check("link case tie text " + preset, links.get(0).equals(tie.text));
                check("link case loc text " + preset, links.get(1).equals(loc.text));
                check("link case tie key " + preset + " " + bits,
                        offered[0] ? PresetSheet.LINK_TIE.equals(tie.linkKey) : tie.linkKey == null);
                check("link case loc key " + preset + " " + bits,
                        offered[1] ? PresetSheet.LINK_LOC.equals(loc.linkKey) : loc.linkKey == null);
                for (int i = 0; i < real.size(); i++) check("a change line is no link", c.lines.get(i).linkKey == null);
            }
        }
        Confirm none = PresetSheet.preview(ProfilePresets.HARDENED, Collections.<String>emptyList(),
                PresetPicker.links(ProfilePresets.HARDENED), new boolean[] { false, false });
        check("no changes says so", PresetPicker.NOTHING_CHANGES.equals(none.lines.get(0).text) && none.lines.size() == 3);
        Confirm custom = PresetSheet.preview(ProfilePresets.CUSTOM, Collections.singletonList("A: 1 → 2"),
                PresetPicker.links(ProfilePresets.CUSTOM), new boolean[0]);
        check("Custom has no link lines", custom.lines.size() == 1 && custom.lines.get(0).linkKey == null);
        check("Custom preview clean", PopupSheet.violations(custom).isEmpty());
    }

    public static void main(String[] args) {
        rules();
        picker();
        flow();
        if (failed > 0) {
            System.out.println("PopupSheetCases: " + failed + " failed");
            System.exit(1);
        }
        System.out.println("PopupSheetCases: ok");
    }
}
