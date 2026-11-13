package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** NWP-20261202-29: RoleReport's cases, compiled with RoleReport.java ALONE and executed by run.sh. Prints one
 *  'ok   <case>' or 'FAIL <case> ...' line per case and exits 1 when any fails. Every value a case produces is also
 *  checked to hold no '.' and none of the package names the case gave it. */
public final class RoleReportCases {
    private static int bad = 0;
    private static final String SELF = "com.nowhere.chooser";
    private static final String SYS = "org.example.bundledbrowser";
    private static final String UPD = "org.example.updateddialer";
    private static final String USR = "org.example.userbrowser";
    private static final String ALL_UNREADABLE = "browser=unreadable,dialer=unreadable,sms=unreadable,"
            + "home=unreadable,assistant=unreadable,callscreen=unreadable,callredirect=unreadable,"
            + "wallet=unreadable,notes=unreadable,emergency=unreadable";

    private interface Case { String run(); }

    private static void check(String name, Case c) {
        String why;
        try {
            why = c.run();
        } catch (Throwable t) {
            why = "threw " + t;
        }
        if (why == null) {
            System.out.println("ok   " + name);
        } else {
            System.out.println("FAIL " + name + " -- " + why);
            bad = 1;
        }
    }

    /** null when value equals want and holds no '.' and no pkg; else why not. */
    private static String expect(String value, String want, String... pkgs) {
        if (value == null) return "got null";
        if (value.indexOf('.') >= 0) return "the value holds a '.': " + value;
        for (String p : pkgs) if (p != null && value.contains(p)) return "the value holds a package name: " + value;
        if (!value.equals(want)) return "got '" + value + "', want '" + want + "'";
        return null;
    }

    private static Map<String, Boolean> sys(Object... kv) {
        Map<String, Boolean> m = new HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], (Boolean) kv[i + 1]);
        return m;
    }

    private static String role(String word) {
        for (String[] r : RoleReport.ROLES) if (r[1].equals(word)) return r[0];
        throw new IllegalStateException("no role " + word);
    }

    public static void main(String[] args) {
        check("unavailable role is unavailable", () -> expect(
                RoleReport.holderClass(false, Arrays.asList(SYS), SELF, sys(SYS, true)), "unavailable", SYS, SELF));
        check("null holders are unreadable", () -> expect(
                RoleReport.holderClass(true, null, SELF, sys()), "unreadable", SELF));
        check("empty holders are none", () -> expect(
                RoleReport.holderClass(true, Collections.<String>emptyList(), SELF, sys()), "none", SELF));
        check("the chooser is chooser", () -> expect(
                RoleReport.holderClass(true, Arrays.asList(SELF), SELF, sys(SELF, true)), "chooser", SELF));
        check("a system app is bundled", () -> {
            if (!RoleReport.isBundled(RoleReport.FLAG_SYSTEM)) return "isBundled(FLAG_SYSTEM) is false";
            return expect(RoleReport.holderClass(true, Arrays.asList(SYS), SELF,
                    sys(SYS, RoleReport.isBundled(0x1))), "bundled", SYS, SELF);
        });
        check("an updated system app is bundled", () -> {
            if (RoleReport.FLAG_UPDATED_SYSTEM_APP != 0x80) return "FLAG_UPDATED_SYSTEM_APP is not 0x80";
            if (!RoleReport.isBundled(0x80)) return "isBundled(0x80) is false";
            if (RoleReport.isBundled(0)) return "isBundled(0) is true";
            return expect(RoleReport.holderClass(true, Arrays.asList(UPD), SELF,
                    sys(UPD, RoleReport.isBundled(0x80 | 0x4))), "bundled", UPD, SELF);
        });
        check("a user app is user", () -> expect(
                RoleReport.holderClass(true, Arrays.asList(USR), SELF, sys(USR, false)), "user", USR, SELF));
        check("unread flags are unknown", () -> {
            String w = expect(RoleReport.holderClass(true, Arrays.asList(USR), SELF, sys(SYS, true)), "unknown",
                    USR, SYS, SELF);
            if (w != null) return w;
            w = expect(RoleReport.holderClass(true, Arrays.asList(USR), SELF, null), "unknown", USR, SELF);
            if (w != null) return "null isSystem: " + w;
            List<String> withNull = new ArrayList<>();
            withNull.add(null);
            return expect(RoleReport.holderClass(true, withNull, SELF, sys()), "unknown", SELF);
        });
        check("two holders join with plus", () -> expect(
                RoleReport.holderClass(true, Arrays.asList(SYS, USR), SELF, sys(SYS, true, USR, false)),
                "bundled+user", SYS, USR, SELF));
        check("ten roles in order", () -> {
            String[] want = {"android.app.role.BROWSER", "android.app.role.DIALER", "android.app.role.SMS",
                    "android.app.role.HOME", "android.app.role.ASSISTANT", "android.app.role.CALL_SCREENING",
                    "android.app.role.CALL_REDIRECTION", "android.app.role.WALLET", "android.app.role.NOTES",
                    "android.app.role.EMERGENCY"};
            if (RoleReport.ROLES.length != want.length) return RoleReport.ROLES.length + " roles, want 10";
            for (int i = 0; i < want.length; i++) {
                if (!want[i].equals(RoleReport.ROLES[i][0])) return "role " + i + " is " + RoleReport.ROLES[i][0];
            }
            return expect(RoleReport.format(new HashMap<>(), new HashMap<>(), SELF, new HashMap<>()),
                    ALL_UNREADABLE, SELF);
        });
        check("a failed availability read is unreadable", () -> {
            Map<String, List<String>> h = new HashMap<>();
            h.put(role("browser"), Arrays.asList(USR));
            return expect(RoleReport.format(new HashMap<>(), h, SELF, sys(USR, false)), ALL_UNREADABLE, USR, SELF);
        });
        check("mixed failures", () -> {
            Map<String, Boolean> av = new HashMap<>();
            Map<String, List<String>> h = new HashMap<>();
            for (String w : new String[]{"browser", "dialer", "sms", "home", "assistant", "wallet", "notes",
                    "emergency"}) av.put(role(w), true);
            av.put(role("callscreen"), false);
            // callredirect: no availability entry (its read failed); wallet: available, holder read failed.
            h.put(role("browser"), Arrays.asList(USR));
            h.put(role("dialer"), Arrays.asList(UPD));
            h.put(role("sms"), Arrays.asList(SELF));
            h.put(role("home"), Arrays.asList(SYS));
            h.put(role("assistant"), Collections.<String>emptyList());
            h.put(role("callredirect"), Arrays.asList(USR));
            h.put(role("notes"), Arrays.asList("org.example.notesflagsfailed"));
            h.put(role("emergency"), Arrays.asList(SYS, USR));
            return expect(RoleReport.format(av, h, SELF, sys(USR, false, UPD, true, SYS, true)),
                    "browser=user,dialer=bundled,sms=chooser,home=bundled,assistant=none,callscreen=unavailable,"
                            + "callredirect=unreadable,wallet=unreadable,notes=unknown,emergency=bundled+user",
                    USR, UPD, SYS, SELF, "org.example.notesflagsfailed");
        });
        check("null maps do not throw", () -> expect(RoleReport.format(null, null, null, null), ALL_UNREADABLE));
        System.exit(bad);
    }
}
