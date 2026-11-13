package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

/** NWP-20261202-05: the cases of DefaultRoles, compiled with it ALONE and executed (run.sh). Each case body returns
 *  null on a pass, or the text it got on a fail; check() runs it inside a try, so a case that throws prints its own
 *  FAIL line and the run goes on. The per-role cases run once per role in ROLES, named `<ROLE WORD> <case>`. The
 *  packages are made up. */
public final class DefaultRolesCases {
    static int runs = 0, fails = 0;
    static final String SELF = "com.nowhere.chooser";
    static final String USER = "com.example.userapp";
    static final String USER2 = "com.example.otheruserapp";
    static final String BUNDLED = "com.example.bundledapp";
    static final String UK = DefaultRoles.kindOf(true, 0);                                  // a user app
    static final String BK = DefaultRoles.kindOf(true, DefaultRoles.FLAG_SYSTEM);          // a bundled app
    static final String NK = DefaultRoles.kindOf(false, 0);                                // flags unreadable

    static void check(String name, Supplier<String> body) {
        runs++;
        try {
            String got = body.get();
            if (got != null) {
                fails++;
                System.out.println("FAIL " + name + "\n     got: " + got);
            }
        } catch (Throwable t) {
            fails++;
            System.out.println("FAIL " + name + " (threw " + t.getClass().getSimpleName() + ")");
        }
    }

    static String show(String[] a) { return a == null ? "null" : Arrays.toString(a); }
    static String[] e(String state, String target) { return new String[]{state, target}; }
    static boolean is(String[] a, String x, String y) { return a != null && a.length == 2 && x.equals(a[0]) && y.equals(a[1]); }
    static List<String> hs(String... p) { return new ArrayList<>(Arrays.asList(p)); }

    /** This role's entry of a marker written for session 7 and read back in session 7. */
    static String[] m(String role, String state, String target) {
        Map<String, String[]> mm = new LinkedHashMap<>();
        mm.put(role, e(state, target));
        Map<String, String[]> back = DefaultRoles.parseMarker(DefaultRoles.markerText("7", mm), "7");
        return back == null ? null : back.get(role);
    }

    static void perRole(String role) {
        String w = DefaultRoles.roleWord(role) + " ";

        check(w + "capture before the marker records nothing", () -> {
            Map<String, String[]> other = new LinkedHashMap<>();
            other.put(role, e("applied", "-"));
            Map<String, String[]> fromOther = DefaultRoles.parseMarker(DefaultRoles.markerText("6", other), "7");
            String[] none = null, foreign = fromOther == null ? null : fromOther.get(role);
            for (String[] mk : new String[][]{none, foreign}) {
                String[] s = DefaultRoles.captureStep(mk, null, USER, UK, SELF, null);
                if (s != null) return "user app before the marker: " + show(s);
                s = DefaultRoles.captureStep(mk, null, BUNDLED, BK, SELF, null);
                if (s != null) return "bundled before the marker: " + show(s);
                s = DefaultRoles.captureStep(mk, null, "", NK, SELF, null);
                if (s != null) return "nobody before the marker: " + show(s);
            }
            return null;
        });

        check(w + "capture after apply records the user's app", () -> {
            String[] s = DefaultRoles.captureStep(m(role, "applied", "-"), null, USER, UK, SELF, null);
            if (!is(s, "record", USER)) return show(s);
            Map<String, String> rec = DefaultRoles.parseRecord("");
            rec.put(role, s[1]);
            String text = DefaultRoles.recordText(rec);
            if (!text.equals(role + " " + USER + "\n")) return "record text " + text;
            String back = DefaultRoles.parseRecord(text).get(role);
            return USER.equals(back) ? null : "round trip " + back;
        });

        check(w + "switch back to a bundled app in an applied session is recorded", () -> {
            String[] s = DefaultRoles.captureStep(m(role, "applied", USER), USER, BUNDLED, BK, SELF, "installed");
            return is(s, "record", BUNDLED) ? null : show(s);
        });

        check(w + "bundled holder while deferred keeps the record", () -> {
            String[] s = DefaultRoles.captureStep(m(role, "deferred", USER), USER, BUNDLED, BK, SELF, "archived");
            if (s != null) return "deferred, archived: " + show(s);
            s = DefaultRoles.captureStep(m(role, "deferred", USER), USER, BUNDLED, BK, SELF, "installed");
            if (s != null) return "deferred, installed before its landing ran: " + show(s);
            s = DefaultRoles.captureStep(m(role, "fallback", USER), USER, BUNDLED, BK, SELF, "installed");
            if (s != null) return "fallback, installed: " + show(s);
            // ... but a user app picked meanwhile is a new choice
            s = DefaultRoles.captureStep(m(role, "deferred", USER), USER, USER2, UK, SELF, "archived");
            return is(s, "record", USER2) ? null : "a user app picked while deferred: " + show(s);
        });

        check(w + "bundled default assigned after the apply with no record records nothing", () -> {
            String[] s = DefaultRoles.captureStep(m(role, "applied", "-"), null, BUNDLED, BK, SELF, null);
            return s == null ? null : show(s);
        });

        check(w + "uninstall or archive while recorded keeps the record, deferred", () -> {
            for (String p : new String[]{"absent", "archived"}) {
                String[] s = DefaultRoles.captureStep(m(role, "applied", USER), USER, BUNDLED, BK, SELF, p);
                if (!is(s, "defer", USER)) return p + ", bundled holder: " + show(s);
                s = DefaultRoles.captureStep(m(role, "applied", USER), USER, "", NK, SELF, p);
                if (!is(s, "defer", USER)) return p + ", nobody: " + show(s);
            }
            String[] s = DefaultRoles.captureStep(m(role, "applied", USER), USER, BUNDLED, BK, SELF, "unknown");
            return s == null ? null : "presence unknown: " + show(s);
        });

        check(w + "apply of an installed record assigns it", () -> {
            String[] p = DefaultRoles.signInPlan(USER, "installed", SELF);
            return USER.equals(p[0]) && "applied".equals(p[1]) && USER.equals(p[2]) ? null : show(p);
        });
        check(w + "apply of an archived record defers", () -> {
            String[] p = DefaultRoles.signInPlan(USER, "archived", SELF);
            return p[0] == null && "deferred".equals(p[1]) && USER.equals(p[2]) ? null : show(p);
        });
        check(w + "apply of an absent record defers", () -> {
            String[] p = DefaultRoles.signInPlan(USER, "absent", SELF);
            return p[0] == null && "deferred".equals(p[1]) && USER.equals(p[2]) ? null : show(p);
        });
        check(w + "apply of an unknown-presence record assigns it", () -> {
            String[] p = DefaultRoles.signInPlan(USER, "unknown", SELF);
            return USER.equals(p[0]) && "applied".equals(p[1]) && USER.equals(p[2]) ? null : show(p);
        });
        check(w + "apply with no record leaves the holder", () -> {
            String[] p = DefaultRoles.signInPlan(null, "absent", SELF);
            String[] q = DefaultRoles.signInPlan(SELF, "installed", SELF);
            return p[0] == null && "applied".equals(p[1]) && "-".equals(p[2]) && q[0] == null ? null : show(p) + show(q);
        });

        check(w + "take-back on land: a bundled app holds it: assign", () -> {
            String[] mk = m(role, "deferred", USER);
            String t = DefaultRoles.materialiseTarget(mk, USER, hs(BUNDLED), BK, SELF);
            if (!USER.equals(t)) return "bundled, target " + t;
            if (!"assign".equals(DefaultRoles.takeoverStep(hs(BUNDLED), BK, SELF, USER))) return "bundled, step";
            if (!USER.equals(DefaultRoles.materialiseTarget(mk, USER, hs(), NK, SELF))) return "nobody, target";
            if (!"assign".equals(DefaultRoles.takeoverStep(hs(), NK, SELF, USER))) return "nobody, step";
            if (!USER.equals(DefaultRoles.materialiseTarget(m(role, "fallback", USER), USER, hs(SELF), UK, SELF))) return "chooser, target";
            if (!"assign".equals(DefaultRoles.takeoverStep(hs(SELF), UK, SELF, USER))) return "chooser, step";
            if (!"held".equals(DefaultRoles.takeoverStep(hs(USER), UK, SELF, USER))) return "already held";
            if (DefaultRoles.materialiseTarget(mk, USER2, hs(BUNDLED), BK, SELF) != null) return "another app landed";
            return DefaultRoles.materialiseTarget(m(role, "applied", USER), USER, hs(BUNDLED), BK, SELF) == null
                    ? null : "an applied role taken again";
        });

        check(w + "take-back on land: a user app holds it: leave", () -> {
            String[] mk = m(role, "deferred", USER);
            String t = DefaultRoles.materialiseTarget(mk, USER, hs(USER2), UK, SELF);
            if (t != null) return "target " + t;
            if (!"leave".equals(DefaultRoles.takeoverStep(hs(USER2), UK, SELF, USER))) return "user app, step";
            if (DefaultRoles.materialiseTarget(mk, USER, null, NK, SELF) != null) return "unreadable, target";
            return "leave".equals(DefaultRoles.takeoverStep(null, NK, SELF, USER)) ? null : "unreadable, step";
        });

        check(w + "unknown flags record nothing", () -> {
            String[] s = DefaultRoles.captureStep(m(role, "applied", "-"), null, USER2, NK, SELF, null);
            if (s != null) return "no record: " + show(s);
            s = DefaultRoles.captureStep(m(role, "applied", USER), USER, USER2, NK, SELF, "installed");
            if (s != null) return "with a record: " + show(s);
            String k = DefaultRoles.kindOf(false, 0);
            return "leave".equals(DefaultRoles.takeoverStep(hs(USER2), k, SELF, USER)) ? null : "takeover over unknown";
        });

        check(w + "a marker of another session is not this session's apply", () -> {
            Map<String, String[]> mm = new LinkedHashMap<>();
            mm.put(role, e("applied", USER));
            String text = DefaultRoles.markerText("7", mm);
            if (DefaultRoles.parseMarker(text, "8") != null) return "session 7 read as 8";
            if (DefaultRoles.parseMarker("x\n" + role + " applied " + USER + "\n", "8") != null) return "no session line";
            Map<String, String[]> back = DefaultRoles.parseMarker(text, "7");
            if (back == null || !is(back.get(role), "applied", USER)) return "own session: " + (back == null ? "null" : show(back.get(role)));
            String other = DefaultRoles.ROLES[(Arrays.asList(DefaultRoles.ROLES).indexOf(role) + 1) % DefaultRoles.ROLES.length];
            back = DefaultRoles.parseMarker(text + other + " applied\n", "7");
            if (back == null || back.containsKey(other) || !back.containsKey(role)) return "a malformed line";
            back = DefaultRoles.parseMarker(text + role + " deferred " + USER + "\n", "7");
            return back != null && !back.containsKey(role) ? null : "a role seen twice";
        });

        check(w + "capture with an unreadable record keeps every role's record", () -> {
            String other = DefaultRoles.ROLES[(Arrays.asList(DefaultRoles.ROLES).indexOf(role) + 1) % DefaultRoles.ROLES.length];
            String text = role + " " + USER + "\n" + other + " " + USER2 + "\n";
            // this session's apply ran for the role, and its holder is unchanged: only a lost record would capture it
            String[] mk = m(role, "applied", USER);
            if (DefaultRoles.recordForCapture(true, text.length(), null) != null) return "an unreadable record was read";
            Map<String, String> rec = DefaultRoles.recordForCapture(true, text.length(), text);
            if (rec == null) return "a readable record read as unknown";
            String[] s = DefaultRoles.captureStep(mk, rec.get(role), USER, UK, SELF, "installed");
            if (s != null) return "the unchanged holder captured: " + show(s);
            s = DefaultRoles.captureStep(mk, rec.get(role), USER2, UK, SELF, "installed");
            if (!is(s, "record", USER2)) return "a real switch: " + show(s);
            rec.put(role, s[1]);
            Map<String, String> back = DefaultRoles.parseRecord(DefaultRoles.recordText(rec));
            if (!USER2.equals(back.get(role))) return "the switch not recorded: " + back;
            if (!USER2.equals(back.get(other))) return "the other role's record lost: " + back;
            Map<String, String> none = DefaultRoles.recordForCapture(false, 0, null);
            return none != null && none.isEmpty() ? null : "no file: " + none;
        });

        check(w + "record round trip keeps every role", () -> {
            String other = DefaultRoles.ROLES[(Arrays.asList(DefaultRoles.ROLES).indexOf(role) + 1) % DefaultRoles.ROLES.length];
            String third = DefaultRoles.ROLES[(Arrays.asList(DefaultRoles.ROLES).indexOf(role) + 2) % DefaultRoles.ROLES.length];
            Map<String, String> rec = DefaultRoles.parseRecord(role + " " + USER + "\n" + other + " " + USER2 + "\n");
            rec.put(third, BUNDLED);
            Map<String, String> back = DefaultRoles.parseRecord(DefaultRoles.recordText(rec));
            return USER.equals(back.get(role)) && USER2.equals(back.get(other)) && BUNDLED.equals(back.get(third))
                    && back.size() == 3 ? null : back.toString();
        });
    }

    public static void main(String[] args) {
        for (String role : DefaultRoles.ROLES) perRole(role);

        check("unreadable record writes no marker", () -> {
            if (!DefaultRoles.recordUnknown(true, 10, null)) return "unreadable within the cap";
            if (DefaultRoles.recordUnknown(false, 0, null)) return "no file";
            if (DefaultRoles.recordUnknown(true, 5000, null)) return "over the cap";
            return DefaultRoles.recordUnknown(true, 10, "") ? "read" : null;
        });
        check("HOME is never in ROLES", () -> DefaultRoles.isRole("android.app.role.HOME") ? "HOME" : null);
        check("SMS is never in ROLES", () -> DefaultRoles.isRole("android.app.role.SMS") ? "SMS" : null);
        check("EMERGENCY is never in ROLES", () -> DefaultRoles.isRole("android.app.role.EMERGENCY") ? "EMERGENCY" : null);
        check("ROLES holds the seven roles", () -> {
            List<String> want = Arrays.asList("android.app.role.BROWSER", "android.app.role.DIALER",
                    "android.app.role.ASSISTANT", "android.app.role.CALL_SCREENING", "android.app.role.CALL_REDIRECTION",
                    "android.app.role.WALLET", "android.app.role.NOTES");
            return want.equals(Arrays.asList(DefaultRoles.ROLES)) ? null : Arrays.toString(DefaultRoles.ROLES);
        });
        check("a bad record line drops only that line", () -> {
            String b = "android.app.role.BROWSER";
            Map<String, String> rec = DefaultRoles.parseRecord("android.app.role.HOME " + USER + "\n"
                    + "android.app.role.DIALER not_a_package\n"
                    + "android.app.role.WALLET " + USER + " extra\n"
                    + b + " " + USER + "\n" + b + " " + USER2 + "\n");
            return rec.size() == 1 && USER.equals(rec.get(b)) ? null : rec.toString();
        });
        check("summary names counts only", () -> {
            String s = DefaultRoles.summary(2, 1, 0, 4);
            return s.equals("default roles at sign-in: 2 applied, 1 deferred, 0 refused, 4 no record (NWP-20261202-05)")
                    ? null : s;
        });
        check("kindOf reads FLAG_SYSTEM and FLAG_UPDATED_SYSTEM_APP as bundled", () -> {
            if (!"bundled".equals(DefaultRoles.kindOf(true, 1))) return "FLAG_SYSTEM";
            if (!"bundled".equals(DefaultRoles.kindOf(true, 128))) return "FLAG_UPDATED_SYSTEM_APP";
            if (!"user".equals(DefaultRoles.kindOf(true, 0))) return "no flag";
            return "unknown".equals(DefaultRoles.kindOf(false, 1)) ? null : "unreadable";
        });
        check("roleWord is the text after the last dot", () ->
                "BROWSER".equals(DefaultRoles.roleWord("android.app.role.BROWSER")) ? null : DefaultRoles.roleWord("android.app.role.BROWSER"));

        if (fails > 0) {
            System.out.println(fails + " of " + runs + " cases FAILED");
            System.exit(1);
        }
        System.out.println("ok " + runs + " cases");
    }
}
