package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/**
 * NWP-20261104-20: UnarchiveReceiver acts only on the system's unarchive request. UnarchiveGate's verdict, compiled
 * with UnarchiveGate ALONE (java.* only), plus source pins that read the receiver and the manifest as text. args[0]
 * is the repo root.
 */
public class UnarchiveGateCases {
    static final String SYS = "android.intent.action.UNARCHIVE_PACKAGE";
    static final String REFUSED_LOG = "\"unarchive refused: not the system's unarchive request\"";
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static boolean acc(String action, String pkg) { return UnarchiveGate.accept(action, pkg); }

    static String chars(int n) {
        StringBuilder b = new StringBuilder("a.");
        while (b.length() < n) b.append('b');
        return b.toString();
    }

    static String read(String root, String rel) throws Exception {
        return new String(Files.readAllBytes(Paths.get(root, rel)), StandardCharsets.UTF_8);
    }

    /** Drops block and line comments; the receiver holds no "//" inside a string, so this is enough. */
    static String strip(String s) {
        return s.replaceAll("(?s)/\\*.*?\\*/", "").replaceAll("//[^\n]*", "");
    }

    /** The text from the first '{' at or after from, up to its matching '}', or null. */
    static String block(String s, int from) {
        int open = s.indexOf('{', from);
        if (open < 0) return null;
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return s.substring(open, i + 1);
        }
        return null;
    }

    static void pins(String root) {
        String recv = null, manifest = null;
        try {
            recv = strip(read(root, "core/chooser/src/com/nowhere/chooser/UnarchiveReceiver.java"));
            manifest = read(root, "core/chooser/AndroidManifest.xml");
        } catch (Exception e) {
            check("p0 sources readable", false, e.toString());
            return;
        }
        // p1: the manifest filter action is the gate's ACTION.
        int r = manifest.indexOf("<receiver android:name=\".UnarchiveReceiver\"");
        int re = r < 0 ? -1 : manifest.indexOf("</receiver>", r);
        String el = re < 0 ? "" : manifest.substring(r, re);
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("<action android:name=\"([^\"]*)\"").matcher(el);
        String act = m.find() ? m.group(1) : null;
        boolean one = act != null && !m.find();
        check("p1 manifest filter action equals UnarchiveGate.ACTION", one && UnarchiveGate.ACTION.equals(act),
                "action=" + act + " single=" + one);

        // p2: the gate is the first decision in onReceive.
        int on = recv.indexOf("public void onReceive(");
        String body = on < 0 ? null : block(recv, on);
        int g = body == null ? -1 : body.indexOf("UnarchiveGate.accept(");
        int fgs = body == null ? -1 : body.indexOf("startForegroundService(");
        int rep = body == null ? -1 : body.indexOf("reportUnarchivalStatus(");
        int tap = body == null ? -1 : body.indexOf("\"unarchive tapped: \"");
        check("p2 onReceive calls UnarchiveGate.accept before startForegroundService, reportUnarchivalStatus and the tapped log",
                g >= 0 && fgs > g && rep > g && tap > g, "accept=" + g + " fgs=" + fgs + " report=" + rep + " tapped=" + tap);

        // p3: the refused branch logs one fixed line and does nothing else.
        int ifAt = body == null ? -1 : body.indexOf("if (!UnarchiveGate.accept(");
        String br = ifAt < 0 ? null : block(body, ifAt);
        boolean ok = false;
        if (br != null) {
            String inner = br.substring(1, br.length() - 1).trim();
            String[] stmts = inner.split(";");
            int logAt = inner.indexOf(REFUSED_LOG);
            boolean fixedLog = logAt >= 0 && inner.indexOf('+', 0) < 0;
            boolean none = true;
            for (String bad : new String[] {"startForegroundService", "reportUnarchivalStatus", "getPackageInstaller",
                    "UnarchiveService"}) {
                if (inner.contains(bad)) none = false;
            }
            ok = fixedLog && none && inner.endsWith("return;") && stmts.length == 2;
        }
        check("p3 the refused branch logs one fixed line and does nothing else", ok, "branch=" + br);
    }

    public static void main(String[] args) throws Exception {
        String a = SYS;
        check("system action with com.example.app is accepted", acc(a, "com.example.app"), "refused");
        check("a.b_c.d2 is accepted", acc(a, "a.b_c.d2"), "refused");
        check("255-char name is accepted", acc(a, chars(255)), "refused");
        check("null action is refused", !acc(null, "com.example.app"), "accepted");
        check("empty action is refused", !acc("", "com.example.app"), "accepted");
        check("MAIN action is refused", !acc("android.intent.action.MAIN", "com.example.app"), "accepted");
        check("action with trailing space is refused", !acc(a + " ", "com.example.app"), "accepted");
        check("null pkg is refused", !acc(a, null), "accepted");
        check("empty pkg is refused", !acc(a, ""), "accepted");
        check("a is refused", !acc(a, "a"), "accepted");
        check("1a.b is refused", !acc(a, "1a.b"), "accepted");
        check("a..b is refused", !acc(a, "a..b"), "accepted");
        check(".a.b is refused", !acc(a, ".a.b"), "accepted");
        check("a.b. is refused", !acc(a, "a.b."), "accepted");
        check("a.b/../c is refused", !acc(a, "a.b/../c"), "accepted");
        check("a.b c is refused", !acc(a, "a.b c"), "accepted");
        check("256-char name is refused", !acc(a, chars(256)), "accepted");
        pins(args.length > 0 ? args[0] : ".");
        if (fails == 0) System.out.println("PASS " + runs + " cases");
        System.exit(fails == 0 ? 0 : 1);
    }
}
