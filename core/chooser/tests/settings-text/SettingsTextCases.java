package com.nowhere.chooser;

/** Cases for SettingsText (NWP-20261111-17) and source checks on the real ProfileActivity.java.
 *  args: <ProfileActivity.java> <temp root>. Exit 0 every case passed, 1 any case failed. */
public final class SettingsTextCases {
    private static int bad = 0;

    private static void check(String name, Object got, Object want) {
        if (java.util.Objects.equals(want, got)) { System.out.println("PASS " + name); return; }
        System.out.println("FAIL " + name + ": got <" + show(got) + "> want <" + show(want) + ">");
        bad++;
    }
    private static void truth(String name, boolean ok, String why) {
        if (ok) { System.out.println("PASS " + name); return; }
        System.out.println("FAIL " + name + ": " + why);
        bad++;
    }
    private static String show(Object o) { return o == null ? "null" : String.valueOf(o).replace("\n", "\\n"); }
    private static String entries(java.util.Map<String,String> m) { return new java.util.ArrayList<>(m.entrySet()).toString(); }

    public static void main(String[] args) throws Exception {
        java.nio.file.Path root = java.nio.file.Files.createTempDirectory(java.nio.file.Paths.get(args[1]), "st");
        try {
            readCases(root);
        } finally {
            java.nio.file.Files.walk(root).sorted(java.util.Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
        }
        parseCases();
        equivalence();
        sourceChecks(new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(args[0])),
                java.nio.charset.StandardCharsets.UTF_8));
        System.exit(bad == 0 ? 0 : 1);
    }

    private static void readCases(java.nio.file.Path root) throws Exception {
        check("R1 an absent file reads as \"\"", SettingsText.read(root.resolve("absent").toFile()), "");
        java.io.File f = root.resolve("cfg").toFile();
        java.nio.file.Files.write(f.toPath(), "a=1\nb=2\n".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        check("R2 a regular file reads as its text", SettingsText.read(f), "a=1\nb=2\n");
        java.io.File g = root.resolve("nonl").toFile();
        java.nio.file.Files.write(g.toPath(), "x".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        check("R2 a last line without a newline gets one", SettingsText.read(g), "x\n");
        // A directory at the path exists and cannot be opened for reading -- EISDIR from the kernel, so this holds
        // as root too, where a chmod 000 file would still read.
        java.io.File d = root.resolve("dir").toFile();
        truth("R3 fixture: a directory exists", d.mkdir() && d.exists(), "mkdir failed");
        check("R3 a path that exists and cannot be read reads as null", SettingsText.read(d), null);
    }

    private static void parseCases() {
        check("P1 parseConfig keeps order, skips #, blank, =x and no-= lines, trims, last wins",
                entries(SettingsText.parseConfig(" a = 1 \n#k=v\n\n=x\nnoeq\nb=2=3\r\na=4\n")), "[a=4, b=2=3]");
        check("P2 parseTiers splits on the first space, skips # and space-less lines, trims",
                entries(SettingsText.parseTiers("com.a prefetch\n#com.c ondemand\nnospace\n com.b  on demand \n\n")),
                "[com.a=prefetch, com.b=on demand]");
        check("P3 parsePins drops blank lines, trims, keeps first order",
                new java.util.ArrayList<>(SettingsText.parsePins("  com.a \n\n\t\ncom.b\ncom.a\n")).toString(), "[com.a, com.b]");
        check("P0 parseConfig on null and \"\" is empty",
                SettingsText.parseConfig(null).size() + SettingsText.parseConfig("").size(), 0);
        check("P0 parseTiers on null and \"\" is empty",
                SettingsText.parseTiers(null).size() + SettingsText.parseTiers("").size(), 0);
        check("P0 parsePins on null and \"\" is empty",
                SettingsText.parsePins(null).size() + SettingsText.parsePins("").size(), 0);
    }

    /** Each parser on a fixed fixture gives what the method it replaced (origin/main's readConfig / readTiers /
     *  readPins) returned on that file. The expected values are written out by hand from those methods' rules. */
    private static void equivalence() {
        // readConfig on this nowhere-config returned {media.default=prefetch, apps.default.napps=auto,
        // apps.default.play=off} in that order: the comment, the blank and "=orphan" were skipped.
        check("E1 parseConfig == readConfig",
                entries(SettingsText.parseConfig("# defaults\nmedia.default=prefetch\n\napps.default.napps = auto\n=orphan\napps.default.play=off\n")),
                "[media.default=prefetch, apps.default.napps=auto, apps.default.play=off]");
        // readTiers on this nowhere-media-tiers returned {com.x.photos=essential, com.y.music=ondemand}: "junk"
        // has no space and was skipped.
        check("E2 parseTiers == readTiers",
                entries(SettingsText.parseTiers("com.x.photos essential\njunk\ncom.y.music ondemand\n")),
                "[com.x.photos=essential, com.y.music=ondemand]");
        // readPins on this nowhere-pins returned [com.x.photos, com.y.music]: the blank line was skipped.
        check("E3 parsePins == readPins",
                new java.util.ArrayList<>(SettingsText.parsePins("com.x.photos\n\ncom.y.music\n")).toString(),
                "[com.x.photos, com.y.music]");
    }

    // ---- source checks ------------------------------------------------------------------------------------------

    /** The source with // and block comments dropped; string and char literals kept whole. */
    static String stripComments(String s) {
        StringBuilder o = new StringBuilder(s.length());
        int n = s.length(), i = 0;
        while (i < n) {
            char c = s.charAt(i);
            if (s.startsWith("//", i)) { while (i < n && s.charAt(i) != '\n') i++; continue; }
            if (s.startsWith("/*", i)) {
                int e = s.indexOf("*/", i + 2);
                i = e < 0 ? n : e + 2;
                o.append(' ');
                continue;
            }
            if (s.startsWith("\"\"\"", i)) {
                int e = s.indexOf("\"\"\"", i + 3);
                int end = e < 0 ? n : e + 3;
                o.append(s, i, end); i = end; continue;
            }
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && s.charAt(j) != c && s.charAt(j) != '\n') { if (s.charAt(j) == '\\') j++; j++; }
                int end = Math.min(n, j + 1);
                o.append(s, i, end); i = end; continue;
            }
            o.append(c); i++;
        }
        return o.toString();
    }

    /** The method from its exact signature to the brace that closes it, braces in literals ignored; null if absent. */
    static String method(String code, String sig) {
        int at = code.indexOf(sig);
        if (at < 0 || code.indexOf(sig, at + 1) >= 0) return null;
        int open = code.indexOf('{', at);
        if (open < 0) return null;
        int depth = 0, n = code.length();
        for (int i = open; i < n; i++) {
            char c = code.charAt(i);
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && code.charAt(j) != c) { if (code.charAt(j) == '\\') j++; j++; }
                i = j; continue;
            }
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return code.substring(at, i + 1);
        }
        return null;
    }

    private static final java.util.regex.Pattern NULL_BRANCH = java.util.regex.Pattern.compile(
            "if\\s*\\(\\s*text\\s*==\\s*null\\s*\\)\\s*\\{[^{}]*\\breturn\\s*(?:false\\s*)?;");

    private static void writer(String code, String label, String sig, String file, String view) {
        String b = method(code, sig);
        if (b == null) { truth(label + ": found by its signature", false, "signature absent, duplicated or unbalanced"); return; }
        int iRead = b.indexOf("SettingsText.read(");
        java.util.regex.Matcher m = NULL_BRANCH.matcher(b);
        int iNull = m.find() ? m.start() : -1;
        int iWrite = b.indexOf("StoreInstaller.writeAtomic(");
        truth(label + ": reads through SettingsText.read(", iRead >= 0, "no SettingsText.read(");
        truth(label + ": returns on a null read", iNull >= 0, "no `if (text == null) { ... return; }` (or `return false;`)");
        truth(label + ": the null check follows the read", iRead >= 0 && iNull > iRead, "read@" + iRead + " null@" + iNull);
        truth(label + ": returns on null before StoreInstaller.writeAtomic(", iNull >= 0 && iWrite > iNull,
                "null@" + iNull + " writeAtomic@" + iWrite);
        if (b.contains("f.delete()")) {
            truth(label + ": returns on null before f.delete()", iNull >= 0 && b.indexOf("f.delete()") > iNull,
                    "null@" + iNull + " delete@" + b.indexOf("f.delete()"));
        }
        truth(label + ": does not read through the swallowing " + view, !b.contains(view), "calls " + view);
        String logRe = "Log\\.w\\(\"NowhereChooser\",\\s*\"" + java.util.regex.Pattern.quote(file)
                + " unreadable -- nothing written \\(NWP-20261111-17\\)\"\\)";
        truth(label + ": logs the file name only on a refused write",
                java.util.regex.Pattern.compile(logRe).matcher(b).find(), "no fixed `" + file + " unreadable` log line");
    }

    private static void reader(String code, String label, String sig, String parser) {
        String b = method(code, sig);
        if (b == null) { truth(label + ": found by its signature", false, "signature absent, duplicated or unbalanced"); return; }
        truth(label + ": reads through SettingsText.read(", b.contains("SettingsText.read("), "no SettingsText.read(");
        truth(label + ": parses through " + parser, b.contains(parser), "no " + parser);
    }

    private static final java.util.regex.Pattern CUR_NULL_BRANCH = java.util.regex.Pattern.compile(
            "if\\s*\\(\\s*cur\\s*==\\s*null\\s*\\)\\s*\\{[^{}]*\\breturn\\s+false\\s*;");

    /** NWP-20261129-15: a nowhere-prefs writer. It reads PREFS_FILE strictly into cur, returns false on null, and only
     *  then composes from cur and writes. */
    private static void prefsWriter(String code, String label, String sig, String compose) {
        String b = method(code, sig);
        if (b == null) { truth(label + ": found by its signature", false, "signature absent, duplicated or unbalanced"); return; }
        int iRead = b.indexOf("SettingsText.read(new java.io.File(getFilesDir(), PREFS_FILE))");
        java.util.regex.Matcher m = CUR_NULL_BRANCH.matcher(b);
        int iNull = m.find() ? m.start() : -1;
        int iCompose = b.indexOf(compose);
        int iWrite = b.indexOf("StoreInstaller.writeAtomic(");
        truth(label + ": reads PREFS_FILE through SettingsText.read(", iRead >= 0, "no strict read of PREFS_FILE");
        truth(label + ": returns false on a null read", iNull >= 0, "no `if (cur == null) { ... return false; }`");
        truth(label + ": the null check follows the read", iRead >= 0 && iNull > iRead, "read@" + iRead + " null@" + iNull);
        truth(label + ": returns on null before " + compose, iNull >= 0 && iCompose > iNull, "null@" + iNull + " compose@" + iCompose);
        truth(label + ": returns on null before StoreInstaller.writeAtomic(", iNull >= 0 && iWrite > iNull,
                "null@" + iNull + " writeAtomic@" + iWrite);
        truth(label + ": does not read through the swallowing readPrefsText()", !b.contains("readPrefsText()"), "calls readPrefsText()");
        truth(label + ": logs the fixed line on a refused write",
                java.util.regex.Pattern.compile("Log\\.w\\(\"NowhereChooser\",\\s*\"nowhere-prefs unreadable -- nothing written \\(NWP-20261129-15\\)\"\\)")
                        .matcher(b).find(), "no fixed `nowhere-prefs unreadable` log line");
    }

    private static void sourceChecks(String src) {
        String code = stripComments(src);
        // NWP-20261124-09: cfgPut's body moved into cfgPutStatic (PlayAtCreateReceiver shares it); cfgPut only delegates
        writer(code, "S1 cfgPutStatic", "static void cfgPutStatic(android.content.Context ctx, String key, String val) {",
                "nowhere-config", "readConfig()");
        String put = java.util.Objects.toString(method(code, "private void cfgPut(String key, String val) {"), "");
        truth("S1 cfgPut only delegates to cfgPutStatic(this, key, val)",
                put.replaceAll("\\s+", "").equals("privatevoidcfgPut(Stringkey,Stringval){cfgPutStatic(this,key,val);}"),
                "cfgPut: " + put);
        writer(code, "S2 setTierOverride", "private boolean setTierOverride(String app, String tier) {",
                "nowhere-media-tiers", "readTiers()");
        writer(code, "S3 setPinned", "private boolean setPinned(String app, boolean on) {", "nowhere-pins", "readPins()");
        truth("S2 setTierOverride still deletes an emptied file",
                java.util.Objects.toString(method(code, "private boolean setTierOverride(String app, String tier) {"), "")
                        .contains("f.delete()"), "no f.delete() -- the order check above would be vacuous");
        reader(code, "S4 readConfig", "private java.util.Map<String,String> readConfig() {", "SettingsText.parseConfig(");
        reader(code, "S5 readTiers", "private java.util.Map<String,String> readTiers() {", "SettingsText.parseTiers(");
        reader(code, "S6 readPins", "private java.util.Set<String> readPins() {", "SettingsText.parsePins(");
        prefsWriter(code, "S7 setPref", "private boolean setPref(String key, String value) {", "prefsUpdated(cur,");
        prefsWriter(code, "S8 writeWipePref", "private boolean writeWipePref(int i) {", "prefsUpdatedWipe(cur,");
        truth("S7 capturePrefs: logs \"captured prefs\" only when setPref answered true, else the fixed line",
                java.util.regex.Pattern.compile("if\\s*\\(\\s*setPref\\(\"locale\",\\s*loc\\)\\s*\\)\\s*\\{[^{}]*\"captured prefs [^{}]*\\}\\s*else\\s*\\{\\s*"
                        + "android\\.util\\.Log\\.w\\(\"NowhereChooser\",\\s*\"prefs not captured -- nowhere-prefs was not written \\(NWP-20261129-15\\)\"\\);\\s*\\}")
                        .matcher(java.util.Objects.toString(method(code, "private void capturePrefs() {"), "")).find(),
                "capturePrefs does not branch its log on setPref's answer");
    }
}
