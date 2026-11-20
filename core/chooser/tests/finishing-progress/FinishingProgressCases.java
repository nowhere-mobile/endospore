package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261208-25: FinishingProgress (pct, status, line), plus the wiring pins in ChooserActivity: the finish block's
 *  95 and 100 paints, installRoamedAppCode's count, line and final post, the GONE resets, and appLabelOf's no-log rule. */
public class FinishingProgressCases {
    static int fails = 0;

    static void eq(String what, String want, String got) {
        if (!want.equals(got)) { fails++; System.out.println("FAIL " + what + ": want [" + want + "] got [" + got + "]"); }
    }

    static void ok(String what, boolean c) {
        if (!c) { fails++; System.out.println("FAIL " + what); }
    }

    /** Drop // and block comments outside string and char literals; keep every newline. */
    static String strip(String s) {
        StringBuilder b = new StringBuilder(s.length());
        int i = 0, n = s.length();
        while (i < n) {
            char c = s.charAt(i);
            if (c == '"' || c == '\'') {
                char q = c;
                b.append(c); i++;
                while (i < n) {
                    char d = s.charAt(i);
                    b.append(d); i++;
                    if (d == '\\' && i < n) { b.append(s.charAt(i)); i++; continue; }
                    if (d == q || d == '\n') break;
                }
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '/') {
                while (i < n && s.charAt(i) != '\n') i++;
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                i += 2;
                while (i + 1 < n && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/')) {
                    if (s.charAt(i) == '\n') b.append('\n');
                    i++;
                }
                i += 2;
            } else {
                b.append(c); i++;
            }
        }
        return b.toString();
    }

    /** The method that starts at `sig`, up to its closing brace at four-space indent; "" when it is not found. */
    static String method(String src, String sig) {
        int s = src.indexOf(sig);
        if (s < 0) return "";
        int e = src.indexOf("\n    }\n", s);
        return e > s ? src.substring(s, e) : "";
    }

    static int count(String hay, String needle) {
        int k = 0;
        for (int i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length())) k++;
        return k;
    }

    public static void main(String[] a) throws Exception {
        // C1: 95 at the start, 99 at the end, non-decreasing, never 100 (the switch paints 100).
        for (int n : new int[] {1, 2, 5, 12, 100}) {
            ok("C1 pct(0," + n + ") == 95", FinishingProgress.pct(0, n) == 95);
            ok("C1 pct(" + n + "," + n + ") == 99", FinishingProgress.pct(n, n) == 99);
            int prev = 95;
            for (int d = 0; d <= n; d++) {
                int p = FinishingProgress.pct(d, n);
                ok("C1 pct(" + d + "," + n + ") in 95..99", p >= 95 && p <= 99);
                ok("C1 pct(" + d + "," + n + ") non-decreasing", p >= prev);
                prev = p;
            }
        }
        ok("C1 pct(3,0) == 95", FinishingProgress.pct(3, 0) == 95);
        ok("C1 pct(0,0) == 95", FinishingProgress.pct(0, 0) == 95);
        ok("C1 pct(-1,5) == 95", FinishingProgress.pct(-1, 5) == 95);
        ok("C1 pct(9,5) == 99", FinishingProgress.pct(9, 5) == 99);

        // C2: the approved status line, byte for byte (U+2026 ellipsis, U+2014 em dash).
        eq("C2 status(95)", "Finishing up… — 95%", FinishingProgress.status(95));
        eq("C2 status(100)", "Finishing up… — 100%", FinishingProgress.status(100));

        // C3: the approved line.
        eq("C3 line(Maps,3,12)", "Installing Maps (3 of 12)", FinishingProgress.line("Maps", 3, 12));
        eq("C3 line(org.example.app,1,1)", "Installing org.example.app (1 of 1)",
                FinishingProgress.line("org.example.app", 1, 1));

        String src = strip(new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8));
        final String GONE = "installLine.setVisibility(View.GONE)";

        // P1: the 95 paint shows the status line with its number; the old bare words are gone from the finish block.
        int p95 = src.indexOf("progressBar.setProgress(95)");
        ok("P1 progressBar.setProgress(95) occurs once", p95 >= 0 && count(src, "progressBar.setProgress(95)") == 1);
        int prov = p95 >= 0 ? src.indexOf("provisionRoamedApps(uid);", p95) : -1;
        String s95 = p95 >= 0 && prov > p95 ? src.substring(p95, prov) : "";
        ok("P1 the 95 paint sets FinishingProgress.status(95)", s95.contains("result.setText(FinishingProgress.status(95))"));
        ok("P1 no result.setText(\"Finishing up…\") between the 95 paint and provisionRoamedApps(uid)",
                !s95.isEmpty() && !s95.contains("result.setText(\"Finishing up…\")"));

        // P2: the 100 paint shows the status line at 100 and hides the install line.
        String a100 = "runOnUiThread(() -> progressBar.setProgress(100));";
        int p100 = src.indexOf(a100);
        ok("P2 the 100 paint occurs once", p100 >= 0 && count(src, a100) == 1);
        int mc = p100 >= 0 ? src.indexOf("mirrorCreate(\"Finishing up…\", 100);", p100) : -1;
        String s100 = p100 >= 0 && mc > p100 ? src.substring(p100, mc) : "";
        ok("P2 the 100 paint sets FinishingProgress.status(100)", s100.contains("result.setText(FinishingProgress.status(100))"));
        ok("P2 the 100 paint sets installLine GONE", s100.contains(GONE));

        // P3: installRoamedAppCode counts n in a pre-pass, posts one line per install before installApkSet, and
        // posts pct(n, n) with the line GONE in its finally.
        String ir = method(src, "private java.util.Set<String> installRoamedAppCode(int uid) {");
        ok("P3 installRoamedAppCode found", !ir.isEmpty());
        int w = ir.indexOf("while ((line = br.readLine()) != null) {");
        ok("P3 the main loop header found", w >= 0);
        int ln = ir.indexOf("FinishingProgress.line(");
        int ia = ir.indexOf("installApkSet(pkg, apks, uid)");
        ok("P3(a) FinishingProgress.line( occurs exactly once", count(ir, "FinishingProgress.line(") == 1);
        ok("P3(a) installApkSet(pkg, apks, uid) occurs exactly once", count(ir, "installApkSet(pkg, apks, uid)") == 1);
        ok("P3(a) FinishingProgress.line( is in the loop, before installApkSet", w >= 0 && ln > w && ia > ln);
        String pre = w > 0 ? ir.substring(0, w) : "";
        ok("P3(b) the pre-pass parses rows with AppCodeManifest.parseRow(", pre.contains("AppCodeManifest.parseRow("));
        ok("P3(b) the pre-pass skips r.deferred rows", pre.contains("r.deferred) continue;"));
        ok("P3(b) the pre-pass counts only APKs on disk", pre.contains(".isFile()"));
        int fin = ir.lastIndexOf("finally {");
        int rm = fin >= 0 ? ir.indexOf("rmTree(dir);", fin) : -1;
        String sfin = fin >= 0 && rm > fin ? ir.substring(fin, rm) : "";
        ok("P3(c) the finally posts FinishingProgress.pct(n, n) before rmTree", sfin.contains("FinishingProgress.pct(n, n)"));
        ok("P3(c) the finally sets installLine GONE before rmTree", sfin.contains(GONE));

        // P4: a new or a failed sign-in never shows a stale install line.
        ok("P4 showRestoring sets installLine GONE",
                method(src, "private void showRestoring(final String name) {").contains(GONE));
        ok("P4 hideRestore sets installLine GONE", method(src, "private void hideRestore() {").contains(GONE));

        // P5: the label is on screen only, never logged.
        String al = method(src, "private String appLabelOf(java.io.File apk, String pkg) {");
        ok("P5 appLabelOf found", !al.isEmpty());
        ok("P5 appLabelOf has no Log.", !al.isEmpty() && !al.contains("Log."));
        ok("P5 appLabelOf( occurs once in installRoamedAppCode, inside FinishingProgress.line(",
                count(ir, "appLabelOf(") == 1 && count(ir, "FinishingProgress.line(appLabelOf(") == 1);
        Matcher m = Pattern.compile("String\\s+(\\w+)\\s*=\\s*FinishingProgress\\.line\\(").matcher(ir);
        ok("P5 the line is assigned to a variable", m.find());
        if (m.find(0)) {
            Pattern v = Pattern.compile("\\b" + Pattern.quote(m.group(1)) + "\\b");
            for (String st : ir.split(";")) {
                if (st.contains("Log.") && v.matcher(st).find())
                    ok("P5 no Log call takes the label (" + m.group(1) + "): " + st.trim(), false);
            }
        }
        if (fails > 0) { System.out.println(fails + " failure(s)"); System.exit(1); }
        System.out.println("finishing-progress: all cases passed");
    }
}
