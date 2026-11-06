package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Random;

// NWP-20261012-06: the cases for KeepOrder -- the keep-set reorder behind "Your apps" drag and drop, the one-time fold
// of the retired "Download first" marks, the row order of the screen, and the "Wake for notifications" overrides.
// Package names are made up; nothing here is a real profile.
public final class KeepOrderCases {
    static int fails = 0, runs = 0;

    static void eq(String name, Object want, Object got) {
        runs++;
        if (!String.valueOf(want).equals(String.valueOf(got))) {
            fails++;
            System.out.println("FAIL " + name + "\n     want: " + show(want) + "\n     got:  " + show(got));
        }
    }

    static String show(Object o) { return String.valueOf(o).replace("\t", "\\t").replace("\n", "\\n"); }

    static List<String> l(String... s) { return Arrays.asList(s); }

    static List<String> sortedLines(String t) {
        List<String> x = new ArrayList<>(KeepOrder.lines(t));
        Collections.sort(x);
        return x;
    }

    public static void main(String[] a) throws Exception {
        // ---- reorder: verbatim lines, named first, the rest in their old order ----
        String keep = "a.one\tauto\n"
                + "b.two\n"
                + "c.three\tondemand\tgroup:play\n"
                + "d.four\tinstalled\tgroup:x\n";
        eq("reorder: named first, group tokens and modes verbatim, unnamed appended in old order",
                "c.three\tondemand\tgroup:play\na.one\tauto\nb.two\nd.four\tinstalled\tgroup:x\n",
                KeepOrder.reorder(keep, l("c.three", "a.one")));
        eq("reorder: a full order is followed exactly",
                "d.four\tinstalled\tgroup:x\nc.three\tondemand\tgroup:play\nb.two\na.one\tauto\n",
                KeepOrder.reorder(keep, l("d.four", "c.three", "b.two", "a.one")));
        eq("reorder: a name with no line is ignored (an Off row in the list)",
                "b.two\na.one\tauto\nc.three\tondemand\tgroup:play\nd.four\tinstalled\tgroup:x\n",
                KeepOrder.reorder(keep, l("zz.off", "b.two", "yy.off")));
        eq("reorder: a name given twice places its line once",
                "b.two\na.one\tauto\nc.three\tondemand\tgroup:play\nd.four\tinstalled\tgroup:x\n",
                KeepOrder.reorder(keep, l("b.two", "b.two", "a.one")));
        eq("reorder: a name with stray spaces still matches",
                "d.four\tinstalled\tgroup:x\na.one\tauto\nb.two\nc.three\tondemand\tgroup:play\n",
                KeepOrder.reorder(keep, l(" d.four ")));
        eq("reorder: no order keeps the file order",
                keep, KeepOrder.reorder(keep, null));
        eq("reorder: an empty order keeps the file order",
                keep, KeepOrder.reorder(keep, Collections.<String>emptyList()));
        eq("reorder: an empty file stays empty", "", KeepOrder.reorder("", l("a.one")));
        eq("reorder: blank lines dropped, CRLF read as line ends, the key read before the first tab",
                "b.two\na.one \tauto\n",
                KeepOrder.reorder("a.one \tauto\r\n\r\n   \nb.two\r\n", l("b.two")));
        eq("reorder: a package with two lines keeps both, together, at its place",
                "b.two\na.one\tauto\na.one\tinstalled\n",
                KeepOrder.reorder("a.one\tauto\nb.two\na.one\tinstalled\n", l("b.two")));
        eq("reorder: a name that is only a prefix of a package does not match it",
                "a.one\tauto\na.on\n",
                KeepOrder.reorder("a.on\na.one\tauto\n", l("a.one")));
        // Properties over random orders: nothing added or lost, and applying the same order twice changes nothing.
        Random rnd = new Random(20261012L);
        String big = "";
        List<String> names = new ArrayList<>();
        for (int i = 0; i < 12; i++) {
            String p = "p" + i + ".app";
            names.add(p);
            big += p + (i % 3 == 0 ? "\tauto" : i % 3 == 1 ? "\tondemand\tgroup:g" + i : "") + "\n";
        }
        for (int k = 0; k < 40; k++) {
            List<String> o = new ArrayList<>(names);
            Collections.shuffle(o, rnd);
            o = o.subList(0, rnd.nextInt(o.size() + 1));
            List<String> withNoise = new ArrayList<>(o);
            withNoise.add(rnd.nextInt(withNoise.size() + 1), "not.kept");
            String r1 = KeepOrder.reorder(big, withNoise);
            eq("reorder property " + k + ": same lines", sortedLines(big), sortedLines(r1));
            eq("reorder property " + k + ": idempotent", r1, KeepOrder.reorder(r1, withNoise));
            List<String> head = new ArrayList<>();
            for (String ln : KeepOrder.lines(r1)) head.add(KeepOrder.keyOf(ln));
            eq("reorder property " + k + ": the named lead, in order", o, head.subList(0, o.size()));
        }

        // ---- readText: the file I/O every keep-set and wake write reads through ----
        java.io.File tf = java.io.File.createTempFile("keeporder", ".txt");
        try {
            try (java.io.FileWriter fw = new java.io.FileWriter(tf)) {
                fw.write("a.one\tauto\r\nb.two\nc.three\tondemand\tgroup:play"); // CRLF, and no final newline
            }
            String txt = KeepOrder.readText(tf);
            eq("readText: one newline after every line, CR dropped", "a.one\tauto\nb.two\nc.three\tondemand\tgroup:play\n", txt);
            eq("readText then a drag: every line survives, as its own line",
                    "c.three\tondemand\tgroup:play\na.one\tauto\nb.two\n", KeepOrder.reorder(txt, l("c.three")));
            eq("readText then a drag: three lines, not one", 3, KeepOrder.lines(KeepOrder.reorder(txt, l("b.two"))).size());
            try (java.io.FileWriter fw = new java.io.FileWriter(tf)) { fw.write(""); }
            eq("readText: an empty file is empty", "", KeepOrder.readText(tf));
        } finally {
            tf.delete();
        }

        // ---- the "Download first" fold: the marks lead, in mark order, once ----
        eq("marks: in mark order, each once, blanks and spaces dropped", "[y.app, x.app]",
                KeepOrder.marks("y.app\n\n x.app \ny.app\n"));
        eq("marks: an absent or empty file has none", "[]", KeepOrder.marks(""));
        String auto = "x.app\tauto\ny.app\tauto\nz.app\tauto\nw.app\n";
        List<String> marks = KeepOrder.marks("z.app\nw.app\nnot.kept\n");
        String folded = KeepOrder.reorder(auto, marks);
        eq("fold: the marked apps move to the top in mark order; the rest keep theirs",
                "z.app\tauto\nw.app\nx.app\tauto\ny.app\tauto\n", folded);
        eq("fold: run again, nothing moves (a crash before the delete is harmless)", folded,
                KeepOrder.reorder(folded, marks));
        eq("fold: no marks, nothing moves", auto, KeepOrder.reorder(auto, KeepOrder.marks("")));

        // ---- Your apps rows: kept first in keep-set order, then the rest as found ----
        eq("keptFirst: kept rows in keep-set order, then launcher and Off rows in the order found",
                "[k1, k2, l1, o1, l2]",
                KeepOrder.keptFirst(l("l1", "k2", "o1", "k1", "l2"), l("k1", "gms.hidden", "k2")));
        eq("keptFirst: nothing kept leaves the order alone", "[b, a]",
                KeepOrder.keptFirst(l("b", "a"), Collections.<String>emptyList()));
        eq("keptFirst: a kept package with no row is not invented", "[a]",
                KeepOrder.keptFirst(l("a"), l("ghost", "a")));

        // ---- nowhere-appwake: overrides only ----
        Map<String, Boolean> w = KeepOrder.parseWake(
                "m.chat\toff\nn.shop\ton\nbad.value\tmaybe\nno.tab\n\ton\nthree.fields\ton\textra\n  \n");
        eq("parseWake: on and off read, malformed lines skipped", "{m.chat=false, n.shop=true}", w);
        eq("parseWake: a later line wins (off then on)", "{a=true}", KeepOrder.parseWake("a\toff\na\ton\n"));
        eq("parseWake: a later line wins (on then off)", "{a=false}", KeepOrder.parseWake("a\ton\na\toff\n"));
        eq("parseWake: spaces around the fields are tolerated", "{a=true}", KeepOrder.parseWake(" a \t on \n"));
        eq("setWake: adds a choice, keeps the others", "a\ton\nb\toff\n", KeepOrder.setWake("a\ton\n", "b", false));
        eq("setWake: replaces a choice", "a\toff\n", KeepOrder.setWake("a\ton\n", "a", false));
        eq("setWake: on an empty file", "a\ton\n", KeepOrder.setWake("", "a", true));
        eq("setWake round-trips through parseWake", "{a=true, b=false}",
                KeepOrder.parseWake(KeepOrder.setWake(KeepOrder.setWake("", "a", true), "b", false)));

        // ---- wakeFor: the override, else the messaging rule -- asked only when there is no override ----
        final int[] asked = { 0 };
        eq("wakeFor: no override, a messaging app wakes", true,
                KeepOrder.wakeFor(w, "x.chat", () -> { asked[0]++; return true; }));
        eq("wakeFor: no override, any other app does not", false,
                KeepOrder.wakeFor(w, "x.game", () -> { asked[0]++; return false; }));
        eq("wakeFor: the messaging rule was asked for both", 2, asked[0]);
        asked[0] = 0;
        eq("wakeFor: unchecked messaging app stays stopped", false,
                KeepOrder.wakeFor(w, "m.chat", () -> { asked[0]++; return true; }));
        eq("wakeFor: checked non-messaging app wakes", true,
                KeepOrder.wakeFor(w, "n.shop", () -> { asked[0]++; return false; }));
        eq("wakeFor: an override never asks PackageManager", 0, asked[0]);

        // ---- NWP-20261125-26: Your apps' not-saved words ----
        for (String[] w2 : new String[][] { { "WAKE_NOT_SAVED", KeepOrder.WAKE_NOT_SAVED },
                                            { "ORDER_NOT_SAVED", KeepOrder.ORDER_NOT_SAVED } }) {
            eq("words: " + w2[0] + " is set", true, w2[1] != null && !w2[1].trim().isEmpty());
            eq("words: " + w2[0] + " claims no save", false, w2[1] != null && w2[1].contains("Saved"));
            eq("words: " + w2[0] + " says the save failed", true, w2[1] != null && w2[1].startsWith("Couldn't save"));
        }

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
