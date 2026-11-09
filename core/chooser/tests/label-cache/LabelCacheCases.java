package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;

/**
 * NWP-20261128-43: the app-label cache's file rules (LabelCache), run by test-label-cache-java.sh. The file keeps its
 * order, a new or changed label moves to the end, and a write keeps the newest CAP labels, so a label learned last is
 * never the one a write leaves out.
 */
public final class LabelCacheCases {
    private static int fails = 0;
    private static int cases = 0;

    private static void check(boolean ok, String what) {
        cases++;
        if (!ok) {
            fails++;
            System.out.println("  FAIL  " + what);
        }
    }

    private static List<String> keys(LinkedHashMap<String,String> m) {
        return new ArrayList<>(m.keySet());
    }

    private static String last(LinkedHashMap<String,String> m) {
        String k = null;
        for (String s : m.keySet()) k = s;
        return k;
    }

    public static void main(String[] args) {
        // 1 parse keeps file order and drops a line with no tab, a leading tab or a trailing tab.
        LinkedHashMap<String,String> m = LabelCache.parse("a\tA\nnotab\n\tlead\ntrail\t\nb\tB\n");
        check(keys(m).equals(Arrays.asList("a", "b")), "parse keys are " + keys(m) + ", want [a, b]");
        check("A".equals(m.get("a")) && "B".equals(m.get("b")), "parse values are " + m);

        // 2 nothing to read gives an empty cache.
        check(LabelCache.parse(null).isEmpty(), "parse(null) is not empty");
        check(LabelCache.parse("").isEmpty(), "parse(\"\") is not empty");

        // 3 a later line for the same package wins and is last.
        m = LabelCache.parse("a\t1\nb\t2\na\t3\n");
        check(keys(m).equals(Arrays.asList("b", "a")), "duplicate: keys are " + keys(m) + ", want [b, a]");
        check("3".equals(m.get("a")), "duplicate: a is " + m.get("a") + ", want 3");

        // 4 put of an unchanged label: false, no change.
        m = LabelCache.parse("a\tA\nb\tB\n");
        check(!LabelCache.put(m, "a", "A"), "put of an unchanged label returned true");
        check(keys(m).equals(Arrays.asList("a", "b")), "put of an unchanged label moved it: " + keys(m));

        // 5 put of a new label and of a changed label: true, and it is last.
        check(LabelCache.put(m, "c", "C"), "put of a new label returned false");
        check("c".equals(last(m)), "a new label is not last: " + keys(m));
        check(LabelCache.put(m, "a", "A2"), "put of a changed label returned false");
        check("a".equals(last(m)) && "A2".equals(m.get("a")), "a changed label is not last with its new text: " + m);
        check(keys(m).equals(Arrays.asList("b", "c", "a")), "after the changed label, keys are " + keys(m));

        // 6 201 entries: render(m, 200) holds the newest 200, not the first inserted.
        m = new LinkedHashMap<>();
        for (int i = 0; i <= 200; i++) LabelCache.put(m, "p" + i, "P" + i);
        String out = LabelCache.render(m, 200);
        String[] lines = out.split("\n");
        check(lines.length == 200, "render(201, 200) wrote " + lines.length + " lines, want 200");
        LinkedHashMap<String,String> back = LabelCache.parse(out);
        check(back.containsKey("p200"), "render dropped the newest entry p200");
        check(back.containsKey("p1"), "render dropped p1");
        check(!back.containsKey("p0"), "render kept the first inserted p0 over a newer one");
        check("p1".equals(keys(back).get(0)) && "p200".equals(last(back)), "render order is not oldest-kept to newest");

        // 7 render then parse round-trips order and values.
        m = new LinkedHashMap<>();
        LabelCache.put(m, "z.one", "Zed One");
        LabelCache.put(m, "a.two", "Ay Two");
        LabelCache.put(m, "m.three", "Em Three");
        back = LabelCache.parse(LabelCache.render(m, LabelCache.CAP));
        check(keys(back).equals(keys(m)), "round trip keys are " + keys(back) + ", want " + keys(m));
        check(back.equals(m), "round trip values are " + back + ", want " + m);

        // 8 a label re-learned after 200 others survives the next render; the oldest one is pushed out.
        m = new LinkedHashMap<>();
        for (int i = 0; i < 200; i++) LabelCache.put(m, "p" + i, "P" + i);
        for (int i = 0; i < 200; i++) LabelCache.put(m, "q" + i, "Q" + i);
        check(LabelCache.put(m, "p0", "changed"), "re-learning p0 with a new label returned false");
        back = LabelCache.parse(LabelCache.render(m, LabelCache.CAP));
        check("changed".equals(back.get("p0")), "the re-learned p0 is not in the next file: " + back.get("p0"));
        check("p0".equals(last(back)), "the re-learned p0 is not last in the next file");
        check(!back.containsKey("q0"), "q0 is still in the file after 200 newer labels");
        check(back.size() == LabelCache.CAP, "the next file holds " + back.size() + " labels, want " + LabelCache.CAP);

        // 9 a map no larger than CAP renders whole.
        m = new LinkedHashMap<>();
        for (int i = 0; i < LabelCache.CAP; i++) LabelCache.put(m, "r" + i, "R" + i);
        back = LabelCache.parse(LabelCache.render(m, LabelCache.CAP));
        check(back.equals(m) && keys(back).equals(keys(m)), "render of CAP entries lost or reordered some");
        check(LabelCache.CAP == 200, "CAP is " + LabelCache.CAP + ", want 200");

        if (fails > 0) {
            System.out.println("FAIL " + fails + " of " + cases + " checks");
            System.exit(1);
        }
        System.out.println("PASS " + cases + " checks");
    }
}
