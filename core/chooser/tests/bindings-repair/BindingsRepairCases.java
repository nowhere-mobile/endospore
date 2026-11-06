package com.nowhere.chooser;

/** Cases for BindingsRepair (NWP-20261110-06). An exception in a case is a FAIL, not a crash. */
public final class BindingsRepairCases {
    private static int failed = 0, ran = 0;

    private static void check(String name, boolean cond) {
        ran++;
        if (!cond) { failed++; System.out.println("--- FAIL " + name); }
    }

    private static String show(String r) { return r == null ? "null" : "\"" + r.replace("\r", "\\r") + "\""; }

    private static boolean noDigit(String s) { return s != null && !s.matches("(?s).*[0-9].*"); }

    public static void main(String[] args) {
        try {
            run();
        } catch (Throwable t) {
            failed++;
            System.out.println("--- FAIL threw " + t);
        }
        System.out.println(ran + " checks, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }

    private static void run() {
        String[] fails = { BindingsRepair.BUSY, BindingsRepair.IO, BindingsRepair.FAILED };
        // O1: each OK form is a success line, the one for its form, and reloads.
        String[][] oks = {
            { "OK REPAIRED 2", BindingsRepair.REPAIRED }, { "OK REPAIRED 0", BindingsRepair.REPAIRED },
            { "OK REPLACED", BindingsRepair.REPLACED }, { "OK CLEAN", BindingsRepair.CLEAN }, { "OK CLEAN\r", BindingsRepair.CLEAN },
        };
        for (String[] c : oks) {
            String got = BindingsRepair.outcome(c[0]);
            check("O1 ok(" + show(c[0]) + ")", BindingsRepair.ok(c[0]));
            check("O1 outcome(" + show(c[0]) + ") is its success line, got " + show(got), c[1].equals(got));
            for (String f : fails) check("O1 outcome(" + show(c[0]) + ") is not a failure line", !f.equals(got));
        }
        // O2: the failures, and not one of them reloads.
        check("O2 BUSY is the busy line", BindingsRepair.BUSY.equals(BindingsRepair.outcome("BUSY")));
        check("O2 BUSY says busy and try again", BindingsRepair.outcome("BUSY").equals("the phone is busy — try again"));
        String io = BindingsRepair.outcome("ERR io");
        check("O2 ERR io is the io line, got " + show(io), BindingsRepair.IO.equals(io));
        check("O2 the ERR io line names a reset", io.toLowerCase().contains("reset"));
        check("O2 the ERR io line names the storage", io.contains("storage"));
        check("O2 the ERR io line says it could not repair", io.startsWith("Couldn't repair"));
        String[] other = { "DENIED", "", null, "OK REPAIRED", "OK REPAIRED x", "OK", "ERR", "ERR damaged", "NO" };
        for (String r : other)
            check("O2 outcome(" + show(r) + ") is couldn't repair -- try again", "couldn't repair — try again".equals(BindingsRepair.outcome(r)));
        String[] notOk = { "BUSY", "ERR io", "DENIED", "", null, "OK REPAIRED", "OK REPAIRED x", "OK", "ERR", "ERR damaged", "NO" };
        for (String r : notOk) check("O2 ok(" + show(r) + ") is false", !BindingsRepair.ok(r));
        // O3: no line holds a digit -- never a count of SIMs, lines or owners.
        java.util.List<String> all = new java.util.ArrayList<>();
        for (String[] c : oks) all.add(c[0]);
        for (String r : notOk) all.add(r);
        for (String r : all) check("O3 outcome(" + show(r) + ") holds no digit", noDigit(BindingsRepair.outcome(r)));
        check("O3 CONFIRM holds no digit", noDigit(BindingsRepair.CONFIRM));
        check("O3 ROW, ROW_SUMMARY and TITLE hold no digit",
                noDigit(BindingsRepair.ROW) && noDigit(BindingsRepair.ROW_SUMMARY) && noDigit(BindingsRepair.TITLE));
        // O4: what the confirmation says, and the decided row name.
        String c = BindingsRepair.CONFIRM;
        check("O4 CONFIRM says it keeps every readable binding", c.contains("keeps every SIM binding"));
        check("O4 CONFIRM says it drops the damaged ones", c.contains("drops the damaged"));
        check("O4 CONFIRM says an unbound SIM is not this phone's own line", c.contains("not this phone's own line"));
        check("O4 CONFIRM says its texts and calls can't be kept until bound or marked", c.contains("can't be kept until it is bound or marked"));
        check("O4 ROW is the decided name", "Repair SIM bindings".equals(BindingsRepair.ROW));
    }
}
