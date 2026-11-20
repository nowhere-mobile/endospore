package com.nowhere.chooser;

/** NWP-20261205-09: HarnessExtras.honour under javac, alone (h57 #8). Exit 0 all pass, 1 a case failed. */
public final class HarnessExtrasCases {
    private static int failed = 0;

    private static void check(String id, boolean got, boolean want, String what) {
        if (got == want) {
            System.out.println("ok " + id + " " + what);
        } else {
            System.out.println("FAIL " + id + " " + what + ": got " + got + ", want " + want);
            failed++;
        }
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s + "\"";
    }

    public static void main(String[] args) {
        // H1: a debuggable build with both extras signs in.
        check("H1", HarnessExtras.honour("1", "p", "w"), true, "honour(\"1\", p, w)");
        // H2: anything but exactly "1" is not debuggable. "0" is a user build; "" and null are a denied or empty read.
        for (String d : new String[] {"0", "", null, "true", " 1"}) {
            check("H2", HarnessExtras.honour(d, "p", "w"), false, "honour(" + show(d) + ", p, w)");
        }
        // H3: a debuggable build still needs both extras.
        check("H3", HarnessExtras.honour("1", null, "w"), false, "honour(\"1\", null, w)");
        check("H3", HarnessExtras.honour("1", "p", null), false, "honour(\"1\", p, null)");
        System.exit(failed == 0 ? 0 : 1);
    }
}
