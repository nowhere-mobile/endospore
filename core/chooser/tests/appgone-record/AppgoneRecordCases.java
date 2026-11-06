import android.content.Context;
import java.io.File;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;

/** NWP-20261023-10: recordUninstalled, readUninstalled and clearUninstalled (lifted verbatim by run.sh) keep
 *  nowhere-appgone.list as the record of what the user UNINSTALLED. A write is made to fail by occupying
 *  "<name>.tmp" with a non-empty directory: the temp cannot be opened, as root too. Each case has its own files dir
 *  under the root in args[0]. */
public class AppgoneRecordCases {
    static final String A = "com.example.alpha", B = "com.example.beta", C = "com.example.gamma";
    static final String REC = "nowhere-appgone.list";
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
    /** Occupy "<name>.tmp" with a non-empty directory, so writeAtomic cannot open its temp. */
    static void blockTmp(File dir, String name) throws IOException {
        File t = new File(dir, name + ".tmp");
        if (!t.mkdir() || !new File(t, "keep").createNewFile()) throw new IOException("block " + t);
    }
    static boolean logged(String what) {
        for (String l : android.util.Log.LINES) if (l.contains(what)) return true;
        return false;
    }
    static boolean infoNamesAPackage() {
        for (String l : android.util.Log.INFO) if (l.contains("com.example")) return true;
        return false;
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);

        System.out.println("== (a) record {a,b} then {b,c}: a,b,c once each, in order; nothing to add writes nothing");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, REC);
            StoreInstaller.recordUninstalled(ctx, Arrays.asList(A, B));
            StoreInstaller.recordUninstalled(ctx, Arrays.asList(B, C));
            check(read(f).equals(A + "\n" + B + "\n" + C + "\n"), "the file reads a, b, c, one line each");
            check(StoreInstaller.readUninstalled(ctx).equals(new java.util.LinkedHashSet<>(Arrays.asList(A, B, C))),
                  "readUninstalled reads the three back, in order");
            check(!new File(d, REC + ".tmp").exists(), "no .tmp is left behind");
            check(!new File(d, "nowhere-appoff.list").exists(), "the Off record is not touched");
            check(!infoNamesAPackage() && !android.util.Log.INFO.isEmpty(), "the info log carries counts, never a package name");
            check(android.util.Log.LINES.isEmpty(), "nothing is warned on success");
            // from here a write cannot happen: any attempt shows as a log line, and the bytes and mtime are compared
            blockTmp(d, REC);
            String before = read(f); long mtime = f.lastModified();
            StoreInstaller.recordUninstalled(ctx, Collections.<String>emptySet());
            StoreInstaller.recordUninstalled(ctx, null);
            StoreInstaller.recordUninstalled(ctx, Arrays.asList(B));
            StoreInstaller.recordUninstalled(ctx, Arrays.asList("", "  ", B));
            check(read(f).equals(before) && f.lastModified() == mtime, "an empty, null or already-listed set leaves the file as it was");
            check(android.util.Log.LINES.isEmpty(), "no write was attempted (nothing logged)");
        }

        System.out.println("== (a2) a blank entry is skipped and the first record creates the file");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            check(StoreInstaller.readUninstalled(ctx).isEmpty(), "an absent file reads empty");
            StoreInstaller.recordUninstalled(ctx, Arrays.asList("", A));
            check(read(new File(d, REC)).equals(A + "\n"), "only the non-empty package is written");
        }

        System.out.println("== (b) clearUninstalled retires only a package that is kept");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, REC);
            put(new File(d, "nowhere-appkeep"), A + "\tondemand\n");
            StoreInstaller.recordUninstalled(ctx, Arrays.asList(A, B, C));
            StoreInstaller.clearUninstalled(ctx, Arrays.asList(A, C));
            check(read(f).equals(B + "\n" + C + "\n"), "a (kept) is retired, c (not kept) stays, b is untouched");
            check(!new File(d, "nowhere-appoff.list").exists(), "clearUninstalled never creates the Off record");
            blockTmp(d, REC);
            String before = read(f); long mtime = f.lastModified();
            android.util.Log.LINES.clear();
            StoreInstaller.clearUninstalled(ctx, null);
            StoreInstaller.clearUninstalled(ctx, Collections.<String>emptySet());
            StoreInstaller.clearUninstalled(ctx, Arrays.asList(C));
            StoreInstaller.clearUninstalled(ctx, Arrays.asList(A));
            check(read(f).equals(before) && f.lastModified() == mtime, "null, empty, a not-kept and an unlisted package change nothing");
            check(android.util.Log.LINES.isEmpty(), "no write was attempted (nothing logged)");
        }

        System.out.println("== (b2) clearUninstalled never adds, and a kept package with no line writes nothing");
        {
            File d = caseDir(root); Context ctx = new Context(d);
            put(new File(d, "nowhere-appkeep"), A + "\tondemand\n");
            StoreInstaller.clearUninstalled(ctx, Arrays.asList(A));
            check(!new File(d, REC).exists(), "no record is created for a package that was never uninstalled");
        }

        System.out.println("== (c) a failed write leaves nowhere-appgone.list byte for byte");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, REC);
            String before = A + "\n" + B + "\n";
            put(f, before);
            put(new File(d, "nowhere-appkeep"), A + "\tondemand\n");
            blockTmp(d, REC);
            StoreInstaller.recordUninstalled(ctx, Arrays.asList(C));
            check(read(f).equals(before), "record: the file is exactly as it was");
            check(logged("recordUninstalled"), "record: the failure is logged as recordUninstalled");
            android.util.Log.LINES.clear();
            StoreInstaller.clearUninstalled(ctx, Arrays.asList(A));
            check(read(f).equals(before), "clear: the file is exactly as it was");
            check(logged("clearUninstalled"), "clear: the failure is logged as clearUninstalled");
        }

        System.out.println("== (c2) an unreadable record is never rewritten from nothing");
        {
            File d = caseDir(root); Context ctx = new Context(d); File f = new File(d, REC);
            if (!f.mkdir()) throw new IOException("mkdir " + f);
            check(StoreInstaller.readUninstalled(ctx).isEmpty(), "readUninstalled reads an unreadable record as empty");
            StoreInstaller.recordUninstalled(ctx, Arrays.asList(A));
            check(f.isDirectory(), "recordUninstalled wrote nothing over it");
            check(logged("recordUninstalled"), "the failure is logged");
        }

        System.out.println(failed == 0 ? "== all cases pass" : "== " + failed + " case(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
