package com.nowhere.chooser;

import java.util.List;

/** NWP-20261204-18: the cases of core/vendor-common/bin/test-gate-sheets-java.sh. They compare against literals, not
 *  against GateSheets' own constants, so a changed constant fails here. */
public final class GateSheetsCases {
    private static int failed;
    private static int passed;

    private static void check(String name, boolean ok) {
        if (ok) { passed++; return; }
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static boolean noneCurrent(List<PopupSheet.Option> options) {
        for (PopupSheet.Option o : options) if (o.current) return false;
        return true;
    }

    private static boolean plain(List<PopupSheet.Option> options) {
        for (PopupSheet.Option o : options) if (!o.chips.isEmpty() || !"".equals(o.description)) return false;
        return true;
    }

    private static boolean named(List<PopupSheet.Option> options, String[] want) {
        if (options.size() != want.length) return false;
        for (int i = 0; i < want.length; i++) if (!want[i].equals(options.get(i).name)) return false;
        return true;
    }

    public static void main(String[] args) {
        PopupSheet.Picker s = GateSheets.sync(SyncChoices.LABELS);
        check("sync title", "Back up my data".equals(s.title));
        check("sync count", s.options.size() == SyncChoices.LABELS.length);
        check("sync names", named(s.options, SyncChoices.LABELS));
        check("sync none current", noneCurrent(s.options));
        check("sync plain cards", plain(s.options));
        check("sync clean", PopupSheet.violations(s).isEmpty());

        CharSequence[] devices = {"Pixel 7a", new StringBuilder("Fairphone 3"), "lynx"};
        PopupSheet.Picker r = GateSheets.restore(devices);
        check("restore title", "Restore data from…".equals(r.title));
        check("restore count", r.options.size() == 3);
        check("restore names", named(r.options, new String[] {"Pixel 7a", "Fairphone 3", "lynx"}));
        check("restore none current", noneCurrent(r.options));
        check("restore plain cards", plain(r.options));
        check("restore clean", PopupSheet.violations(r).isEmpty());

        PopupSheet.Picker none;
        try {
            none = GateSheets.restore(null);
        } catch (RuntimeException e) {
            none = null;
        }
        check("restore null labels", none != null && none.options.isEmpty());

        if (failed > 0) {
            System.out.println("GateSheetsCases: " + failed + " check(s) failed");
            System.exit(1);
        }
        System.out.println("GateSheetsCases: " + passed + " checks passed");
    }
}
