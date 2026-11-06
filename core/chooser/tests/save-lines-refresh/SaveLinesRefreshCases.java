package com.nowhere.chooser;

/** SaveLinesRefresh: when Your data repaints its save lines after a save lands (NWP-20261121-04). Run by
 *  core/vendor-common/bin/test-save-lines-refresh-java.sh, compiled with BackNowCycle.java (parseLanded's parser). */
public final class SaveLinesRefreshCases {
    private static final long N = SaveLinesRefresh.NOTHING;
    private static int fails = 0;

    private static void eq(String what, Object want, Object got) {
        if (!want.equals(got)) { fails++; System.out.println("  FAIL  " + what + ": want " + want + ", got " + got); }
    }

    public static void main(String[] a) {
        eq("NOTHING is -1", -1L, N);
        eq("POLL_MS is 15 s", 15_000L, SaveLinesRefresh.POLL_MS);

        // parseLanded: GET-SEAL-LANDED's "OK <unix seconds>"; NOTHING for anything else.
        eq("parse OK 123", 123L, SaveLinesRefresh.parseLanded("OK 123"));
        eq("parse OK 0", 0L, SaveLinesRefresh.parseLanded("OK 0"));
        eq("parse padded", 7L, SaveLinesRefresh.parseLanded(" OK 7 \n"));
        for (String s : new String[] { null, "", "ERR", "OK", "OK x", "OK 1 2", "OK -3", "OK 99999999999999999999" }) {
            eq("parse [" + s + "] is NOTHING", N, SaveLinesRefresh.parseLanded(s));
        }

        // due 1: the first stamp seeds; the same stamp is not due; a new one is.
        SaveLinesRefresh r = new SaveLinesRefresh();
        eq("due1 seed", false, r.due(100, false));
        eq("due1 same", false, r.due(100, false));
        eq("due1 new", true, r.due(200, false));

        // due 2: a hold leaves a new stamp due, so the next tick without the hold fires.
        r = new SaveLinesRefresh();
        r.due(100, false);
        eq("due2 held", false, r.due(200, true));
        eq("due2 released", true, r.due(200, false));

        // due 3: NOTHING is never due and changes nothing.
        r = new SaveLinesRefresh();
        eq("due3 NOTHING first", false, r.due(N, false));
        eq("due3 still seeds", false, r.due(5, false));
        eq("due3 after seed", true, r.due(6, false));
        r = new SaveLinesRefresh();
        r.due(100, false);
        eq("due3 NOTHING after seed", false, r.due(N, false));
        eq("due3 seed kept", false, r.due(100, false));

        // due 4: painted() records the stamp the load painted for; NOTHING keeps it.
        r = new SaveLinesRefresh();
        r.due(100, false);
        r.painted(200);
        eq("due4 painted s2", false, r.due(200, false));
        r.painted(N);
        eq("due4 painted NOTHING keeps s2", false, r.due(200, false));
        eq("due4 next", true, r.due(300, false));

        // due 5: no save since sign-in (0), then a real save.
        r = new SaveLinesRefresh();
        r.due(0, false);
        eq("due5 0 then real", true, r.due(1_700_000_000L, false));

        // due 6: painted() seeds too.
        r = new SaveLinesRefresh();
        r.painted(300);
        eq("due6 painted seed same", false, r.due(300, false));
        eq("due6 painted seed new", true, r.due(400, false));

        // keepPolling: only its own screen, attached, with the activity alive.
        for (int i = 0; i < 8; i++) {
            boolean same = (i & 4) != 0, att = (i & 2) != 0, fin = (i & 1) != 0;
            eq("keepPolling(" + same + "," + att + "," + fin + ")", same && att && !fin,
                    SaveLinesRefresh.keepPolling(same, att, fin));
        }

        if (fails > 0) { System.out.println("FAIL: " + fails + " case(s)"); System.exit(1); }
        System.out.println("PASS: SaveLinesRefresh cases");
    }
}
