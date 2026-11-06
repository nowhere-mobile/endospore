package com.nowhere.chooser;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** NWP-20261015-28: the held-list format, the floor arithmetic and both release paths of AppHeld; readText (NWP-20261111-19). */
public final class AppHeldCases {
    private static int fails = 0;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) fails++;
    }

    private static Map<String, Long> floors(Object... kv) {
        Map<String, Long> m = new HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], ((Number) kv[i + 1]).longValue());
        return m;
    }

    private static AppHeld.Held parse(String text) { return AppHeld.parseHeld(text, "#stamp 13"); }

    public static void main(String[] args) {
        System.out.println("== the file: render -> parse ==");
        List<String> pkgs = Arrays.asList("com.a", "org.b");
        Map<String, Long> rel = floors("com.z", 500L, "com.a", 7L);
        String text = AppHeld.renderHeld("#stamp 13", pkgs, rel);
        AppHeld.Held h = parse(text);
        check(h.stampMatched, "a matching stamp reads as matched");
        check(h.pkgs.equals(pkgs), "packages round-trip in order");
        check(h.released.equals(rel), "release floors round-trip");
        check(text.indexOf("#rel com.a 7\n") < text.indexOf("#rel com.z 500\n") && text.indexOf("#rel com.a") >= 0,
                "floors are written sorted by package");

        System.out.println("== a different session's file is empty ==");
        AppHeld.Held other = AppHeld.parseHeld(AppHeld.renderHeld("#stamp 12", pkgs, rel), "#stamp 13");
        check(!other.stampMatched, "#stamp 12 against #stamp 13 is not matched");
        check(other.pkgs.isEmpty(), "... and holds no packages");
        check(other.released.isEmpty(), "... and carries no floors");
        check(!parse("").stampMatched && parse("").pkgs.isEmpty(), "an empty file is unmatched and empty");

        System.out.println("== a malformed #rel line is no floor ==");
        for (String bad : new String[] { "#rel a 1 2", "#rel a x", "#rel" }) {
            AppHeld.Held m = parse("#stamp 13\n" + bad + "\ncom.b\n");
            check(!m.released.containsKey("a"), "'" + bad + "' gives no floor");
            check(m.pkgs.equals(Arrays.asList("com.b")), "'" + bad + "' is not read as a package");
        }
        check(parse("#stamp 13\n#rel a 5\n").released.get("a") == 5L, "a well-formed #rel line is read");

        System.out.println("== path separators and the seal's reader contract ==");
        AppHeld.Held p = parse("#stamp 13\ncom/evil\nco\\m.evil\ncom.ok\n");
        check(p.pkgs.equals(Arrays.asList("com.ok")), "lines with / or \\ are dropped");
        boolean allHash = true;
        for (String ln : text.split("\n")) {
            if (!pkgs.contains(ln) && !ln.startsWith("#")) allHash = false;
        }
        check(allHash, "every non-package line renderHeld writes starts with #");
        check(AppHeld.renderHeld("#stamp 13", new ArrayList<String>(), new HashMap<String, Long>()).startsWith("#"),
                "an empty list still writes a comment-only file");

        System.out.println("== floorWall ==");
        check(AppHeld.floorWall(900_000L, null, 1_000_000L, 5_000L) == 900_000L, "no release -> the session floor");
        check(AppHeld.floorWall(100_000L, 40_000L, 1_000_000L, 100_000L) == 940_000L,
                "a release 60 s ago -> nowWall - 60 s");
        check(AppHeld.floorWall(990_000L, 40_000L, 1_000_000L, 100_000L) == 990_000L,
                "a release older than sign-in -> the session floor");

        System.out.println("== release ==");
        AppHeld.Held base = new AppHeld.Held(new ArrayList<>(Arrays.asList("a", "b")), floors("c", 3L), true);
        AppHeld.Held one = AppHeld.releaseOf(base, "a", 9_000L);
        check(one.pkgs.equals(Arrays.asList("b")), "releasing a frees a and keeps b");
        check(one.released.get("a") == 9_000L && one.released.get("c") == 3L, "a's floor is nowElapsed; others kept");
        check(base.pkgs.size() == 2 && !base.released.containsKey("a"), "the input is not modified");
        AppHeld.Held all = AppHeld.releaseOf(base, null, 9_000L);
        check(all.pkgs.isEmpty() && all.released.get("a") == 9_000L && all.released.get("b") == 9_000L,
                "releasing all frees both and floors both");

        System.out.println("== sign-out ==");
        AppHeld.Held out = AppHeld.signOutOf(base);
        check(out.pkgs.isEmpty(), "sign-out empties the list");
        check(out.released.equals(floors("c", 3L)), "... and returns the floors UNCHANGED");

        System.out.println("== readText: absent, readable, unreadable (NWP-20261111-19) ==");
        try {
            File dir = Files.createTempDirectory("appheld").toFile(); // under -Djava.io.tmpdir, which run.sh removes
            check("".equals(AppHeld.readText(new File(dir, "absent.list"))), "T1 an absent file reads as \"\"");
            File f = new File(dir, "held.list");
            Files.write(f.toPath(), "#stamp 13\n#rel a 5\ncom.b".getBytes(StandardCharsets.UTF_8));
            check("#stamp 13\n#rel a 5\ncom.b\n".equals(AppHeld.readText(f)),
                    "T2 a readable file is its text, one \\n after each line");
            Files.write(f.toPath(), "#stamp 13\ncom.b\n".getBytes(StandardCharsets.UTF_8));
            check("#stamp 13\ncom.b\n".equals(AppHeld.readText(f)), "T2 ... and its line ends are kept as they are");
            File asDir = new File(dir, "held.dir");
            check(asDir.mkdir(), "T3 setup: a directory stands at the list's path");
            check(AppHeld.readText(asDir) == null, "T3 a path that exists but cannot be opened reads as null");
            f.delete(); asDir.delete(); dir.delete();
        } catch (Throwable t) {
            check(false, "the readText cases threw " + t);
        }

        System.out.println(fails == 0 ? "PASS" : "FAILED: " + fails);
        System.exit(fails == 0 ? 0 : 1);
    }
}
