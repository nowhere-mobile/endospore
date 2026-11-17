package com.nowhere.chooser;

import java.util.Arrays;
import java.util.List;

import com.nowhere.chooser.PopupSheet.Boxes;
import com.nowhere.chooser.PopupSheet.Option;
import com.nowhere.chooser.PopupSheet.Picker;

/** NWP-20261206-04: Auto standby when idle as a sheet of cards with two boxes. Each failure line names its case. */
final class StandbySheetCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static int currentCount(Picker p) {
        int n = 0;
        for (Option o : p.options) if (o.current) n++;
        return n;
    }

    public static void main(String[] args) {
        // C1: the timeouts and the default.
        check("C1 MINS is { 5, 15, 30, 60, 0 }: " + Arrays.toString(StandbySheets.MINS),
                Arrays.equals(StandbySheets.MINS, new int[] { 5, 15, 30, 60, 0 }));
        check("C1 DEFAULT_MINUTES is 15", StandbySheets.DEFAULT_MINUTES == 15);

        // C2: the words, verbatim.
        check("C2 LABELS verbatim: " + Arrays.toString(StandbySheets.LABELS), Arrays.equals(StandbySheets.LABELS,
                new String[] { "After 5 minutes", "After 15 minutes", "After 30 minutes", "After 1 hour", "Never" }));
        check("C2 TITLE", "Auto standby when idle".equals(StandbySheets.TITLE));
        check("C2 WAIT_HEAD", "Before standby, wait for:".equals(StandbySheets.WAIT_HEAD));
        check("C2 BOX_KEYS", Arrays.equals(StandbySheets.BOX_KEYS, new String[] { "holdlock", "holdaudio" }));
        check("C2 BOX_LABELS", Arrays.equals(StandbySheets.BOX_LABELS, new String[] { "app installs", "audio playing" }));

        // C3: which card idle= marks current.
        check("C3 current(\"\") is 1", StandbySheets.current("") == 1);
        check("C3 current(\"x\") is 1", StandbySheets.current("x") == 1);
        check("C3 current(null) is 1", StandbySheets.current(null) == 1);
        check("C3 current(\"5\") is 0", StandbySheets.current("5") == 0);
        check("C3 current(\"15\") is 1", StandbySheets.current("15") == 1);
        check("C3 current(\"60\") is 3", StandbySheets.current("60") == 3);
        check("C3 current(\"0\") is 4", StandbySheets.current("0") == 4);
        check("C3 current(\"2\") is -1: " + StandbySheets.current("2"), StandbySheets.current("2") == -1);

        // C4: the picker: one card per label, no chips, one current only at k.
        for (int k = 0; k < StandbySheets.LABELS.length; k++) {
            Picker p = StandbySheets.picker(k);
            check("C4 picker(" + k + ") title", StandbySheets.TITLE.equals(p.title));
            check("C4 picker(" + k + ") has 5 cards", p.options.size() == 5);
            for (int i = 0; i < p.options.size(); i++) {
                Option o = p.options.get(i);
                check("C4 picker(" + k + ") card " + i + " name", StandbySheets.LABELS[i].equals(o.name));
                check("C4 picker(" + k + ") card " + i + " has no chips", o.chips.isEmpty());
                check("C4 picker(" + k + ") card " + i + " current only at " + k, o.current == (i == k));
            }
            check("C4 picker(" + k + ") has one current", currentCount(p) == 1);
        }
        check("C4 picker(-1) has none current", currentCount(StandbySheets.picker(-1)) == 0);
        check("C4 picker(5) has none current", currentCount(StandbySheets.picker(5)) == 0);

        // C5: the boxes: checked unless "0".
        Boxes b = StandbySheets.boxes("", "0");
        check("C5 boxes(\"\", \"0\") is [on, off]: " + b.checked, b.checked.equals(Arrays.asList(true, false)));
        b = StandbySheets.boxes("0", "");
        check("C5 boxes(\"0\", \"\") is [off, on]: " + b.checked, b.checked.equals(Arrays.asList(false, true)));
        check("C5 boxes(null, null) is [on, on]", StandbySheets.boxes(null, null).checked.equals(Arrays.asList(true, true)));
        check("C5 boxes heading", StandbySheets.WAIT_HEAD.equals(b.heading));
        check("C5 boxes labels", b.labels.equals(Arrays.asList(StandbySheets.BOX_LABELS)));

        // C6: what a box writes.
        check("C6 boxValue(true) is \"\"", "".equals(StandbySheets.boxValue(true)));
        check("C6 boxValue(false) is \"0\"", "0".equals(StandbySheets.boxValue(false)));

        // C7: the toast, today's text when a card is current.
        check("C7 toast(1, true): " + StandbySheets.toast(1, true),
                "Auto standby when idle: after 15 minutes".equals(StandbySheets.toast(1, true)));
        check("C7 toast(1, false): " + StandbySheets.toast(1, false),
                "Auto standby when idle: after 15 minutes — applies next sign-in".equals(StandbySheets.toast(1, false)));
        check("C7 toast(4, true): " + StandbySheets.toast(4, true),
                "Auto standby when idle: never".equals(StandbySheets.toast(4, true)));
        check("C7 toast(-1, true) is TITLE: " + StandbySheets.toast(-1, true),
                StandbySheets.TITLE.equals(StandbySheets.toast(-1, true)));
        check("C7 toast(-1, false) ends \" — applies next sign-in\"",
                (StandbySheets.TITLE + " — applies next sign-in").equals(StandbySheets.toast(-1, false)));

        // C8: both models keep the sheet's rules.
        for (int k = -1; k < StandbySheets.LABELS.length; k++) {
            check("C8 violations(picker(" + k + ")) is empty", PopupSheet.violations(StandbySheets.picker(k)).isEmpty());
        }
        check("C8 violations(boxes) is empty", PopupSheet.violations(StandbySheets.boxes("", "")).isEmpty());
        check("C8 violations(boxes 0 0) is empty", PopupSheet.violations(StandbySheets.boxes("0", "0")).isEmpty());

        // C9: the Boxes rules.
        List<String> v = PopupSheet.violations(new Boxes("Wait & see", Arrays.asList("a"), Arrays.asList(true)));
        check("C9 an \"&\" heading fires R_AMPERSAND: " + v, v.equals(Arrays.asList(PopupSheet.R_AMPERSAND)));
        v = PopupSheet.violations(new Boxes("Wait", Arrays.asList("a", "b & c"), Arrays.asList(true, false)));
        check("C9 an \"&\" label fires R_AMPERSAND: " + v, v.equals(Arrays.asList(PopupSheet.R_AMPERSAND)));
        v = PopupSheet.violations(new Boxes("Wait", Arrays.asList("a", "b"), Arrays.asList(true)));
        check("C9 a size mismatch fires R_EMPTY: " + v, v.equals(Arrays.asList(PopupSheet.R_EMPTY)));
        v = PopupSheet.violations((Boxes) null);
        check("C9 null fires R_EMPTY: " + v, v.equals(Arrays.asList(PopupSheet.R_EMPTY)));
        v = PopupSheet.violations(new Boxes(null, null, null));
        check("C9 empty lists never throw and fire nothing: " + v, v.isEmpty());

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
