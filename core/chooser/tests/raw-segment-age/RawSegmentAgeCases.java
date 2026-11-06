package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.TreeMap;

/** Cases for RawSegmentAge (NWP-20261108-10, Q033; orphans: NWP-20261115-07, #36). Exits 1 on any failure. */
public final class RawSegmentAgeCases {
    private static final long T0 = 1_700_000_000_000L;
    private static final long H = 3_600_000L;
    private static final long DAY = 24 * H;
    private static int fails = 0;

    private static void check(String name, boolean cond) {
        if (cond) System.out.println("  ok    " + name);
        else { fails++; System.out.println("  FAIL  " + name); }
    }

    private static TreeMap<Long, Long> rec(long... kv) {
        TreeMap<Long, Long> m = new TreeMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    private static List<Long> ids(long... v) {
        List<Long> l = new ArrayList<>();
        for (long x : v) l.add(x);
        return l;
    }

    private static RawSegmentAge.Row row(long id, String addr, Integer ref, Integer count, Integer seq, Integer port) {
        return new RawSegmentAge.Row(id, addr, ref, count, seq, port);
    }

    /** One sender's text: ids from firstId, one row per sequence value, reference 7 and no port. */
    private static List<RawSegmentAge.Row> text(long firstId, String addr, int ref, int count, Integer... seqs) {
        List<RawSegmentAge.Row> l = new ArrayList<>();
        for (Integer s : seqs) l.add(row(firstId++, addr, ref, count, s, null));
        return l;
    }

    private static List<RawSegmentAge.Row> join(List<RawSegmentAge.Row> a, List<RawSegmentAge.Row> b) {
        List<RawSegmentAge.Row> l = new ArrayList<>(a);
        l.addAll(b);
        return l;
    }

    public static void main(String[] args) {
        RawSegmentAge.Plan p = RawSegmentAge.plan(rec(), ids(5), T0);
        check("first sight stamps now", p.record.equals(rec(5, T0)) && p.remove.isEmpty() && p.stamped == 1);

        p = RawSegmentAge.plan(rec(5, T0), ids(5), T0 + DAY - 60_000L);
        check("23 h 59 m is kept with its stamp", p.record.equals(rec(5, T0)) && p.remove.isEmpty() && p.stamped == 0);

        p = RawSegmentAge.plan(rec(5, T0), ids(5), T0 + DAY);
        check("exactly 24 h is removed", p.remove.equals(ids(5)));
        check("a removed id keeps its stamp", p.record.equals(rec(5, T0)));
        p = RawSegmentAge.plan(p.record, ids(5), T0 + DAY + H);
        check("a removal that failed is retried at the next scan", p.remove.equals(ids(5)) && p.record.equals(rec(5, T0)));

        p = RawSegmentAge.plan(rec(5, T0 + H), ids(5), T0);
        check("a stamp after now is re-stamped and not removed",
              p.record.equals(rec(5, T0)) && p.remove.isEmpty() && p.stamped == 1);
        p = RawSegmentAge.plan(rec(5, T0 + 5 * DAY), ids(5), T0);
        check("a stamp far in the future is re-stamped, never removed", p.remove.isEmpty() && p.record.equals(rec(5, T0)));

        p = RawSegmentAge.plan(rec(5, T0, 6, T0), ids(6), T0 + H);
        check("a vanished id is dropped", p.record.equals(rec(6, T0)) && p.remove.isEmpty());

        TreeMap<Long, Long> m = RawSegmentAge.parse("5 abc\nx\n6 -1\n7\n8 10 11\n9 " + T0 + "\n");
        check("a malformed line is ignored", m.equals(rec(9, T0)));
        m = RawSegmentAge.parse("5 abc\n");
        p = RawSegmentAge.plan(m, ids(5), T0 + 2 * DAY);
        check("a malformed line's id reads as first seen now, never removed",
              p.remove.isEmpty() && p.record.equals(rec(5, T0 + 2 * DAY)));
        check("a duplicate id keeps the later stamp", RawSegmentAge.parse("5 10\n5 30\n5 20\n").equals(rec(5, 30)));
        check("a CRLF line is read", RawSegmentAge.parse("5 10\r\n").equals(rec(5, 10)));

        TreeMap<Long, Long> r = rec(1, T0, 7, T0 + 5, 900, T0 + 9);
        String f = RawSegmentAge.format(r);
        check("format is one '<id> <ms>' line per entry, ascending",
              f.equals("1 " + T0 + "\n7 " + (T0 + 5) + "\n900 " + (T0 + 9) + "\n"));
        check("parse/format round trip", RawSegmentAge.parse(f).equals(r) && RawSegmentAge.format(RawSegmentAge.parse(f)).equals(f));
        check("parse of nothing is empty", RawSegmentAge.parse("").isEmpty() && RawSegmentAge.parse(null).isEmpty());

        List<Long> many = new ArrayList<>();
        for (long i = 600; i >= 1; i--) many.add(i);
        p = RawSegmentAge.plan(rec(), many, T0);
        check("the cap keeps the lowest 512 ids",
              p.record.size() == 512 && p.record.firstKey() == 1 && p.record.lastKey() == 512 && p.stamped == 512);
        p = RawSegmentAge.plan(rec(600, T0), many, T0 + 2 * DAY);
        check("an id past the cap is neither recorded nor removed", !p.record.containsKey(600L) && !p.remove.contains(600L));

        p = RawSegmentAge.plan(rec(), Arrays.asList(4L, 4L, 4L), T0);
        check("duplicate waiting ids collapse", p.record.equals(rec(4, T0)) && p.stamped == 1);

        check("the window is 24 h", RawSegmentAge.WINDOW_MS == 86_400_000L);

        // #36 (2026-10-22): only orphan segments are stamped; a complete text is left for the framework.
        check("a 3-part text with sequences 1,2,3 has no orphan",
              RawSegmentAge.orphans(text(1, "A", 7, 3, 1, 2, 3)).isEmpty());
        check("2 of 3 parts are both orphans", RawSegmentAge.orphans(text(1, "A", 7, 3, 1, 2)).equals(ids(1, 2)));
        check("a single-part row is no orphan", RawSegmentAge.orphans(Arrays.asList(row(1, "A", -1, 1, 1, null))).isEmpty());
        check("a single-part row with a null sequence and a null reference number is no orphan",
              RawSegmentAge.orphans(Arrays.asList(row(1, "A", null, 1, null, null))).isEmpty());
        check("a single-part row with sequence 0 is no orphan",
              RawSegmentAge.orphans(Arrays.asList(row(1, "A", -1, 1, 0, null))).isEmpty());
        check("two single-part rows from one sender are no orphans",
              RawSegmentAge.orphans(Arrays.asList(row(1, "A", -1, 1, 1, null), row(2, "A", -1, 1, 1, null))).isEmpty());
        List<RawSegmentAge.Row> twoRefs = join(text(1, "A", 7, 3, 1, 2, 3), text(4, "A", 8, 3, 1, 2));
        check("one sender, two reference numbers: only the incomplete one's ids",
              RawSegmentAge.orphans(twoRefs).equals(ids(4, 5)));
        check("the same address and reference number with a different count are two groups",
              RawSegmentAge.orphans(join(text(1, "A", 5, 2, 1, 2), text(3, "A", 5, 3, 3))).equals(ids(3)));
        check("sequences 1,1,2 of count 3 are all orphans",
              RawSegmentAge.orphans(text(1, "A", 7, 3, 1, 1, 2)).equals(ids(1, 2, 3)));
        check("sequences 1,1,3 of count 3 are all orphans (three rows, two distinct parts)",
              RawSegmentAge.orphans(text(1, "A", 7, 3, 1, 1, 3)).equals(ids(1, 2, 3)));
        check("sequences 1,2,5 of count 3 are all orphans",
              RawSegmentAge.orphans(text(1, "A", 7, 3, 1, 2, 5)).equals(ids(1, 2, 3)));
        check("sequences 0,1,2 of count 3 are all orphans",
              RawSegmentAge.orphans(text(1, "A", 7, 3, 0, 1, 2)).equals(ids(1, 2, 3)));
        check("sequences 1,2,3,4 of count 3 are all orphans",
              RawSegmentAge.orphans(text(1, "A", 7, 3, 1, 2, 3, 4)).equals(ids(1, 2, 3, 4)));
        check("a multipart row with a null sequence is an orphan, that row only",
              RawSegmentAge.orphans(join(text(1, "A", 7, 3, 1, 2, 3), Arrays.asList(row(9, "A", 7, 3, null, null))))
                  .equals(ids(9)));
        check("a null count is an orphan", RawSegmentAge.orphans(Arrays.asList(row(1, "A", 7, null, 1, null))).equals(ids(1)));
        check("a count below 1 is an orphan",
              RawSegmentAge.orphans(Arrays.asList(row(1, "A", 7, 0, 1, null), row(2, "A", 7, -1, 1, null))).equals(ids(1, 2)));
        check("two senders sharing a reference number, one part each of a 2-part text, are both orphans",
              RawSegmentAge.orphans(Arrays.asList(row(1, "A", 7, 2, 1, null), row(2, "B", 7, 2, 2, null))).equals(ids(1, 2)));
        check("a different destination port splits the group, so both are orphans",
              RawSegmentAge.orphans(Arrays.asList(row(1, "A", 7, 2, 1, null), row(2, "A", 7, 2, 2, 2948))).equals(ids(1, 2)));
        check("a null address is a key value of its own: a complete text from it is no orphan",
              RawSegmentAge.orphans(text(1, null, 7, 2, 1, 2)).isEmpty());
        check("orphans are ascending ids",
              RawSegmentAge.orphans(Arrays.asList(row(9, "A", 7, 3, 1, null), row(2, "B", 7, 3, 1, null))).equals(ids(2, 9)));
        check("orphans of no rows is empty", RawSegmentAge.orphans(new ArrayList<RawSegmentAge.Row>()).isEmpty());
        p = RawSegmentAge.plan(rec(), RawSegmentAge.orphans(twoRefs), T0);
        check("plan over orphans never stamps a complete text's ids",
              p.record.equals(rec(4, T0, 5, T0)) && p.stamped == 2 && p.remove.isEmpty());
        p = RawSegmentAge.plan(rec(1, T0, 2, T0, 3, T0, 4, T0), RawSegmentAge.orphans(twoRefs), T0 + DAY);
        check("a complete text's old stamps are dropped, never removed",
              p.remove.equals(ids(4)) && p.record.equals(rec(4, T0, 5, T0 + DAY)));

        System.out.println(fails == 0 ? "all cases passed" : fails + " case(s) FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
