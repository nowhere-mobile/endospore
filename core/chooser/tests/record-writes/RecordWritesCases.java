import android.content.Context;
import java.io.File;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;

/** NWP-20261022-04: setPlayDep and notePlaySeen (lifted verbatim by run.sh) must leave nowhere-playdeps and
 *  nowhere-playseen byte for byte, log the failure, and leave no .tmp of their own when the write cannot happen. The
 *  write is made to fail by occupying "<name>.tmp" with a non-empty directory: the temp cannot be opened, as root
 *  too. Each case has its own files dir under the root in args[0].
 *  NWP-20261111-06 (cases S1-S4): a record that EXISTS but cannot be opened (a non-empty directory in its place) is
 *  unknown, not empty -- the strict readers return null, and setPlayDep / notePlaySeen write nothing over it.
 *  NWP-20261112-03 (cases K1-K2): the same for the keep-set, nowhere-appkeep -- readAppModesStrictIn and
 *  readAppGroupsStrict answer null for an unopenable file or one whose read fails mid-file (never the lines read before
 *  the failure), empty for an absent one, and parseAppModes / parseAppGroups let the IOException escape. */
public class RecordWritesCases {
    static final Map<String, Long> VERSIONS = new HashMap<>();
    static int failed = 0;
    static int n = 0;

    /** The harness's versionCodeOf: the lifted notePlaySeen calls it through ProfileActivity's stub. */
    static long versionCodeOf(String pkg) { Long v = VERSIONS.get(pkg); return v == null ? -1L : v; }

    static String read(File f) throws IOException {
        return new String(Files.readAllBytes(f.toPath()), Charset.defaultCharset());
    }
    static void put(File f, String s) throws IOException { Files.write(f.toPath(), s.getBytes(Charset.defaultCharset())); }
    static void ok(String what) { System.out.println("  ok    " + what); }
    static void no(String what) { failed++; System.out.println("  FAIL  " + what); }
    static void check(boolean c, String what) { if (c) ok(what); else no(what); }

    static File caseDir(File root) throws IOException {
        File d = new File(root, "c" + (++n));
        if (!d.mkdir()) throw new IOException("mkdir " + d);
        android.util.Log.LINES.clear();
        return d;
    }
    /** Occupy "<name>.tmp" with a non-empty directory, so writeAtomic cannot open its temp. */
    static void blockTmp(File dir, String name) throws IOException {
        File t = new File(dir, name + ".tmp");
        if (!t.mkdir() || !new File(t, "keep").createNewFile()) throw new IOException("block " + t);
    }
    /** Put a non-empty directory where the record "<name>" belongs: it exists and cannot be opened, as root too. */
    static File dirRecord(File dir, String name) throws IOException {
        File t = new File(dir, name);
        if (!t.mkdir() || !new File(t, "keep").createNewFile()) throw new IOException("dirRecord " + t);
        return t;
    }
    /** A reader that serves one keep-set line and then fails: the read that fails mid-file (K2). run.sh's seam
     *  copies of readAppModesStrictIn / readAppGroupsStrict read through this instead of a FileReader. */
    static java.io.Reader failingReader() {
        return new java.io.Reader() {
            private boolean served = false;
            @Override public int read(char[] buf, int off, int len) throws IOException {
                if (served) throw new IOException("EIO (test)");
                String first = "a\tauto\tgroup:x\n";
                first.getChars(0, first.length(), buf, off); // BufferedReader asks for 8192, so it fits
                served = true;
                return first.length();
            }
            @Override public void close() {}
        };
    }
    static boolean logged(String what) {
        for (String l : android.util.Log.LINES) if (l.contains(what)) return true;
        return false;
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);

        System.out.println("== 1. setPlayDep add then remove round-trips the file and leaves no .tmp");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            ProfileActivity.setPlayDep(ctx, "com.a", true);
            ProfileActivity.setPlayDep(ctx, "com.b", true);
            check(read(new File(d, "nowhere-playdeps")).equals("com.a\ncom.b\n"), "add writes one package per line");
            check(ProfileActivity.readPlayDeps(ctx).size() == 2, "readPlayDeps reads both back");
            ProfileActivity.setPlayDep(ctx, "com.a", false);
            check(read(new File(d, "nowhere-playdeps")).equals("com.b\n"), "remove rewrites the file without it");
            check(!new File(d, "nowhere-playdeps.tmp").exists(), "no .tmp is left behind");
            check(android.util.Log.LINES.isEmpty(), "nothing is logged on success");
        }

        System.out.println("== 2. a failed setPlayDep write leaves nowhere-playdeps byte for byte");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            String before = "com.keep1\ncom.keep2\n";
            put(new File(d, "nowhere-playdeps"), before);
            blockTmp(d, "nowhere-playdeps");
            ProfileActivity.setPlayDep(ctx, "com.new", true);
            check(read(new File(d, "nowhere-playdeps")).equals(before), "add: the file is exactly as it was");
            check(logged("setPlayDep"), "add: the failure is logged as setPlayDep");
            android.util.Log.LINES.clear();
            ProfileActivity.setPlayDep(ctx, "com.keep1", false);
            check(read(new File(d, "nowhere-playdeps")).equals(before), "remove: the file is exactly as it was");
            check(logged("setPlayDep"), "remove: the failure is logged as setPlayDep");
        }

        System.out.println("== 3. a failed notePlaySeen write leaves nowhere-playseen byte for byte");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            VERSIONS.clear(); VERSIONS.put("com.new", 7L); VERSIONS.put("com.old", 3L);
            String before = "com.old\t3\ty\n";
            put(new File(d, "nowhere-playseen"), before);
            blockTmp(d, "nowhere-playseen");
            ProfileActivity.notePlaySeen(ctx, "com.new", true);
            check(read(new File(d, "nowhere-playseen")).equals(before), "the file is exactly as it was");
            check(logged("notePlaySeen"), "the failure is logged as notePlaySeen");
        }

        System.out.println("== 3b. notePlaySeen writes a determination and keys it to the version");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            VERSIONS.clear(); VERSIONS.put("com.new", 7L);
            ProfileActivity.notePlaySeen(ctx, "com.new", true);
            check(read(new File(d, "nowhere-playseen")).equals("com.new\t7\ty\n"), "pkg, versionCode and answer are written");
            check(!new File(d, "nowhere-playseen.tmp").exists(), "no .tmp is left behind");
            ProfileActivity.notePlaySeen(ctx, "com.unreadable", true);
            check(read(new File(d, "nowhere-playseen")).equals("com.new\t7\ty\n"), "an unreadable version records nothing");
        }

        System.out.println("== 4. an unchanged determination does not touch the file");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            VERSIONS.clear(); VERSIONS.put("com.same", 5L);
            File f = new File(d, "nowhere-playseen");
            put(f, "com.same\t5\tn\n");
            blockTmp(d, "nowhere-playseen");
            long mtime = f.lastModified();
            ProfileActivity.notePlaySeen(ctx, "com.same", false);
            check(read(f).equals("com.same\t5\tn\n") && f.lastModified() == mtime, "notePlaySeen: same version, same answer: untouched");
            check(android.util.Log.LINES.isEmpty(), "notePlaySeen: no write was attempted (nothing logged)");
            File g = new File(d, "nowhere-playdeps");
            put(g, "com.dep\n");
            blockTmp(d, "nowhere-playdeps");
            ProfileActivity.setPlayDep(ctx, "com.dep", true);
            ProfileActivity.setPlayDep(ctx, "com.absent", false);
            check(read(g).equals("com.dep\n") && android.util.Log.LINES.isEmpty(), "setPlayDep: add of a present / remove of an absent package writes nothing");
        }

        System.out.println("== S1. an unopenable nowhere-playdeps is never rewritten by setPlayDep (NWP-20261111-06)");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            File rec = dirRecord(d, "nowhere-playdeps");
            for (boolean on : new boolean[] { true, false }) {
                android.util.Log.LINES.clear();
                ProfileActivity.setPlayDep(ctx, "x", on);
                String how = on ? "add" : "remove";
                check(rec.isDirectory() && new File(rec, "keep").isFile(), how + ": nowhere-playdeps is still the directory it was");
                check(!new File(d, "nowhere-playdeps.tmp").exists(), how + ": no nowhere-playdeps.tmp was written");
                check(logged("nowhere-playdeps unreadable -- nothing written"), how + ": the abstention is logged");
                check(!logged("NowhereChooser: setPlayDep"), how + ": no write was attempted");
            }
        }

        System.out.println("== S2. an unopenable nowhere-playseen is never rewritten by notePlaySeen (NWP-20261111-06)");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            VERSIONS.clear(); VERSIONS.put("x", 4L);
            File rec = dirRecord(d, "nowhere-playseen");
            ProfileActivity.notePlaySeen(ctx, "x", true);
            check(rec.isDirectory() && new File(rec, "keep").isFile(), "nowhere-playseen is still the directory it was");
            check(!new File(d, "nowhere-playseen.tmp").exists(), "no nowhere-playseen.tmp was written");
            check(logged("nowhere-playseen unreadable -- nothing written"), "the abstention is logged");
            check(!logged("NowhereChooser: notePlaySeen"), "no write was attempted");
        }

        System.out.println("== S3. an ABSENT record still gets its first line (NWP-20261111-06)");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            ProfileActivity.setPlayDep(ctx, "x", true);
            check(new File(d, "nowhere-playdeps").isFile() && read(new File(d, "nowhere-playdeps")).equals("x\n"),
                    "setPlayDep creates nowhere-playdeps holding x");
            VERSIONS.clear(); VERSIONS.put("x", 4L);
            ProfileActivity.notePlaySeen(ctx, "x", true);
            check(new File(d, "nowhere-playseen").isFile() && read(new File(d, "nowhere-playseen")).equals("x\t4\ty\n"),
                    "notePlaySeen creates nowhere-playseen holding x's determination");
            check(android.util.Log.LINES.isEmpty(), "nothing is logged");
        }

        System.out.println("== S4. the strict readers: null for an unopenable record, empty for an absent one (NWP-20261111-06)");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            check(ProfileActivity.readPlayDepsStrict(ctx) != null && ProfileActivity.readPlayDepsStrict(ctx).isEmpty(),
                    "readPlayDepsStrict: absent is empty");
            check(ProfileActivity.readPlaySeenStrict(ctx) != null && ProfileActivity.readPlaySeenStrict(ctx).isEmpty(),
                    "readPlaySeenStrict: absent is empty");
            dirRecord(d, "nowhere-playdeps");
            dirRecord(d, "nowhere-playseen");
            check(ProfileActivity.readPlayDepsStrict(ctx) == null, "readPlayDepsStrict: unopenable is null");
            check(ProfileActivity.readPlaySeenStrict(ctx) == null, "readPlaySeenStrict: unopenable is null");
            check(ProfileActivity.readPlayDeps(ctx).isEmpty() && ProfileActivity.readPlaySeen(ctx).isEmpty(),
                    "the lenient readers still read unopenable as empty");
            File e = caseDir(root); Context ectx = new Context(e);
            put(new File(e, "nowhere-playdeps"), "a\n\n b \n");
            put(new File(e, "nowhere-playseen"), "a\t3\ty\nmalformed\nb\t2\tn\n");
            check(ProfileActivity.readPlayDepsStrict(ectx).equals(new java.util.LinkedHashSet<>(java.util.List.of("a", "b"))),
                    "readPlayDepsStrict: a regular file parses (blank lines dropped, trimmed)");
            java.util.Map<String, String[]> seen = ProfileActivity.readPlaySeenStrict(ectx);
            check(seen != null && seen.size() == 2 && "y".equals(seen.get("a")[1]) && "2".equals(seen.get("b")[0]),
                    "readPlaySeenStrict: a regular file parses (malformed line skipped)");
        }

        System.out.println("== K1. the strict keep-set readers: null for an unopenable nowhere-appkeep, empty for an absent one (NWP-20261112-03)");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            dirRecord(d, "nowhere-appkeep");
            check(ProfileActivity.readAppModesStrictIn(d) == null, "readAppModesStrictIn: unopenable is null");
            check(ProfileActivity.readAppGroupsStrict(ctx) == null, "readAppGroupsStrict: unopenable is null");
            check(ProfileActivity.readAppModesIn(d).isEmpty() && ProfileActivity.readAppGroups(ctx).isEmpty(),
                    "the lenient readers still read unopenable as empty");
            File a = caseDir(root); Context actx = new Context(a);
            check(ProfileActivity.readAppModesStrictIn(a) != null && ProfileActivity.readAppModesStrictIn(a).isEmpty(),
                    "readAppModesStrictIn: absent is empty");
            check(ProfileActivity.readAppGroupsStrict(actx) != null && ProfileActivity.readAppGroupsStrict(actx).isEmpty(),
                    "readAppGroupsStrict: absent is empty");
            File e = caseDir(root); Context ectx = new Context(e);
            put(new File(e, "nowhere-appkeep"), "a\nb\tondemand\n\nc\tauto\tgroup:x\n");
            java.util.LinkedHashMap<String, String> modes = ProfileActivity.readAppModesStrictIn(e);
            check(modes != null && new java.util.ArrayList<>(modes.entrySet()).toString().equals("[a=installed, b=ondemand, c=auto]"),
                    "readAppModesStrictIn: a readable file parses in order (bare = installed, blank skipped): " + modes);
            Map<String, String> groups = ProfileActivity.readAppGroupsStrict(ectx);
            check(groups != null && groups.equals(Map.of("c", "x")), "readAppGroupsStrict: a readable file parses to {c=x}: " + groups);
            check(ProfileActivity.readAppModesIn(e).equals(modes) && ProfileActivity.readAppGroups(ectx).equals(groups),
                    "the lenient readers return the same maps for a readable file");
        }

        System.out.println("== K2. a keep-set read that fails mid-file is unknown, never the part read (NWP-20261112-03)");
        {
            boolean threw = false;
            try {
                java.util.Map<String, String> part = ProfileActivity.parseAppModes(new java.io.BufferedReader(failingReader()));
                no("parseAppModes returned " + part + " over a read that failed after its first line");
            } catch (IOException x) { threw = true; }
            check(threw, "parseAppModes lets the IOException escape");
            threw = false;
            try {
                java.util.Map<String, String> part = ProfileActivity.parseAppGroups(new java.io.BufferedReader(failingReader()));
                no("parseAppGroups returned " + part + " over a read that failed after its first line");
            } catch (IOException x) { threw = true; }
            check(threw, "parseAppGroups lets the IOException escape");
            File d = caseDir(root); Context ctx = new Context(d);
            put(new File(d, "nowhere-appkeep"), "a\tauto\tgroup:x\nb\n"); // exists, so the strict readers open it
            java.util.Map<String, String> m = ProfileActivity.readAppModesStrictInSeam(d);
            check(m == null, "readAppModesStrictIn over a failing read is null, not the one-line partial map: " + m);
            java.util.Map<String, String> g = ProfileActivity.readAppGroupsStrictSeam(ctx);
            check(g == null, "readAppGroupsStrict over a failing read is null, not the one-line partial map: " + g);
        }

        System.out.println(failed == 0 ? "== all cases pass" : "== " + failed + " case(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
