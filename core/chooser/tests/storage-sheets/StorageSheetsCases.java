package com.nowhere.chooser;

import java.util.List;

/**
 * NWP-20261204-17: StorageSheets' three picker models under javac (core/vendor-common/bin/test-storage-sheets-java.sh).
 * Each failure prints "  FAIL  <label> -- <detail>"; the suite's mutants name the label that must convict them.
 */
public final class StorageSheetsCases {
    private static int run;
    private static int failed;

    private static void check(String label, boolean ok, String detail) {
        run++;
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + label + " -- " + detail);
    }

    private static int currentCount(PopupSheet.Picker p) {
        int n = 0;
        for (PopupSheet.Option o : p.options) if (o.current) n++;
        return n;
    }

    private static int currentIndex(PopupSheet.Picker p) {
        for (int i = 0; i < p.options.size(); i++) if (p.options.get(i).current) return i;
        return -1;
    }

    private static boolean chipsEmpty(PopupSheet.Picker p) {
        for (PopupSheet.Option o : p.options) if (!o.chips.isEmpty()) return false;
        return true;
    }

    /** The cases a picker over values/labels/trade-offs must pass when value v is the current one. */
    private static void valued(String what, PopupSheet.Picker p, String[] values, String[] labels, String[] tradeoffs, String v) {
        String pre = what + "(" + v + ") ";
        check(pre + "options", p.options.size() == values.length, "want " + values.length + ", got " + p.options.size());
        if (p.options.size() != values.length) return;
        boolean names = true, descs = true;
        for (int i = 0; i < values.length; i++) {
            PopupSheet.Option o = p.options.get(i);
            if (!labels[i].equals(o.name)) names = false;
            if (o.description == null || !o.description.equals(tradeoffs[i]) || o.description.equals(o.name)) descs = false;
        }
        check(pre + "names", names, "names are not the labels");
        check(pre + "descriptions", descs, "descriptions are not the trade-off lines");
        check(pre + "chips", chipsEmpty(p), "an option has a chip");
        int want = -1;
        for (int i = 0; i < values.length; i++) if (values[i].equals(v)) want = i;
        check(pre + "current", currentCount(p) == 1 && currentIndex(p) == want,
                "want exactly one current at " + want + ", got " + currentCount(p) + " (first at " + currentIndex(p) + ")");
        List<String> bad = PopupSheet.violations(p);
        check(pre + "violations", bad.isEmpty(), bad.toString());
    }

    private static void none(String label, PopupSheet.Picker p, int size) {
        check(label, p.options.size() == size && currentCount(p) == 0,
                "want " + size + " options and none current, got " + p.options.size() + " and " + currentCount(p));
    }

    public static void main(String[] args) {
        String[] sealLabels = new String[SealHold.VALUES.length], sealTrade = new String[SealHold.VALUES.length];
        for (int i = 0; i < SealHold.VALUES.length; i++) {
            sealLabels[i] = SealHold.label(SealHold.VALUES[i]);
            sealTrade[i] = SealHold.tradeoff(SealHold.VALUES[i]);
        }
        check("sealHold title", "Backups while apps set up".equals(StorageSheets.sealHold("2").title),
                StorageSheets.sealHold("2").title);
        check("sealHold values", SealHold.VALUES.length == 4, "want 4 SealHold values, got " + SealHold.VALUES.length);
        for (String v : SealHold.VALUES) valued("sealHold", StorageSheets.sealHold(v), SealHold.VALUES, sealLabels, sealTrade, v);
        none("sealHold(bogus) current", StorageSheets.sealHold("bogus"), SealHold.VALUES.length);
        none("sealHold(null) current", StorageSheets.sealHold(null), SealHold.VALUES.length);
        check("sealHold(bogus) violations", PopupSheet.violations(StorageSheets.sealHold("bogus")).isEmpty(), "breaches");

        String[] saveLabels = new String[SaveMode.VALUES.length], saveTrade = new String[SaveMode.VALUES.length];
        for (int i = 0; i < SaveMode.VALUES.length; i++) {
            saveLabels[i] = SaveMode.label(SaveMode.VALUES[i]);
            saveTrade[i] = SaveMode.tradeoff(SaveMode.VALUES[i]);
        }
        check("saveMode title", "Save automatically".equals(StorageSheets.saveMode("always").title),
                StorageSheets.saveMode("always").title);
        check("saveMode values", SaveMode.VALUES.length == 3, "want 3 SaveMode values, got " + SaveMode.VALUES.length);
        for (String v : SaveMode.VALUES) valued("saveMode", StorageSheets.saveMode(v), SaveMode.VALUES, saveLabels, saveTrade, v);
        none("saveMode(bogus) current", StorageSheets.saveMode("bogus"), SaveMode.VALUES.length);
        none("saveMode(null) current", StorageSheets.saveMode(null), SaveMode.VALUES.length);
        check("saveMode(bogus) violations", PopupSheet.violations(StorageSheets.saveMode("bogus")).isEmpty(), "breaches");

        CharSequence[] names = { "Never", "1 day", "3 days", "1 week" };
        check("reclaim title", "Re-archive idle apps".equals(StorageSheets.reclaim(names, 0).title),
                StorageSheets.reclaim(names, 0).title);
        for (int k = 0; k < names.length; k++) {
            PopupSheet.Picker p = StorageSheets.reclaim(names, k);
            String pre = "reclaim(" + k + ") ";
            boolean same = p.options.size() == names.length;
            for (int i = 0; same && i < names.length; i++) {
                PopupSheet.Option o = p.options.get(i);
                if (!names[i].toString().equals(o.name) || o.description != null || !o.chips.isEmpty()) same = false;
            }
            check(pre + "names", same, "want the four names, no description, no chip");
            check(pre + "current", currentCount(p) == 1 && currentIndex(p) == k,
                    "want exactly one current at " + k + ", got " + currentCount(p) + " (first at " + currentIndex(p) + ")");
            List<String> bad = PopupSheet.violations(p);
            check(pre + "violations", bad.isEmpty(), bad.toString());
        }
        none("reclaim(-1) current", StorageSheets.reclaim(names, -1), names.length);
        none("reclaim(4) current", StorageSheets.reclaim(names, 4), names.length);
        boolean ok;
        try {
            ok = StorageSheets.reclaim(null, 0).options.isEmpty();
        } catch (RuntimeException e) {
            ok = false;
        }
        check("reclaim(null) options", ok, "want zero options and no throw");

        System.out.println("storage-sheets cases: " + run + " run, " + failed + " failed");
        if (failed != 0) System.exit(1);
    }
}
