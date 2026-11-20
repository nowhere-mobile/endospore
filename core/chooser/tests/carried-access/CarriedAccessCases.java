package com.nowhere.chooser;

import java.util.Arrays;
import java.util.List;

/** NWP-20261207-17: CarriedAccess, compiled unchanged and run by test-carried-access-java.sh. Exit 1 on any failure. */
public class CarriedAccessCases {
    static int fails = 0;

    static void check(String name, boolean ok, Object got) {
        if (ok) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + ": got " + got); fails++; }
    }

    public static void main(String[] a) {
        String talkback = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService";
        String inner = "com.example.a11y/.Svc$Inner";

        // C1: a real-shaped list -- a framework target, a bare magnification entry, a malformed and a duplicate entry.
        String real = talkback + ":com.android.server.accessibility/ColorInversion"
                + ":com.android.server.accessibility.MagnificationController:bad entry:" + inner + ":" + talkback
                + ":/NoPkg:1bad.pkg/Cls";
        List<String> s = CarriedAccess.services(real);
        check("C1 services keeps the app services, in order, once; no framework or malformed entry",
                s.equals(Arrays.asList(talkback, inner)), s);

        // C2
        check("C2 services of null is empty", CarriedAccess.services(null).isEmpty(), CarriedAccess.services(null));
        check("C2 services of \"\" is empty", CarriedAccess.services("").isEmpty(), CarriedAccess.services(""));

        // C3: without keeps every other entry, framework ones included, in order.
        String w = CarriedAccess.without("a.b/C:com.android.server.accessibility/ColorInversion:x.y/Z"
                + ":com.android.server.accessibility.MagnificationController", "x.y/Z");
        check("C3 without keeps every other entry in order, framework entries included",
                "a.b/C:com.android.server.accessibility/ColorInversion:com.android.server.accessibility.MagnificationController"
                        .equals(w), w);

        // C4
        String last = CarriedAccess.without("x.y/Z", "x.y/Z");
        check("C4 without of the last entry is \"\"", "".equals(last), "'" + last + "'");
        check("C4 anyComponent(\"\") is false", !CarriedAccess.anyComponent(""), true);

        // C5
        String in5 = talkback + ":com.android.server.accessibility/ColorInversion";
        String w5 = CarriedAccess.without(in5, "x.y/Z");
        check("C5 without of an absent entry is the input", in5.equals(w5), w5);

        // C6: accessibility_enabled stays on while ANY <pkg>/<cls> entry is left, a framework component included.
        check("C6 anyComponent of a framework component is true",
                CarriedAccess.anyComponent("com.android.server.accessibility/ColorInversion"
                        + ":com.android.server.accessibility.MagnificationController"), false);
        check("C6 anyComponent of a bare framework entry only is false",
                !CarriedAccess.anyComponent("com.android.server.accessibility.MagnificationController:bad entry"), true);
        check("C6 anyComponent with one app service is true",
                CarriedAccess.anyComponent("com.android.server.accessibility/ColorInversion:a.b/C"), false);
        check("C6 anyComponent of null is false", !CarriedAccess.anyComponent(null), true);
        // C6b: the last listed service goes while a framework component stays: the flag is kept, the list shows none.
        String rest = CarriedAccess.without("com.reader/.Reader:com.android.server.accessibility/ColorInversion",
                "com.reader/.Reader");
        check("C6b removing the last listed service leaves the framework component",
                "com.android.server.accessibility/ColorInversion".equals(rest), rest);
        check("C6b the framework component left keeps accessibility_enabled (anyComponent true)",
                CarriedAccess.anyComponent(rest), rest);
        check("C6b the framework component left is not listed", CarriedAccess.services(rest).isEmpty(), rest);

        // C7
        List<String> lines = Arrays.asList(
                "com.a android.permission.CAMERA",
                "com.a flags:user-fixed:android.permission.CAMERA",
                "com.a appop:android:manage_external_storage",
                "com.a appop:android:get_usage_stats",
                "com.a appop:android:system_alert_window",
                "com.b appop:android:manage_external_storage",
                "com.c appop:android:get_usage_stats",
                "com.c appop:android:get_usage_stats x",
                " appop:android:get_usage_stats");
        List<String> u = CarriedAccess.usageLines(lines);
        check("C7 usageLines lists the packages of the exact usage lines", u.equals(Arrays.asList("com.a", "com.c")), u);
        check("C7 usageLines of null is empty", CarriedAccess.usageLines(null).isEmpty(), CarriedAccess.usageLines(null));

        // C8: withoutUsage drops exactly com.a's usage line; every other line is the same String, in order.
        List<String> o = CarriedAccess.withoutUsage(lines, "com.a");
        check("C8 withoutUsage leaves 8 lines", o.size() == 8, o);
        check("C8 com.a's usage line is gone", !o.contains("com.a appop:android:get_usage_stats"), o);
        check("C8 com.a appop:android:manage_external_storage kept at index 2",
                o.size() > 2 && o.get(2) == lines.get(2), o);
        check("C8 com.a appop:android:system_alert_window kept at index 3",
                o.size() > 3 && o.get(3) == lines.get(4), o);
        check("C8 the flags: line kept byte for byte", o.size() > 1 && o.get(1) == lines.get(1), o);
        check("C8 com.c appop:android:get_usage_stats kept", o.contains("com.c appop:android:get_usage_stats"), o);
        check("C8 com.c appop:android:get_usage_stats x kept", o.contains("com.c appop:android:get_usage_stats x"), o);
        boolean same = o.size() == 8;
        for (int i = 0, j = 0; same && i < lines.size(); i++) {
            if (i == 3) continue;
            same = o.get(j++) == lines.get(i);
        }
        check("C8 every other line is the same String in the same order", same, o);

        // C9
        for (String t : new String[]{"x a\ny b\n", ""}) {
            String r = CarriedAccess.lines(CarriedAccess.splitLines(t));
            check("C9 lines(splitLines(t)) round trips " + t.replace("\n", "\\n"), t.equals(r), r);
        }
        check("C9 splitLines(null) is null", CarriedAccess.splitLines(null) == null, CarriedAccess.splitLines(null));

        // C10: the install and its permission restore land between the screen read and the switch. A fake phone:
        // roamd's restore grants usage access from the carried line; capturePerms records an installed app only on
        // MODE_ALLOWED and carries a not-installed app's line forward.
        String app = "com.watch";
        Phone ph = new Phone(Arrays.asList("com.keep appop:android:get_usage_stats", app + " appop:android:get_usage_stats"));
        List<String> read = CarriedAccess.usageLines(ph.perms);  // the screen read: not installed, listed with its line
        check("C10 the screen read lists the not-installed app", read.contains(app) && !ph.installed(app), read);
        ph.install(app);                                          // the install and its restore, while the screen is open
        check("C10 the restore granted live usage access", ph.allowed(app), ph.live);
        boolean off = CarriedAccess.usageOff(ph.ops(app));        // the user switches the row off
        check("C10 the off reports success", off, off);
        check("C10 the off revoked the live grant of the app installed since the read", !ph.allowed(app), ph.live);
        ph.capture();
        check("C10 the next capture records no usage line for it", !ph.perms.contains(app + " appop:android:get_usage_stats"),
                ph.perms);
        check("C10 the next capture keeps the other app's line", ph.perms.contains("com.keep appop:android:get_usage_stats"),
                ph.perms);

        // C11: the app is still not installed at the off and installs later: the line is gone, so nothing is restored.
        Phone p2 = new Phone(Arrays.asList(app + " appop:android:get_usage_stats"));
        check("C11 the off of a not-installed app reports success", CarriedAccess.usageOff(p2.ops(app)), p2.perms);
        p2.install(app);
        check("C11 a later install restores no usage access", !p2.allowed(app), p2.live);
        p2.capture();
        check("C11 the next capture records no usage line", p2.perms.isEmpty(), p2.perms);

        // C12: an unreadable nowhere-perms fails the off, but an installed app's live grant is still revoked.
        Phone p3 = new Phone(Arrays.asList(app + " appop:android:get_usage_stats"));
        p3.install(app);
        p3.unreadable = true;
        check("C12 an unreadable nowhere-perms fails the off", !CarriedAccess.usageOff(p3.ops(app)), true);
        check("C12 the live grant is revoked all the same", !p3.allowed(app), p3.live);

        // C13: the install and its restore land just after the off's installation check. The line went first, so the
        // restore finds nothing to grant.
        Phone p4 = new Phone(Arrays.asList(app + " appop:android:get_usage_stats"));
        p4.installAfterUid = app;
        check("C13 the off reports success", CarriedAccess.usageOff(p4.ops(app)), p4.perms);
        check("C13 the install just after the check restores no usage access", p4.installed(app) && !p4.allowed(app),
                p4.live);

        System.exit(fails == 0 ? 0 : 1);
    }

    /** A fake phone for C10-C13: installed apps with uids, their live usage appop, and the nowhere-perms lines. */
    static final class Phone {
        java.util.List<String> perms;
        final java.util.Map<String, Integer> uids = new java.util.HashMap<>();
        final java.util.Map<Integer, Boolean> live = new java.util.HashMap<>();
        boolean unreadable;
        String installAfterUid;  // C13: this app installs (and is restored) right after the off reads its uid

        Phone(List<String> lines) { perms = new java.util.ArrayList<>(lines); }

        boolean installed(String pkg) { return uids.containsKey(pkg); }

        boolean allowed(String pkg) { return installed(pkg) && Boolean.TRUE.equals(live.get(uids.get(pkg))); }

        /** The install, then roamd's restore: grant usage access when the carried line holds it. */
        void install(String pkg) {
            int uid = 10100 + uids.size();
            uids.put(pkg, uid);
            live.put(uid, perms.contains(pkg + CarriedAccess.USAGE_SUFFIX));
        }

        /** capturePerms: an installed app only on MODE_ALLOWED; a not-installed app's line carried forward. */
        void capture() {
            java.util.ArrayList<String> out = new java.util.ArrayList<>();
            for (String p : CarriedAccess.usageLines(perms)) if (!installed(p)) out.add(p + CarriedAccess.USAGE_SUFFIX);
            for (String p : uids.keySet()) if (allowed(p)) out.add(p + CarriedAccess.USAGE_SUFFIX);
            perms = out;
        }

        CarriedAccess.UsageOps ops(final String pkg) {
            return new CarriedAccess.UsageOps() {
                @Override public boolean forget() {
                    if (unreadable) return false;
                    perms = CarriedAccess.withoutUsage(perms, pkg);
                    return true;
                }
                @Override public int uid() {
                    int u = installed(pkg) ? uids.get(pkg) : -1;
                    if (pkg.equals(installAfterUid)) { installAfterUid = null; install(pkg); }
                    return u;
                }
                @Override public boolean ignore(int uid) { live.put(uid, false); return true; }
            };
        }
    }
}
