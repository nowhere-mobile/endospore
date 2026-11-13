package com.nowhere.chooser;

/** NWP-20261202-04: the cases of VpnReportKeys, compiled with it ALONE by run.sh. Each check prints "ok   <name>" or
 *  "FAIL <name>"; every name starts with its case id and a space ("c2 ", "c2b "), so a mutant names the case it fails. */
public final class VpnReportKeysCases {
    private static int fails = 0, checks = 0;
    private static final java.util.List<Object[]> built = new java.util.ArrayList<>();

    private static void check(String name, boolean ok, Object got) {
        checks++;
        if (ok) {
            System.out.println("ok   " + name);
        } else {
            fails++;
            System.out.println("FAIL " + name + " -- got " + got);
        }
    }

    /** keys(...) with its inputs kept for c9. */
    private static java.util.LinkedHashMap<String, String> k(String label, String rec, String pick, boolean liveRead,
            String liveApp, String liveLock, String livePend) {
        java.util.LinkedHashMap<String, String> m = VpnReportKeys.keys(rec, pick, liveRead, liveApp, liveLock, livePend);
        built.add(new Object[] {label, m, new String[] {rec, pick, liveApp, liveLock, livePend}});
        return m;
    }

    /** The WHOLE map, keys and order, against the expected pairs: a missing or extra key fails. */
    private static void expect(String name, java.util.LinkedHashMap<String, String> m, String... kv) {
        java.util.LinkedHashMap<String, String> want = new java.util.LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) want.put(kv[i], kv[i + 1]);
        boolean ok = new java.util.ArrayList<>(want.entrySet()).equals(new java.util.ArrayList<>(m.entrySet()));
        check(name, ok, m + " want " + want);
    }

    private static final java.util.Map<String, java.util.Set<String>> ALLOWED = new java.util.HashMap<>();
    static {
        java.util.Set<String> file = new java.util.HashSet<>(java.util.Arrays.asList("none", "off", "set", "unreadable"));
        ALLOWED.put("vpn_record", file);
        ALLOWED.put("vpn_pick", file);
        ALLOWED.put("vpn_record_block", new java.util.HashSet<>(java.util.Arrays.asList("0", "1")));
        ALLOWED.put("vpn_live", new java.util.HashSet<>(java.util.Arrays.asList("unread", "none", "record", "other")));
        ALLOWED.put("vpn_live_block", new java.util.HashSet<>(java.util.Arrays.asList("1", "0", "unset", "other")));
        ALLOWED.put("vpn_live_pending", new java.util.HashSet<>(java.util.Arrays.asList("none", "live", "other")));
    }

    public static void main(String[] args) {
        String recX0 = "app=com.x\nlockdown=0\n";
        String recY0 = "app=com.y\nlockdown=0\n";
        String off0 = "app=\nlockdown=0\n";

        // c1: the NW-e39d98931a8f shape -- the captured choice is off, the live block is on.
        expect("c1 record com.x block 0, live com.x block 1 no pending",
                k("c1", recX0, null, true, "com.x", "1", null),
                "vpn_record", "set", "vpn_record_block", "0", "vpn_pick", "none",
                "vpn_live", "record", "vpn_live_block", "1", "vpn_live_pending", "none");

        // c2: consent pending with NO record file; pending compares with the LIVE app.
        expect("c2 no record, live com.x pending com.x",
                k("c2", null, null, true, "com.x", "0", "com.x"),
                "vpn_record", "none", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "0", "vpn_live_pending", "live");
        expect("c2b record com.y, live com.x pending com.x",
                k("c2b", recY0, null, true, "com.x", "0", "com.x"),
                "vpn_record", "set", "vpn_record_block", "0", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "0", "vpn_live_pending", "live");
        expect("c2c pending names another package than the live app",
                k("c2c", recX0, null, true, "com.x", "0", "com.y"),
                "vpn_record", "set", "vpn_record_block", "0", "vpn_pick", "none",
                "vpn_live", "record", "vpn_live_block", "0", "vpn_live_pending", "other");

        // c3: the live app is another package than the record's.
        expect("c3 record com.y, live com.x",
                k("c3", recY0, null, true, "com.x", "1", null),
                "vpn_record", "set", "vpn_record_block", "0", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "1", "vpn_live_pending", "none");

        // c4: the Secure reads threw.
        expect("c4 liveRead false gives unread and no live block or pending",
                k("c4", recX0, null, false, "com.x", "1", "com.x"),
                "vpn_record", "set", "vpn_record_block", "0", "vpn_pick", "none", "vpn_live", "unread");

        // c5: no record, no pick.
        expect("c5 no record and no pick",
                k("c5", null, null, true, null, null, null),
                "vpn_record", "none", "vpn_pick", "none",
                "vpn_live", "none", "vpn_live_block", "unset", "vpn_live_pending", "none");

        // c6: app= empty is off, with no block key.
        expect("c6 record app= empty lockdown 0 is off with no block",
                k("c6", off0, null, true, null, null, null),
                "vpn_record", "off", "vpn_pick", "none",
                "vpn_live", "none", "vpn_live_block", "unset", "vpn_live_pending", "none");
        expect("c6 record app= empty lockdown 1 is off with no block",
                k("c6b", "app=\nlockdown=1\n", null, true, null, null, null),
                "vpn_record", "off", "vpn_pick", "none",
                "vpn_live", "none", "vpn_live_block", "unset", "vpn_live_pending", "none");
        expect("c6 pick app= empty lockdown 0 is off",
                k("c6c", null, off0, true, null, null, null),
                "vpn_record", "none", "vpn_pick", "off",
                "vpn_live", "none", "vpn_live_block", "unset", "vpn_live_pending", "none");
        expect("c6 a record that is off never gives vpn_live=record",
                k("c6d", off0, null, true, "com.x", "0", null),
                "vpn_record", "off", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "0", "vpn_live_pending", "none");

        // c7: everything vpn_choice passes over is unreadable, with no block key.
        String[][] bad = {
            {"bad package com/x", "app=com/x\nlockdown=0\n"},
            {"lockdown 7", "app=com.x\nlockdown=7\n"},
            {"no app line", "lockdown=0\n"},
            {"app= empty lockdown 7", "app=\nlockdown=7\n"},
            {"no lockdown line", "app=com.x\n"},
            {"a read error", VpnReportKeys.UNREADABLE},
        };
        for (String[] b : bad) {
            expect("c7 record " + b[0] + " is unreadable",
                    k("c7 record " + b[0], b[1], null, false, null, null, null),
                    "vpn_record", "unreadable", "vpn_pick", "none", "vpn_live", "unread");
            expect("c7 pick " + b[0] + " is unreadable",
                    k("c7 pick " + b[0], null, b[1], false, null, null, null),
                    "vpn_record", "none", "vpn_pick", "unreadable", "vpn_live", "unread");
        }

        // c8: the live strings' edge values.
        expect("c8 live app \"null\" is none",
                k("c8", null, null, true, "null", "0", "null"),
                "vpn_record", "none", "vpn_pick", "none",
                "vpn_live", "none", "vpn_live_block", "0", "vpn_live_pending", "none");
        expect("c8 live lock \"2\" is other",
                k("c8b", null, null, true, "com.x", "2", null),
                "vpn_record", "none", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "other", "vpn_live_pending", "none");
        expect("c8 live lock null is unset",
                k("c8c", null, null, true, "com.x", null, null),
                "vpn_record", "none", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "unset", "vpn_live_pending", "none");
        expect("c8 live lock \"null\" is other",
                k("c8d", null, null, true, "com.x", "null", null),
                "vpn_record", "none", "vpn_pick", "none",
                "vpn_live", "other", "vpn_live_block", "other", "vpn_live_pending", "none");

        // c10: the first app= and the first lockdown= line win, as vpn_choice's head -n 1.
        expect("c10 first app= and first lockdown= line win",
                k("c10", "app=com.x\napp=com.y\nlockdown=1\nlockdown=0\n", null, true, "com.x", "1", null),
                "vpn_record", "set", "vpn_record_block", "1", "vpn_pick", "none",
                "vpn_live", "record", "vpn_live_block", "1", "vpn_live_pending", "none");
        expect("c10 the pick is not compared with the live app",
                k("c10b", null, recX0, true, "com.x", "1", null),
                "vpn_record", "none", "vpn_pick", "set",
                "vpn_live", "other", "vpn_live_block", "1", "vpn_live_pending", "none");

        // c9: every map built above holds only its key's fixed tokens, and no value carries input text.
        for (Object[] b : built) {
            String label = (String) b[0];
            @SuppressWarnings("unchecked")
            java.util.LinkedHashMap<String, String> m = (java.util.LinkedHashMap<String, String>) b[1];
            String[] in = (String[]) b[2];
            boolean ok = true;
            for (java.util.Map.Entry<String, String> e : m.entrySet()) {
                String v = e.getValue();
                java.util.Set<String> allowed = ALLOWED.get(e.getKey());
                if (allowed == null || v == null || !allowed.contains(v) || v.contains("com.") || v.contains("com/")) {
                    ok = false;
                }
                for (String s : in) {
                    if (s != null && s.length() > 1 && v != null && v.contains(s)) ok = false;
                }
            }
            check("c9 no value carries input text (" + label + ")", ok, m);
        }

        if (fails == 0) {
            System.out.println("PASS " + checks + " checks");
        } else {
            System.out.println("FAILED " + fails + " of " + checks + " checks");
            System.exit(1);
        }
    }
}
