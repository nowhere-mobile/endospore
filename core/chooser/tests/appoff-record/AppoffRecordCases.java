import android.content.Context;
import java.io.File;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;

/** NWP-20261025-06: recordTurnedOff and clearTurnedOff (lifted verbatim by run.sh) read nowhere-appoff.list RAW and
 *  strictly, so a rewrite keeps the Play-stack lines roamd's appcode_stage_play_dormant reads, a re-keep retires the
 *  vending line, and an unreadable file is never rewritten. Each case has its own files dir under the root in args[0]. */
public class AppoffRecordCases {
    static final String A = "com.example.alpha", B = "com.example.beta";
    static final String VEN = "com.android.vending", GMS = "com.google.android.gms";
    static final String OFF = "nowhere-appoff.list";
    static int failed = 0;
    static int n = 0;

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
        android.util.Log.INFO.clear();
        return d;
    }
    static boolean logged(String what) {
        for (String l : android.util.Log.LINES) if (l.contains(what)) return true;
        return false;
    }
    static boolean noPackageLogged() {
        for (String l : android.util.Log.LINES) if (l.contains("com.")) return false;
        for (String l : android.util.Log.INFO) if (l.contains("com.")) return false;
        return true;
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);

        System.out.println("== (a) a later Off keeps the Play-stack lines, in order");
        File keep;
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            put(f, "a\n" + VEN + "\n" + GMS + "\n");
            StoreInstaller.recordTurnedOff(ctx, "b");
            check(read(f).equals("a\n" + VEN + "\n" + GMS + "\nb\n"), "the file reads a, vending, gms, b");
            keep = d;
        }

        System.out.println("== (b) a package already listed writes nothing");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            String bytes = "a\n\n" + VEN;
            put(f, bytes);
            check(f.setLastModified(1000), "lastModified set to 1000");
            StoreInstaller.recordTurnedOff(ctx, VEN);
            check(read(f).equals(bytes), "the bytes are unchanged");
            check(f.lastModified() == 1000, "lastModified is still 1000 (no rename replaced the file)");
            check(!new File(d, OFF + ".tmp").exists(), "no .tmp is left behind");
        }

        System.out.println("== (c) an unreadable record: recordTurnedOff writes nothing and says so");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            check(f.mkdir(), "nowhere-appoff.list is a directory");
            StoreInstaller.recordTurnedOff(ctx, "b");
            check(logged("Off record unreadable"), "the unreadable line is logged");
            check(!logged("recordTurnedOff"), "writeAtomic's failure line is NOT logged (no write was attempted)");
            check(noPackageLogged(), "no log line names a package");
            check(f.isDirectory() && f.list().length == 0, "the directory is untouched");
            check(!new File(d, OFF + ".tmp").exists(), "no .tmp is left behind");
        }

        System.out.println("== (d) a kept Play Store's vending line is retired");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            put(new File(d, "nowhere-appkeep"), VEN + "\tinstalled\n");
            put(f, VEN + "\na\n");
            StoreInstaller.clearTurnedOff(ctx, Collections.singletonList(VEN));
            check(read(f).equals("a\n"), "only a is left");
        }

        System.out.println("== (e) a package that is not kept is never retired");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            put(new File(d, "nowhere-appkeep"), A + "\tinstalled\n");
            put(f, VEN + "\n" + B + "\n" + A + "\n");
            StoreInstaller.clearTurnedOff(ctx, Arrays.asList(VEN, B));
            check(read(f).equals(VEN + "\n" + B + "\n" + A + "\n"), "the file is unchanged");
        }

        System.out.println("== (f) clearTurnedOff on an unreadable record writes nothing and says so");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            put(new File(d, "nowhere-appkeep"), VEN + "\tinstalled\n");
            check(f.mkdir(), "nowhere-appoff.list is a directory");
            StoreInstaller.clearTurnedOff(ctx, Collections.singletonList(VEN));
            check(logged("Off record unreadable"), "the unreadable line is logged");
            check(!logged("clearTurnedOff"), "writeAtomic's failure line is NOT logged");
            check(noPackageLogged(), "no log line names a package");
            check(f.isDirectory() && f.list().length == 0, "the directory is untouched");
        }

        System.out.println("== (g) the reader view is unchanged: the stack lines are still residue");
        {
            Context ctx = new Context(keep);
            check(ProfileActivity.explicitlyTurnedOff(ctx).equals(new java.util.LinkedHashSet<>(Arrays.asList("a", "b"))),
                  "explicitlyTurnedOff over (a)'s file returns only a, b");
        }

        System.out.println("== (h) an absent record is created holding the package");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, OFF);
            StoreInstaller.recordTurnedOff(ctx, "b");
            check(f.isFile() && read(f).equals("b\n"), "the file holds b");
        }

        System.out.println(failed == 0 ? "ALL CASES PASSED" : failed + " CASE CHECK(S) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
