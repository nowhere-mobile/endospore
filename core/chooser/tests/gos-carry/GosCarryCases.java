package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.StringReader;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.ToLongFunction;

/** NWP-20261017-15: GosState's receipt rule and carry-forward decision. NWP-20261111-05: the strict carry-file read. */
public final class GosCarryCases {
    private static int fails = 0;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) fails++;
    }

    private static BufferedReader rd(String s) { return new BufferedReader(new StringReader(s)); }

    private static Map<String, Long> rows(Object... kv) {
        Map<String, Long> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], ((Number) kv[i + 1]).longValue());
        return m;
    }

    private static Set<String> set(String... s) { return new LinkedHashSet<>(Arrays.asList(s)); }

    private static ToLongFunction<String> reads(Map<String, Long> m) {
        return p -> m.containsKey(p) ? m.get(p) : 0L;
    }

    private static boolean liveOf(Map<String, Long> old, String receipt) {
        return GosState.liveFor(receipt == null ? false : GosState.parseReceipt(rd(receipt)).live, old);
    }

    public static void main(String[] args) throws Exception {
        Map<String, Long> sealed = rows("a", 0x40L);

        System.out.println("== the receipt: is the mechanism live? ==");
        check(GosState.liveFor(false, rows()), "an empty sealed set is live with no receipt");
        check(!liveOf(sealed, null), "a sealed set with no receipt is NOT live");
        check(!liveOf(sealed, ""), "a sealed set with an empty receipt is NOT live");
        check(!liveOf(sealed, "a\nb\n"), "a sealed set with a receipt of bare packages is NOT live");
        check(!liveOf(sealed, "#partial\na\n"), "a '#partial' comment is not '#live'");
        check(liveOf(sealed, "#live\na\n"), "'#live' makes it live");
        check(liveOf(sealed, "#live empty\n"), "'#live empty' makes it live");
        GosState.Receipt part = GosState.parseReceipt(rd("#partial\na\n"));
        check(part.applied.contains("a") && !part.applied.contains("#partial") && part.applied.size() == 1,
                "in '#partial\\na' only 'a' is applied");
        check(GosState.parseReceipt(rd("#live\n  a  \n\nb\n")).applied.equals(set("a", "b")),
                "applied lines are trimmed and blanks skipped");

        System.out.println("== the carry decision ==");
        GosState.Carried c = GosState.carry(sealed, set("a"), Arrays.asList("a"), reads(rows("a", 0L)));
        check(!c.out.containsKey("a") && c.carried == 0, "applied and read 0 -> the row is dropped");
        c = GosState.carry(sealed, set("a"), Arrays.asList("a"), p -> -1L);
        check(c.out.equals(rows("a", 0x40L)) && c.carried == 1, "applied and unreadable -> old row carried and counted");
        c = GosState.carry(sealed, set(), Arrays.asList("a"), reads(rows("a", 0L)));
        check(c.out.equals(rows("a", 0x40L)) && c.carried == 1, "not applied and read 0 -> old row carried");
        c = GosState.carry(sealed, set(), Arrays.asList("a"), p -> -1L);
        check(c.out.equals(rows("a", 0x40L)) && c.carried == 1, "not applied and unreadable -> old row carried");
        c = GosState.carry(rows(), set(), Arrays.asList("n"), reads(rows("n", 0x40L)));
        check(c.out.equals(rows("n", 0x40L)) && c.carried == 0, "not applied and read 0x40 -> captured, not counted as carried");
        c = GosState.carry(sealed, set("a"), Arrays.asList("a"), reads(rows("a", 0x80L)));
        check(c.out.equals(rows("a", 0x80L)), "applied and read non-zero -> the live word replaces the old row");
        c = GosState.carry(sealed, set(), Arrays.asList("z"), reads(rows("z", 0L)));
        check(c.out.isEmpty() && c.carried == 0, "a candidate absent from old with read 0 is absent from out");
        c = GosState.carry(rows(), set("z"), Arrays.asList("z"), p -> -1L);
        check(c.out.isEmpty() && c.carried == 0, "applied, unreadable and never sealed -> nothing to carry");

        System.out.println("== the sealed file ==");
        Map<String, Long> p = GosState.parseRows(rd("a\t" + Long.toHexString(0x2000000L | 0x40L) + "\n"));
        check(p.get("a") == 0x40L, "a flag outside MASK is masked off on parse");
        check(GosState.MASK == 0x1FFFFC2L, "the shipped MASK is the compiled one");
        p = GosState.parseRows(rd("pkg\tzz\nonefield\n#c\n\n\t40\nok\t40\n"));
        check(p.equals(rows("ok", 0x40L)), "'pkg\\tzz', a one-field line, a comment, a blank and an empty name are skipped, not fatal");
        Map<String, Long> m = rows("a", 0x40L, "b", 0x1000042L);
        check(GosState.parseRows(rd(GosState.rowsText(m))).equals(m), "rowsText round-trips through parseRows");
        check(GosState.rowsText(rows("a", 0x40L)).equals("a\t40\n"), "rowsText writes <pkg>\\t<hex>\\n");

        System.out.println("== the carry file, read strictly (NWP-20261111-05) ==");
        File dir = Files.createTempDirectory("gos-carry").toFile();   // under -Djava.io.tmpdir, run.sh's D
        try {
            check(GosState.readRows(new File(dir, "absent")).isEmpty(), "R1 an absent carry file is an empty map");
            File rowsFile = new File(dir, "nowhere-gosstate");
            Files.write(rowsFile.toPath(), ("a\t" + Long.toHexString(0x2000000L | 0x40L) + "\n#c\nb\t1000042\n").getBytes("UTF-8"));
            check(GosState.readRows(rowsFile).equals(rows("a", 0x40L, "b", 0x1000042L)), "R2 a regular file's rows come back masked");
            File unopenable = new File(dir, "unopenable");
            check(unopenable.mkdir(), "R3 setup: a directory at the path");
            boolean threw = false;
            try { GosState.readRows(unopenable); } catch (IOException e) { threw = true; }
            check(threw, "R3 a path that exists but cannot be opened THROWS (never an empty map)");
        } finally {
            File[] left = dir.listFiles();
            if (left != null) for (File f : left) f.delete();
            dir.delete();
        }
        BufferedReader boom = new BufferedReader(new StringReader("")) {
            private int n = 0;
            @Override public String readLine() throws IOException {
                if (n++ == 0) return "a\t40";
                throw new IOException("mid-read");
            }
        };
        boolean threwMid = false;
        try { GosState.parseRows(boom); } catch (IOException e) { threwMid = true; }
        check(threwMid, "R4 parseRows propagates an IOException after one good line (no partial map)");

        System.out.println("== what apply writes ==");
        List<String> none = Collections.emptyList();
        check(GosState.receiptText(true, 0, none).equals("#live empty\n"), "nothing sealed -> '#live empty'");
        check(GosState.receiptText(false, 2, Arrays.asList("a", "b")).equals("#live\na\nb\n"), "two landed -> '#live' then the packages");
        check(GosState.receiptText(false, 0, none).equals(""), "every write failed -> no receipt at all");
        check(!GosState.parseReceipt(rd(GosState.receiptText(false, 0, none))).live, "a failed apply's receipt reads as not live");
        check(GosState.parseReceipt(rd(GosState.receiptText(false, 1, Arrays.asList("a")))).live, "a landed apply's receipt reads as live");

        if (fails > 0) { System.out.println("FAILED: " + fails); System.exit(1); }
        System.out.println("PASS");
    }
}
