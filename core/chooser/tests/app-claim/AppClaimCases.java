import java.io.File;
import java.io.StringReader;
import java.util.*;

/**
 * NWP-20261015-27: AppClaim's claim-record reader, receipt scoping and hold/release diff, executed against the lifted
 * helpers (Lifted). An UNREADABLE record is null and changes nothing; an EMPTY one is the instruction to release.
 * NWP-20261111-16: the receipt is read as strictly (readReceiptFile is null when present but unreadable), and the
 * source checks pin that applyFromFile, the two receipt writers and releaseAll change nothing on that null.
 */
public class AppClaimCases {
    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  ok    " + name); }
        else { fail++; System.out.println("  FAIL  " + name); }
    }

    static Map<String, String> parse(String text) throws Exception {
        return Lifted.parseClaims(new StringReader(text));
    }

    static Map<String, String> map(String... kv) {
        Map<String, String> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    static List<String> l(String... s) { return new ArrayList<>(Arrays.asList(s)); }

    // Not removed here: run.sh points java.io.tmpdir into the directory its EXIT trap removes.
    static File tmpDir() throws Exception {
        return java.nio.file.Files.createTempDirectory("appclaim").toFile();
    }

    static String src(String path) throws Exception {
        return new String(java.nio.file.Files.readAllBytes(new File(path).toPath()), "UTF-8");
    }

    /** {@code s} with its comments removed; string and char literals are copied verbatim. */
    static String stripComments(String s) {
        StringBuilder out = new StringBuilder();
        int i = 0, n = s.length();
        while (i < n) {
            char c = s.charAt(i);
            if (c == '/' && i + 1 < n && s.charAt(i + 1) == '/') {
                while (i < n && s.charAt(i) != '\n') i++;
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                int e = s.indexOf("*/", i + 2);
                i = e < 0 ? n : e + 2;
                out.append(' ');
            } else if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && s.charAt(j) != c) j += s.charAt(j) == '\\' ? 2 : 1;
                j = Math.min(j + 1, n);
                out.append(s, i, j);
                i = j;
            } else {
                out.append(c);
                i++;
            }
        }
        return out.toString();
    }

    /** The braced body of the first declaration starting {@code decl} in comment-free {@code s}; "" when absent. */
    static String body(String s, String decl) {
        int at = s.indexOf(decl);
        if (at < 0) return "";
        int open = s.indexOf('{', at);
        if (open < 0) return "";
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < s.length() && s.charAt(j) != c) j += s.charAt(j) == '\\' ? 2 : 1;
                i = j;
            } else if (c == '{') {
                depth++;
            } else if (c == '}' && --depth == 0) {
                return s.substring(open, i + 1);
            }
        }
        return "";
    }

    public static void main(String[] a) throws Exception {
        System.out.println("== parseClaims: the line rules ==");
        check("a comment, a blank line and a no-tab line are skipped",
                parse("# note\n\nnotab\ncom.a\tunitA\n").equals(map("com.a", "unitA")));
        check("a package containing '/' is skipped",
                parse("com/evil\tunitA\ncom.ok\tunitA\n").equals(map("com.ok", "unitA")));
        check("a line that BEGINS with a tab trims to a no-tab line and is skipped",
                parse("\tunitA\n\tcom.a\n").isEmpty());
        check("pkg and unit with surrounding spaces are trimmed",
                parse("  com.a  \t  unitA  \n").equals(map("com.a", "unitA")));
        Map<String, String> dup = parse("com.a\tunitA\ncom.a\tunitB\n");
        check("a later duplicate keeps one entry", dup.size() == 1 && dup.containsKey("com.a"));
        check("an empty record parses to an empty map", parse("").isEmpty());

        System.out.println("== the agent's format ==");
        // The exact bytes core/agent/app_claim_test.go TestWriteClaimsOut_NamesTheHolderAndIsDeterministic makes
        // writeClaimsOut write (unitB = "bbbb2222"): the header comment, then the sorted held packages.
        String agent = "# pkg\tunit -- written by the seal; empty means nothing is held elsewhere\n"
                + "com.aaa\tbbbb2222\ncom.zzz\tbbbb2222\n";
        Map<String, String> got = parse(agent);
        check("the agent's record parses to its expected map, in order",
                got.equals(map("com.aaa", "bbbb2222", "com.zzz", "bbbb2222"))
                        && new ArrayList<>(got.keySet()).equals(l("com.aaa", "com.zzz")));
        check("the agent's header-only (empty) record parses to an empty map",
                parse("# pkg\tunit -- written by the seal; empty means nothing is held elsewhere\n").isEmpty());

        System.out.println("== readClaimsFile / readClaims / claimedElsewhere ==");
        File dir = tmpDir();
        File f = new File(dir, "nowhere-claims");
        check("an ABSENT record is an empty map, not null", Lifted.readClaimsFile(f) != null && Lifted.readClaimsFile(f).isEmpty());
        try (java.io.FileWriter w = new java.io.FileWriter(f)) { w.write(agent); }
        check("a readable record is read", Lifted.readClaimsFile(f).size() == 2);
        File asDir = new File(dir, "isdir");
        asDir.mkdir();
        check("a DIRECTORY where the record should be is null (unreadable), not empty", Lifted.readClaimsFile(asDir) == null);
        File locked = new File(dir, "locked");
        try (java.io.FileWriter w = new java.io.FileWriter(locked)) { w.write("com.a\tu\n"); }
        locked.setReadable(false, false);
        if (locked.canRead()) {
            System.out.println("  note  chmod 000 case SKIPPED: this process can read an unreadable file (running as root); "
                    + "the directory case above covers null-for-unreadable");
        } else {
            check("a chmod 000 record is null (unreadable), not empty", Lifted.readClaimsFile(locked) == null);
        }
        Lifted.Context ctx = new Lifted.Context();
        ctx.dir = dir;
        check("readClaims reads the record from the files dir", Lifted.readClaims(ctx).equals(map("com.aaa", "bbbb2222", "com.zzz", "bbbb2222")));
        check("claimedElsewhere names the claimed packages",
                Lifted.claimedElsewhere(ctx).equals(new LinkedHashSet<>(l("com.aaa", "com.zzz"))));
        f.delete();
        check("claimedElsewhere of an absent record is empty", Lifted.claimedElsewhere(ctx).isEmpty());
        File ud = tmpDir();
        new File(ud, "nowhere-claims").mkdir();
        Lifted.Context bad = new Lifted.Context();
        bad.dir = ud;
        check("readClaims of an unreadable record is null", Lifted.readClaims(bad) == null);
        check("claimedElsewhere of an unreadable record is EMPTY (a drop set: exclude nothing)",
                Lifted.claimedElsewhere(bad).isEmpty());

        System.out.println("== parseReceipt: scoped by user ==");
        check("a receipt stamped for user 11 reads as empty for user 12",
                Lifted.parseReceipt("#user 11\ncom.a\ncom.b\n", 12).isEmpty());
        check("the matching user's packages are read",
                Lifted.parseReceipt("#user 12\ncom.a\ncom.b\n", 12).equals(l("com.a", "com.b")));
        check("two blocks keep only the matching one",
                Lifted.parseReceipt("#user 11\ncom.a\n#user 12\ncom.b\n", 12).equals(l("com.b"))
                        && Lifted.parseReceipt("#user 11\ncom.a\n#user 12\ncom.b\n", 11).equals(l("com.a")));
        check("user 1 does not match a '#user 11' stamp", Lifted.parseReceipt("#user 11\ncom.a\n", 1).isEmpty());
        check("an empty receipt is empty", Lifted.parseReceipt("", 12).isEmpty());

        System.out.println("== diff: hold / release ==");
        List<List<String>> d = Lifted.diff(map("a", "u", "b", "u"), l("b", "c"));
        check("want {a,b}, have {b,c}: hold [a], release [c]", d.get(0).equals(l("a")) && d.get(1).equals(l("c")));
        d = Lifted.diff(map(), l("b", "c"));
        check("an EMPTY record releases everything held and holds nothing", d.get(0).isEmpty() && d.get(1).equals(l("b", "c")));
        d = Lifted.diff(map("a", "u"), l("a"));
        check("nothing to do when want == have", d.get(0).isEmpty() && d.get(1).isEmpty());
        d = Lifted.diff(map("a", "u"), l());
        check("nothing held yet: hold everything wanted", d.get(0).equals(l("a")) && d.get(1).isEmpty());

        System.out.println("== applyFromFile: an unreadable record changes nothing ==");
        Map<String, String> unreadable = Lifted.readClaims(bad);
        check("the unreadable record is null, so there is no diff to compute", unreadable == null);
        String s = src(a[0]);
        int ap = s.indexOf("Result applyFromFile(");
        int guard = s.indexOf("if (want == null) {", ap);
        int diffCall = s.indexOf("diff(want, have)", ap);
        check("applyFromFile returns on a null record BEFORE it diffs against the receipt",
                ap > 0 && guard > ap && diffCall > guard);

        System.out.println("== readReceiptFile: an unreadable receipt is null, not empty (NWP-20261111-16) ==");
        File absent = new File(tmpDir(), "nowhere-appclaim");
        List<String> c1 = Lifted.readReceiptFile(absent, 11);
        check("C1 an ABSENT receipt is empty, not null", c1 != null && c1.isEmpty());
        File rf = new File(tmpDir(), "nowhere-appclaim");
        try (java.io.FileWriter w = new java.io.FileWriter(rf)) { w.write("#user 11\ncom.a\ncom.b\n"); }
        List<String> as12 = Lifted.readReceiptFile(rf, 12);
        check("C2 a receipt for user 11 read as user 11 gives its packages, read as user 12 gives empty",
                l("com.a", "com.b").equals(Lifted.readReceiptFile(rf, 11)) && as12 != null && as12.isEmpty());
        File rd = new File(tmpDir(), "nowhere-appclaim");
        rd.mkdir();
        // A directory cannot be opened as a file even by root, so unlike chmod 000 this case never skips.
        check("C3 a receipt path that exists but cannot be opened (a directory) is null, not empty",
                Lifted.readReceiptFile(rd, 11) == null);
        // C4 pins shipped behaviour: a read error after a good line PROPAGATES out of the parser, so readReceiptFile's
        // catch turns it into null. A parser that swallowed it would hand back a partial list as the whole receipt.
        java.io.Reader torn = new java.io.Reader() {
            boolean done;
            @Override public int read(char[] b, int off, int len) throws java.io.IOException {
                if (done) throw new java.io.IOException("injected");
                String t = "#user 11\ncom.a\n";
                t.getChars(0, t.length(), b, off);
                done = true;
                return t.length();
            }
            @Override public void close() {}
        };
        boolean threw = false;
        try { Lifted.parseReceipt(torn, 11); } catch (java.io.IOException e) { threw = true; }
        check("C4 parseReceipt(Reader) propagates a read error after one good line", threw);

        System.out.println("== the receipt's callers change nothing on an unreadable read (NWP-20261111-16) ==");
        String code = stripComments(s);
        String af = body(code, "Result applyFromFile(");
        int g = af.indexOf("if (have == null) {");
        int r = g < 0 ? -1 : af.indexOf("return new Result(ERROR", g);
        check("S1 applyFromFile returns ERROR on a null receipt before diff(",
                g >= 0 && r > g && af.indexOf("diff(") > r && af.indexOf("readReceipt(ctx, userId)") >= 0
                        && af.indexOf("readReceipt(ctx, userId)") < g);
        String[][] writers = {
                {"S2 writeReceipt(Context, int, List)",
                        "static void writeReceipt(Context ctx, int userId, java.util.List<String> add)"},
                {"S3 clearReceipt", "static void clearReceipt("}};
        for (String[] w : writers) {
            String b = body(code, w[1]);
            int wg = b.indexOf("if (held == null) {");
            int wr = wg < 0 ? -1 : b.indexOf("return;", wg);
            check(w[0] + " returns on a null read before writeReceipt(ctx, userId, all,",
                    wg >= 0 && wr > wg && b.indexOf("writeReceipt(ctx, userId, all,") > wr);
        }
        String ra = body(code, "static Result releaseAll(");
        int rg = ra.indexOf("if (held == null) {");
        int rr = rg < 0 ? -1 : ra.indexOf("return new Result(ERROR", rg);
        check("S4 releaseAll returns ERROR on a null read, never the 'nothing held' APPLIED",
                rg >= 0 && rr > rg && ra.indexOf("APPLIED") > rr);

        System.out.println("== the holder's name: the third column (NWP-20261125-06, h54 #1) ==");
        String three = "# pkg\tunit -- written by the seal; empty means nothing is held elsewhere\n"
                + "com.a\t  U1  \tPixel 8\ncom.b\tU2\ncom.c\tU3\t\ncom.d\tU4\tbad\u0007name\n";
        check("N1 a 3-column line gives the unit (second column only, trimmed)",
                parse(three).equals(map("com.a", "U1", "com.b", "U2", "com.c", "U3", "com.d", "U4")));
        Map<String, String> names = Lifted.parseClaimNames(new StringReader(three));
        check("N2 a 3-column line gives its name; a 2-column, empty or control-character third column gives none",
                names.equals(map("com.a", "Pixel 8")));
        check("N3 the agent's 2-column record gives no names",
                Lifted.parseClaimNames(new StringReader(agent)).isEmpty());
        File nd = tmpDir();
        Lifted.Context nctx = new Lifted.Context();
        nctx.dir = nd;
        check("N4 an absent record gives no names, never an error", Lifted.readClaimNames(nctx).isEmpty());
        java.nio.file.Files.write(new File(nd, Lifted.CLAIMS).toPath(), three.getBytes("UTF-8"));
        check("N5 readClaimNames reads the record's names", Lifted.readClaimNames(nctx).equals(map("com.a", "Pixel 8")));
        Map<String, List<String>> groups = Lifted.holdGroups(l("a", "b", "c", "d"),
                map("a", "Pixel 8", "b", "Pixel 9", "c", "Pixel 8"), "your other device");
        check("N6 two names give two groups, then the fallback, in first-seen order",
                new ArrayList<>(groups.keySet()).equals(l("Pixel 8", "Pixel 9", "your other device"))
                        && groups.get("Pixel 8").equals(l("a", "c")) && groups.get("Pixel 9").equals(l("b"))
                        && groups.get("your other device").equals(l("d")));
        check("N7 no names give one fallback group",
                Lifted.holdGroups(l("a", "b"), null, "your other device")
                        .equals(Collections.singletonMap("your other device", l("a", "b"))));
        String ap2 = body(code, "Result applyFromFile(");
        check("N8 applyFromFile holds once per group, with HeldElsewhereCopy.WHERE as the fallback",
                ap2.contains("holdGroups(toHold, names, HeldElsewhereCopy.WHERE)")
                        && ap2.contains("hold(ctx, userId, g.getValue(), g.getKey())")
                        && !ap2.contains("\"your other device\""));
        check("N9 the held dialog's title names where it is held",
                body(code, "static Result hold(").contains(".setTitle(\"Held by \" + where)"));

        System.out.println();
        System.out.println("passed " + pass + ", failed " + fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
