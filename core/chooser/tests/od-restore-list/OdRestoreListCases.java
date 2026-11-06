package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** NWP-20261128-16: OdRestoreList's request text and its reply parser, run under javac by
 *  core/vendor-common/bin/test-od-restore-list-java.sh. Prints "ok <ID> ..." or "FAIL <ID> ..." per case. */
public final class OdRestoreListCases {
    private static int failed = 0;
    private static final List<String> SENT = Arrays.asList("a.b", "c.d", "e.f");

    private static void check(String id, String what, boolean pass, Object got) {
        if (pass) System.out.println("ok " + id + " " + what);
        else { System.out.println("FAIL " + id + " " + what + " -- got " + got); failed++; }
    }

    private static Map<String, String> parse(String... lines) {
        return OdRestoreList.parse(Arrays.asList(lines), SENT);
    }

    private static boolean is(Map<String, String> m, String a, String c, String e) {
        return m.size() == 3 && m.containsKey("a.b") && m.containsKey("c.d") && m.containsKey("e.f")
                && Objects.equals(m.get("a.b"), a) && Objects.equals(m.get("c.d"), c) && Objects.equals(m.get("e.f"), e);
    }

    private static boolean refuses(List<String> pkgs) {
        try { OdRestoreList.request(pkgs); return false; } catch (IllegalArgumentException expected) { return true; }
    }

    public static void main(String[] args) {
        String r = OdRestoreList.request(SENT);
        check("L1", "the request is the verb, the names one space apart, one newline",
                "RESTORE-ODDATA\na.b c.d e.f\n".equals(r), r);

        List<String> nine = new ArrayList<>();
        for (int i = 0; i < 9; i++) nine.add("p.n" + i);
        check("L2", "a list of 1 and a list of CHUNK+1 are refused (the one-name form stays restoreOnlyLocked)",
                OdRestoreList.CHUNK == 8 && refuses(Arrays.asList("a.b")) && refuses(nine)
                        && !refuses(nine.subList(0, 8)) && !refuses(nine.subList(0, 2)), OdRestoreList.CHUNK);

        Map<String, String> m = parse("a.b OK a.b", "c.d OK NOSRC", "e.f ERR-BUSY", "END 3");
        check("L3", "a full reply maps each package to its own reply", is(m, "OK a.b", "OK NOSRC", "ERR-BUSY"), m);

        m = parse("a.b OK a.b", "c.d OK NOSRC");
        check("L4", "a cut reply (two lines, no END): the third has no reply", is(m, "OK a.b", "OK NOSRC", null), m);

        m = parse("a.b OK a.b", "c.d STOPPED", "e.f STOPPED", "END 1");
        check("L5", "STOPPED (a sign-out) is no reply", is(m, "OK a.b", null, null), m);

        m = parse("NONE");
        check("L6", "a one-line NONE applies to every package", is(m, "NONE", "NONE", "NONE"), m);

        m = parse("OK LOCAL");
        check("L7", "a one-line OK LOCAL applies to every package", is(m, "OK LOCAL", "OK LOCAL", "OK LOCAL"), m);

        m = parse("ERR-PKG");
        check("L8", "a one-line ERR-PKG applies to every package", is(m, "ERR-PKG", "ERR-PKG", "ERR-PKG"), m);

        m = parse("a.b OK a.b", "x.y OK x.y", "c.d OK NOSRC", "e.f OK e.f", "END 3");
        check("L9", "a line naming a package not sent is ignored",
                is(m, "OK a.b", "OK NOSRC", "OK e.f") && !m.containsKey("x.y"), m);

        m = parse("e.f OK e.f", "a.b ERR-NOTREADY", "c.d OK NOSRC", "END 3");
        check("L10", "lines out of order still map by name", is(m, "ERR-NOTREADY", "OK NOSRC", "OK e.f"), m);

        Map<String, String> endOnly = parse("END 3");
        Map<String, String> none = OdRestoreList.parse(new ArrayList<String>(), SENT);
        check("L11", "END alone, and no lines at all (a failed connect), are no reply for every package",
                is(endOnly, null, null, null) && is(none, null, null, null), endOnly + " / " + none);

        m = parse("a.b OK a.b", "a.b ERR-X", "c.d OK c.d", "e.f OK e.f", "END 3");
        check("L12", "a package's first line wins", is(m, "OK a.b", "OK c.d", "OK e.f"), m);

        System.exit(failed == 0 ? 0 : 1);
    }
}
