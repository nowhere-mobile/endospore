package com.nowhere.chooser;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * NWP-20261120-14: WifiMirrorPick.order EXECUTED (the connected network first, within MAX), WifiMirror.capture pinned
 * by text to send what order returns with no cap of its own, and MAX pinned at or below handleWifiMirror's bound,
 * read from core/agent/main.go. Args: <WifiMirror.java> <main.go>. Exit 0 every case passed, 1 a case failed, 2 an
 * anchor was not found (the pins cannot run).
 */
public final class Cases {
    private static int failed = 0;

    private static void check(String what, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failed++;
    }

    private static void cannot(String why) {
        System.out.println("  CANNOT RUN  " + why);
        System.exit(2);
    }

    private static List<String> lines(int n) {
        List<String> l = new ArrayList<>();
        for (int i = 0; i < n; i++) l.add("L" + i);
        return l;
    }

    private static List<String> want(int... idx) {
        List<String> l = new ArrayList<>();
        for (int i : idx) l.add("L" + i);
        return l;
    }

    private static int[] range(int from, int to) { // [from, to]
        int[] r = new int[to - from + 1];
        for (int i = 0; i < r.length; i++) r[i] = from + i;
        return r;
    }

    private static int[] cat(int[]... parts) {
        int len = 0;
        for (int[] p : parts) len += p.length;
        int[] r = new int[len];
        int k = 0;
        for (int[] p : parts) for (int v : p) r[k++] = v;
        return r;
    }

    private static void order(String what, List<String> in, int currentAt, List<String> expect) {
        List<String> before = in == null ? null : new ArrayList<>(in);
        List<String> got = WifiMirrorPick.order(in, currentAt);
        boolean ok = got != null && got.equals(expect) && (in == null || in.equals(before));
        check(what + (ok ? "" : " (got " + got + ")"), ok);
    }

    /** Drops // and block comments; string and char literals are kept as they are. */
    private static String stripComments(String s) {
        StringBuilder o = new StringBuilder();
        int i = 0, n = s.length();
        while (i < n) {
            char c = s.charAt(i);
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && s.charAt(j) != c) j += s.charAt(j) == '\\' ? 2 : 1;
                j = Math.min(j + 1, n);
                o.append(s, i, j);
                i = j;
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '/') {
                while (i < n && s.charAt(i) != '\n') i++;
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                int e = s.indexOf("*/", i + 2);
                i = e < 0 ? n : e + 2;
                o.append(' ');
            } else {
                o.append(c);
                i++;
            }
        }
        return o.toString();
    }

    /** The brace-matched body of the first method whose header contains {@code header}; null when absent. */
    private static String body(String src, String header) {
        int h = src.indexOf(header);
        if (h < 0) return null;
        int open = src.indexOf('{', h);
        if (open < 0) return null;
        int depth = 0;
        for (int i = open; i < src.length(); i++) {
            char c = src.charAt(i);
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < src.length() && src.charAt(j) != c) j += src.charAt(j) == '\\' ? 2 : 1;
                i = j;
                continue;
            }
            if (c == '{') depth++;
            if (c == '}' && --depth == 0) return src.substring(open, i + 1);
        }
        return null;
    }

    public static void main(String[] a) throws Exception {
        if (a.length != 2) cannot("usage: Cases <WifiMirror.java> <main.go>");

        // --- WifiMirrorPick.order, executed ---------------------------------------------------------------------------
        order("current late is kept first: 20 lines, currentAt 17 -> L17, L0..L14", lines(20), 17,
                want(cat(new int[] {17}, range(0, 14))));
        order("current early moves first: 20 lines, currentAt 3 -> L3, L0..L2, L4..L15", lines(20), 3,
                want(cat(new int[] {3}, range(0, 2), range(4, 15))));
        order("no current keeps framework order: 20 lines, currentAt -1 -> L0..L15", lines(20), -1, want(range(0, 15)));
        order("current first, under the cap: 10 lines, currentAt 0 -> unchanged", lines(10), 0, want(range(0, 9)));
        order("current last, under the cap: 10 lines, currentAt 9 -> L9, L0..L8", lines(10), 9,
                want(cat(new int[] {9}, range(0, 8))));
        order("index past the end counts as -1: currentAt 99", lines(20), 99, want(range(0, 15)));
        order("negative index counts as -1: currentAt -5", lines(20), -5, want(range(0, 15)));
        order("empty input gives an empty list", new ArrayList<>(), -1, new ArrayList<>());
        order("null input gives an empty list", null, 0, new ArrayList<>());
        List<String> holed = lines(18);
        holed.set(2, null); // 17 non-null
        order("a null entry is skipped and does not count toward MAX", holed, -1,
                want(cat(range(0, 1), range(3, 16))));
        order("currentAt on a null entry counts as -1", holed, 2, want(cat(range(0, 1), range(3, 16))));
        check("MAX is 16 (the mirror's cap, kept for amnesia finding #9), got " + WifiMirrorPick.MAX,
                WifiMirrorPick.MAX == 16);

        // --- WifiMirror.capture, by text (comments dropped) ------------------------------------------------------------
        String wm = stripComments(new String(Files.readAllBytes(Paths.get(a[0])), "UTF-8"));
        String cap = body(wm, "static void capture(");
        if (cap == null) cannot("no capture( body in " + a[0]);
        check("capture sends WifiMirrorPick.order(lines, currentAt)",
                cap.contains("java.util.List<String> sent = WifiMirrorPick.order(lines, currentAt);"));
        check("capture's payload count is the size of the list order returned",
                cap.contains("int n = sent.size();")
                        && cap.contains("for (String l : sent) sb.append(l).append('\\n');")
                        && cap.contains("send(\"WIFI-MIRROR\\n\" + n + \"\\n\" + sb)"));
        check("capture still encodes with WifiMirrorLine.encode(c.SSID, c.preSharedKey, c.macRandomizationSetting)",
                cap.contains("WifiMirrorLine.encode(c.SSID, c.preSharedKey, c.macRandomizationSetting)"));
        check("capture marks the connected network by its id",
                cap.contains("cur = wi.getNetworkId();") && cap.contains("if (cur != -1 && c.networkId == cur) currentAt = lines.size();"));
        List<String> caps = new ArrayList<>();
        Matcher cmp = Pattern.compile("(<=|>=|==|!=|<|>)\\s*(-?\\d+)\\b").matcher(cap);
        while (cmp.find()) {
            String op = cmp.group(1), lit = cmp.group(2);
            if (!((op.equals("==") && lit.equals("0")) || (op.equals("!=") && lit.equals("-1")))) caps.add(cmp.group());
        }
        Matcher sixteen = Pattern.compile("(?<![\\w.])16(?![\\w.])").matcher(cap);
        while (sixteen.find()) caps.add("literal 16");
        check("capture has no numeric cap of its own (no `>= 16` or other bound against a literal)"
                + (caps.isEmpty() ? "" : " (found " + caps + ")"), caps.isEmpty());

        // --- MAX against the daemon's bound, read from main.go ---------------------------------------------------------
        String go = new String(Files.readAllBytes(Paths.get(a[1])), "UTF-8");
        int f = go.indexOf("\nfunc handleWifiMirror(");
        if (f < 0) cannot("no func handleWifiMirror( in " + a[1]);
        int end = go.indexOf("\nfunc ", f + 1);
        String hw = go.substring(f, end < 0 ? go.length() : end);
        Matcher b = Pattern.compile("n <= 0 \\|\\| n > (\\d+)").matcher(hw);
        List<Integer> bounds = new ArrayList<>();
        while (b.find()) bounds.add(Integer.parseInt(b.group(1)));
        if (bounds.size() != 1) cannot("expected one `n <= 0 || n > N` in handleWifiMirror, found " + bounds);
        int bound = bounds.get(0);
        check("WifiMirrorPick.MAX (" + WifiMirrorPick.MAX + ") is at most handleWifiMirror's bound (" + bound + ")",
                WifiMirrorPick.MAX <= bound);

        System.out.println(failed == 0 ? "every case passed" : failed + " case(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
