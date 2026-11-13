package com.nowhere.chooser;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;

/** NWP-20261130-12: cases for SettingsRoam, run by core/vendor-common/bin/test-settings-roam.sh. With no argument it runs
 *  J1-J10 and exits 1 on a failed case. --table prints the verdict table P1 compares with the shell's. --apply and
 *  --reconcile are the Java half of the E cases: their store is the shell stub's directory, so a value crosses both
 *  halves byte for byte. */
final class SettingsRoamCases {
    private static final String INNER = "a,custom(com.x/.Outer$Tile),b";
    private static final String QS = "sysui_qs_tiles";
    private static int failed = 0;

    private static void check(String id, boolean ok, String what) {
        System.out.println((ok ? "ok " : "FAIL ") + id + " " + what);
        if (!ok) failed++;
    }

    private static final class Fake implements SettingsRoam.Store {
        final Map<String, String> vals = new HashMap<>();
        final List<String> puts = new ArrayList<>();
        final List<String> gets = new ArrayList<>();
        final Set<String> failing = new HashSet<>();

        @Override public String get(String scope, String key) {
            gets.add(scope + " " + key);
            return vals.get(scope + " " + key);
        }

        @Override public boolean put(String scope, String key, String value) {
            if (failing.contains(key)) return false;
            puts.add(key);
            vals.put(scope + " " + key, value);
            return true;
        }

        String v(String key) { return vals.get("secure " + key); }
    }

    private static List<SettingsRoam.Row> qsList() {
        return SettingsRoam.parseList(Arrays.asList("# a comment", "", "secure " + QS + " tiles"));
    }

    private static List<String> rec(String value) {
        return Arrays.asList("idle=5", "sroam=secure " + QS + " " + value);
    }

    private static final Predicate<String> ALL = p -> true;
    private static final Predicate<String> NONE = p -> false;

    private static void j1() {
        for (String v : new String[] {"a,b", INNER}) {
            Fake f = new Fake();
            SettingsRoam.Result r = SettingsRoam.apply(qsList(), rec(v), f, ALL);
            check("J1", v.equals(f.v(QS)) && r.applied == 1 && r.malformed == 0, "apply writes " + v);
            check("J1", f.puts.equals(Arrays.asList(QS, SettingsRoam.APPLIED_KEY)) && "1".equals(f.v(SettingsRoam.APPLIED_KEY)),
                    "the marker is the last put");
        }
        List<SettingsRoam.Row> two = SettingsRoam.parseList(Arrays.asList("secure " + QS + " tiles", "system plain_row"));
        Fake f = new Fake();
        SettingsRoam.apply(two, Arrays.asList("sroam=system plain_row one two", "sroam=secure " + QS + " x"), f, ALL);
        check("J1", "one two".equals(f.vals.get("system plain_row")) && "x".equals(f.v(QS)),
                "a later plain row on the list applies with no code change");
    }

    private static void j2() {
        Fake f = new Fake();
        SettingsRoam.Result r = SettingsRoam.apply(qsList(), rec("a,custom(x/y),b"), f, NONE);
        check("J2", "a,b".equals(f.v(QS)), "a missing package's tile leaves the live value");
        check("J2", "a,?custom(x/y),b".equals(f.v(SettingsRoam.TILES_KEY)) && r.waiting == 1, "the row keeps it, marked");
        f = new Fake();
        SettingsRoam.apply(qsList(), rec(INNER), f, NONE);
        check("J2", "a,b".equals(f.v(QS)) && "a,?custom(com.x/.Outer$Tile),b".equals(f.v(SettingsRoam.TILES_KEY)),
                "the same with a $ in the class");
        f = new Fake();
        SettingsRoam.apply(qsList(), rec("a,custom(mine/y),custom(other/z)"), f, p -> p.equals("mine"));
        check("J2", "a,custom(mine/y)".equals(f.v(QS)) && "a,custom(mine/y),?custom(other/z)".equals(f.v(SettingsRoam.TILES_KEY)),
                "only the missing package waits");
        f = new Fake();
        SettingsRoam.apply(qsList(), rec(INNER), f, ALL);
        check("J2", f.v(SettingsRoam.TILES_KEY) == null, "nothing waits: the row is not written");
    }

    private static void j3() {
        SettingsRoam.Row row = qsList().get(0);
        Fake f = new Fake();
        f.vals.put("secure " + QS, "a,b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "a,?custom(com.x/.Outer$Tile),b");
        int n = SettingsRoam.reconcile(row, f, ALL);
        check("J3", n == 1 && INNER.equals(f.v(QS)), "the live value gets it back at the stored position, $ intact");
        check("J3", "".equals(f.v(SettingsRoam.TILES_KEY)), "the row empties at the last tile");

        f = new Fake();
        f.vals.put("secure " + QS, "a,b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "?custom(x/y),a,?custom(z/y),b");
        n = SettingsRoam.reconcile(row, f, p -> p.equals("x"));
        check("J3", n == 1 && "custom(x/y),a,b".equals(f.v(QS)), "a first-position tile goes first");
        check("J3", "custom(x/y),a,?custom(z/y),b".equals(f.v(SettingsRoam.TILES_KEY)), "the other tile still waits");

        f = new Fake();
        f.vals.put("secure " + QS, "a,custom(x/y),b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "a,?custom(x/y),b");
        n = SettingsRoam.reconcile(row, f, ALL);
        check("J3", n == 0 && "a,custom(x/y),b".equals(f.v(QS)) && "".equals(f.v(SettingsRoam.TILES_KEY)),
                "a tile already live is not doubled, and its mark goes");

        f = new Fake();
        f.vals.put("secure " + QS, "a,b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "a,?custom(x/y),b");
        n = SettingsRoam.reconcile(row, f, NONE);
        check("J3", n == 0 && f.puts.isEmpty(), "no landing writes nothing");

        f = new Fake();
        f.vals.put("secure " + QS, "a,b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "a,?custom(x/y) b");
        n = SettingsRoam.reconcile(row, f, ALL);
        check("J3", n == 0 && f.puts.isEmpty(), "a row outside the set writes nothing");

        f = new Fake();
        f.vals.put("secure " + QS, "a b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "a,?custom(x/y)");
        n = SettingsRoam.reconcile(row, f, ALL);
        check("J3", n == 0 && f.puts.isEmpty(), "a live value outside the set is not overwritten");

        f = new Fake();
        f.failing.add(QS);
        f.vals.put("secure " + QS, "a,b");
        f.vals.put("secure " + SettingsRoam.TILES_KEY, "a,?custom(x/y),b");
        n = SettingsRoam.reconcile(row, f, ALL);
        check("J3", n == 0 && "a,?custom(x/y),b".equals(f.v(SettingsRoam.TILES_KEY)), "a failed live put keeps the mark");
    }

    private static void j4() {
        Fake f = new Fake();
        SettingsRoam.Result r = SettingsRoam.apply(qsList(), Arrays.asList("idle=5", "wipe=3"), f, ALL);
        check("J4", f.puts.equals(Arrays.asList(SettingsRoam.APPLIED_KEY)) && r.rows == 0, "no sroam line: only the marker");
        f = new Fake();
        SettingsRoam.apply(qsList(), Collections.emptyList(), f, ALL);
        check("J4", f.puts.equals(Arrays.asList(SettingsRoam.APPLIED_KEY)), "an empty reply: only the marker");
    }

    private static void j5() {
        Fake f = new Fake();
        SettingsRoam.Result r = SettingsRoam.apply(qsList(), null, f, ALL);
        check("J5", f.puts.isEmpty() && !r.marked, "a failed read writes nothing and sets no marker");
        f = new Fake();
        r = SettingsRoam.apply(SettingsRoam.parseList(null), rec("a,b"), f, ALL);
        check("J5", f.puts.isEmpty() && !r.marked, "an unreadable list writes nothing and sets no marker");
        f = new Fake();
        r = SettingsRoam.apply(SettingsRoam.parseList(Arrays.asList("# nothing")), rec("a,b"), f, ALL);
        check("J5", f.puts.isEmpty() && !r.marked, "a list with no row writes nothing and sets no marker");
    }

    private static void j6() {
        Fake f = new Fake();
        SettingsRoam.apply(qsList(), Arrays.asList("sroam=secure off_list v", "sroam=system " + QS + " v",
                "sroam=global " + QS + " v"), f, ALL);
        check("J6", f.puts.equals(Arrays.asList(SettingsRoam.APPLIED_KEY)), "a record row off the list never reaches a put");
        List<SettingsRoam.Row> r = SettingsRoam.parseList(Arrays.asList("global adb_enabled", "secure bad-key",
                "secure k odd_kind", "secure k tiles extra", "secure"));
        check("J6", r.isEmpty(), "the list refuses Global, a bad key, an unknown kind and a wrong field count");
        f = new Fake();
        SettingsRoam.apply(SettingsRoam.parseList(Arrays.asList("global " + QS)), Arrays.asList("sroam=global " + QS + " v"), f, ALL);
        check("J6", f.puts.isEmpty(), "a global row on the list never reaches a put");
    }

    private static void j7() {
        Fake f = new Fake();
        f.failing.add(QS);
        SettingsRoam.Result r = SettingsRoam.apply(qsList(), rec("a,b"), f, ALL);
        check("J7", r.failed == 1 && !r.marked && f.v(SettingsRoam.APPLIED_KEY) == null, "a failed put: no marker");
        f = new Fake();
        f.failing.add(SettingsRoam.TILES_KEY);
        r = SettingsRoam.apply(qsList(), rec("a,custom(x/y)"), f, NONE);
        check("J7", r.failed == 1 && f.v(SettingsRoam.APPLIED_KEY) == null, "a failed put of the waiting row: no marker");
    }

    private static void j8() {
        Fake f = new Fake();
        SettingsRoam.Result r = SettingsRoam.apply(qsList(), rec("custom(x/y),custom(z/y)"), f, NONE);
        check("J8", f.v(QS) == null && !f.puts.contains(QS) && r.waiting == 2, "every tile waits: no put of the live row");
        check("J8", "?custom(x/y),?custom(z/y)".equals(f.v(SettingsRoam.TILES_KEY)) && r.marked, "the row holds them, marker set");
    }

    private static void j9() {
        char[] big = new char[8193];
        Arrays.fill(big, 'a');
        for (String bad : new String[] {"a b", "a?b", "", new String(big)}) {
            Fake f = new Fake();
            SettingsRoam.Result r = SettingsRoam.apply(qsList(), Arrays.asList(("sroam=secure " + QS + " " + bad).trim()), f, ALL);
            check("J9", f.puts.isEmpty() && r.malformed == 1 && !r.marked, "malformed (length " + bad.length() + "): nothing written");
        }
        List<SettingsRoam.Row> two = SettingsRoam.parseList(Arrays.asList("secure " + QS + " tiles", "system plain_row"));
        Fake f = new Fake();
        SettingsRoam.apply(two, Arrays.asList("sroam=secure " + QS + " a?b", "sroam=system plain_row v"), f, ALL);
        check("J9", f.puts.equals(Arrays.asList("plain_row")), "the other rows still apply, and the marker stays unset");
    }

    private static void table() {
        for (int c = 0x20; c <= 0x7e; c++) {
            System.out.printf("%02x %d%n", c, SettingsRoam.tilesValid(String.valueOf((char) c)) ? 1 : 0);
        }
        char[] a = new char[8192];
        Arrays.fill(a, 'a');
        System.out.println("len8192 " + (SettingsRoam.tilesValid(new String(a)) ? 1 : 0));
        System.out.println("len8193 " + (SettingsRoam.tilesValid(new String(a) + "a") ? 1 : 0));
        System.out.println("empty " + (SettingsRoam.tilesValid("") ? 1 : 0));
    }

    /** J10: the verdict table against the set the architecture states, written out here and in the suite. */
    private static void j10() {
        String set = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./(),-$";
        boolean same = true;
        for (char c = 0x20; c <= 0x7e; c++) same &= SettingsRoam.tilesValid(String.valueOf(c)) == (set.indexOf(c) >= 0);
        check("J10", same && set.length() == 70, "exactly the 70 characters of the set");
        check("J10", !SettingsRoam.tilesValid("a\n") && !SettingsRoam.tilesValid(null) && !SettingsRoam.tilesValid(""),
                "a trailing newline, null and empty are refused");
        char[] a = new char[8192];
        Arrays.fill(a, 'a');
        check("J10", SettingsRoam.tilesValid(new String(a)), "8192 characters pass");
        check("J10", !SettingsRoam.tilesValid(new String(a) + "a"), "8193 characters are refused");
    }

    /** The shell stub's directory as a store: <dir>/<scope>.<key>, no trailing newline. */
    private static SettingsRoam.Store dirStore(File dir) {
        return new SettingsRoam.Store() {
            @Override public String get(String scope, String key) {
                try {
                    return new String(Files.readAllBytes(new File(dir, scope + "." + key).toPath()), StandardCharsets.UTF_8);
                } catch (Exception e) {
                    return null;
                }
            }

            @Override public boolean put(String scope, String key, String value) {
                try {
                    Files.write(new File(dir, scope + "." + key).toPath(), value.getBytes(StandardCharsets.UTF_8));
                    return true;
                } catch (Exception e) {
                    return false;
                }
            }
        };
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("--table")) {
            table();
            return;
        }
        if (args.length == 5 && args[0].equals("--apply")) {
            // args: prefs.out, list file, installed package or -, stub dir. Lines arrive as DaemonSocket gives them.
            List<String> lines = new ArrayList<>();
            for (String l : Files.readAllLines(new File(args[1]).toPath())) if (!l.trim().isEmpty()) lines.add(l.trim());
            String have = args[3];
            SettingsRoam.apply(SettingsRoam.parseList(Files.readAllLines(new File(args[2]).toPath())), lines,
                    dirStore(new File(args[4])), have::equals);
            return;
        }
        if (args.length == 4 && args[0].equals("--reconcile")) {
            String have = args[2];
            SettingsRoam.reconcile(SettingsRoam.parseList(Files.readAllLines(new File(args[1]).toPath())).get(0),
                    dirStore(new File(args[3])), have::equals);
            return;
        }
        j1(); j2(); j3(); j4(); j5(); j6(); j7(); j8(); j9(); j10();
        System.exit(failed == 0 ? 0 : 1);
    }
}
