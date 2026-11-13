package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * NWP-20261201-28: the Privacy level flow as PopupSheet models: the picker, the count of settings a pick changes, and
 * the preview with its consent links, in the order docs/product-decisions.md 2026-11-03 fixes. PresetPicker and
 * ProfilePresets hold the facts and do not know this class. The words here are drafts and make no privacy claim.
 *
 * Pure java.util so a javac suite can compile it off the build host (core/vendor-common/bin/test-popup-sheet-java.sh).
 */
final class PresetSheet {
    private PresetSheet() {}

    /** The link keys of a preview's two consent lines, in PresetPicker.links order. */
    static final String LINK_TIE = "tie";
    static final String LINK_LOC = "loc";

    static final String PREVIEW_CONTEXT = "These settings change:";

    /** One card per dropdownNames entry; the shown one is current. */
    static PopupSheet.Picker picker(boolean savedCustom, String shown, Map<String, String> savedCustomValues) {
        List<PopupSheet.Option> options = new ArrayList<>();
        for (String name : PresetPicker.dropdownNames(savedCustom)) {
            Map<String, String> values = ProfilePresets.CUSTOM.equals(name)
                    ? savedCustomValues : ProfilePresets.valuesOf(name);
            options.add(new PopupSheet.Option(name, chips(values), PresetPicker.description(name), name.equals(shown)));
        }
        return new PopupSheet.Picker(PresetPicker.CARD_TITLE, options);
    }

    /** The idle chip, then the wipe chip. A null map or an unknown value gives no chip. */
    static List<String> chips(Map<String, String> values) {
        if (values == null) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        String idle = idleChip(values.get("idle"));
        if (idle != null) out.add(idle);
        String wipe = wipeChip(values.get("wipe"));
        if (wipe != null) out.add(wipe);
        return Collections.unmodifiableList(out);
    }

    private static String idleChip(String value) {
        if (value == null) return null;
        switch (value) {
            case "5": return "Standby 5 min";
            case "15": return "Standby 15 min";
            case "30": return "Standby 30 min";
            case "60": return "Standby 1 h";
            case "0": return "Standby never";
            default: return null;
        }
    }

    private static String wipeChip(String value) {
        if (value == null) return null;
        switch (value) {
            case "0": return "Wipe once saved";
            case "1": return "Wipe 1 h";
            case "2": return "Wipe 6 h";
            case "3": return "Wipe 12 h";
            case "4": return "Wipe 1 day";
            case "5": return "Wipe at power-off";
            default: return null;
        }
    }

    /** How many settings a pick changes, before the preview. */
    static PopupSheet.Confirm count(String picked, int n) {
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, picked, PresetPicker.countLine(n),
                Collections.<PopupSheet.Line>emptyList(),
                Arrays.asList(new PopupSheet.Button("Review the changes", PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    /** One line per change (or NOTHING_CHANGES), then every consent line. A consent line is a link only where offered
     *  says its screen is offered. */
    static PopupSheet.Confirm preview(String picked, List<String> lines, List<String> links, boolean[] offered) {
        List<PopupSheet.Line> out = new ArrayList<>();
        if (lines == null || lines.isEmpty()) out.add(new PopupSheet.Line(PresetPicker.NOTHING_CHANGES, null));
        else for (String l : lines) out.add(new PopupSheet.Line(l, null));
        if (links != null) {
            for (int i = 0; i < links.size(); i++) {
                boolean open = offered != null && i < offered.length && offered[i];
                out.add(new PopupSheet.Line(links.get(i), open ? linkKey(i) : null));
            }
        }
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, picked, PREVIEW_CONTEXT, out,
                Arrays.asList(new PopupSheet.Button("Apply " + picked, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)));
    }

    private static String linkKey(int index) {
        return index == 0 ? LINK_TIE : LINK_LOC;
    }
}
