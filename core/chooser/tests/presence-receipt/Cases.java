import android.content.Context;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.Set;

/** NWP-20261120-18: the session-presence receipts (files/nowhere-appseen, files/nowhere-appgone), lifted verbatim by
 *  run.sh, keep their stamp discipline. A matching stamp unions; a foreign or absent stamp reads empty and is
 *  replaced on write; an unreadable user serial (-1) writes nothing and reads nothing. seenStamp is stubbed as
 *  stampFor(ctx.serial). Each case has its own files dir under the root in args[0]. */
public class Cases {
    static final String A = "com.example.alpha", B = "com.example.beta", C = "com.example.gamma";
    static final String SEEN = "nowhere-appseen", GONE = "nowhere-appgone";
    static final String UNREADABLE = "presence receipt: user serial unreadable -- not recorded";
    static int failed = 0;
    static int n = 0;

    static String read(File f) throws IOException { return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8); }
    static void put(File f, String s) throws IOException { Files.write(f.toPath(), s.getBytes(StandardCharsets.UTF_8)); }
    static void ok(String what) { System.out.println("  ok    " + what); }
    static void no(String what) { failed++; System.out.println("  FAIL  " + what); }
    static void check(boolean c, String what) { if (c) ok(what); else no(what); }
    static Set<String> set(String... p) { return new LinkedHashSet<>(Arrays.asList(p)); }
    static boolean sameOrder(Set<String> got, String... want) {
        return new java.util.ArrayList<>(got).equals(Arrays.asList(want));
    }

    static File caseDir(File root) throws IOException {
        File d = new File(root, "c" + (++n));
        if (!d.mkdir()) throw new IOException("mkdir " + d);
        android.util.Log.LINES.clear();
        android.util.Log.INFO.clear();
        return d;
    }
    static boolean logNamesAPackage() {
        for (String l : android.util.Log.LINES) if (l.contains("com.example")) return true;
        for (String l : android.util.Log.INFO) if (l.contains("com.example")) return true;
        return false;
    }
    static boolean logged(String what) {
        for (String l : android.util.Log.LINES) if (l.contains(what)) return true;
        return false;
    }
    static String[] listing(File d) {
        String[] l = d.list();
        if (l == null) return new String[0];
        Arrays.sort(l);
        return l;
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);

        System.out.println("== (R1) snapshot {a} then {b} under serial 7: the union, stamp line first");
        {
            File d = caseDir(root); Context ctx = new Context(d, 7); File f = new File(d, SEEN);
            StoreInstaller.snapshotAppSeen(ctx, set(A));
            StoreInstaller.snapshotAppSeen(ctx, set(B));
            check(read(f).equals("#stamp 7\n" + A + "\n" + B + "\n"), "the receipt reads \"#stamp 7\", a, b");
            check(sameOrder(StoreInstaller.appSeenThisSession(ctx), A, B), "appSeenThisSession reads a, b, in order");
            check(!new File(d, SEEN + ".tmp").exists(), "no .tmp is left behind");
        }

        System.out.println("== (R2) a receipt stamped \"#stamp 8\" read under serial 7: empty, and a snapshot replaces it");
        {
            File d = caseDir(root); Context ctx = new Context(d, 7); File f = new File(d, SEEN);
            put(f, "#stamp 8\n" + C + "\n");
            check(StoreInstaller.appSeenThisSession(ctx).isEmpty(), "appSeenThisSession reads session 8's receipt as empty");
            StoreInstaller.snapshotAppSeen(ctx, set(A));
            check(read(f).equals("#stamp 7\n" + A + "\n"), "the snapshot re-stamps for 7 and drops session 8's c");
        }

        System.out.println("== (R3) unstamped receipts read under serial 7: empty");
        {
            File d = caseDir(root); Context ctx = new Context(d, 7);
            put(new File(d, SEEN), A + "\n" + B + "\n");
            put(new File(d, GONE), A + "\n" + B + "\n");
            check(StoreInstaller.appSeenThisSession(ctx).isEmpty(), "appSeenThisSession reads an unstamped receipt as empty");
            check(StoreInstaller.appGoneThisSession(ctx).isEmpty(), "appGoneThisSession reads an unstamped receipt as empty");
        }

        System.out.println("== (R4) serial -1 (the lookup threw): snapshotAppSeen and noteAppGone write nothing");
        {
            File d = caseDir(root); Context ctx = new Context(d, -1); File f = new File(d, SEEN);
            String before = "#stamp 7\n" + A + "\n";
            put(f, before);
            StoreInstaller.snapshotAppSeen(ctx, set(B));
            StoreInstaller.noteAppGone(ctx, C);
            check(read(f).equals(before), "the existing appseen receipt is byte for byte unchanged");
            check(!new File(d, GONE).exists(), "no appgone receipt is created");
            check(Arrays.equals(listing(d), new String[] {SEEN}), "the files dir holds only the old receipt (no .tmp)");
            check(logged(UNREADABLE), "the refusal is logged");
            check(!logNamesAPackage(), "no log line names a package");
        }
        {
            File d = caseDir(root); Context ctx = new Context(d, -1);
            StoreInstaller.snapshotAppSeen(ctx, set(A));
            StoreInstaller.noteAppGone(ctx, B);
            check(listing(d).length == 0, "in an empty files dir, neither call creates a file");
        }

        System.out.println("== (R5) receipts stamped \"#stamp -1\" read under serial -1: empty for both readers");
        {
            File d = caseDir(root); Context ctx = new Context(d, -1);
            put(new File(d, SEEN), "#stamp -1\n" + A + "\n");
            put(new File(d, GONE), "#stamp -1\n" + A + "\n");
            check(StoreInstaller.appSeenThisSession(ctx).isEmpty(), "appSeenThisSession reads a \"#stamp -1\" receipt as empty");
            check(StoreInstaller.appGoneThisSession(ctx).isEmpty(), "appGoneThisSession reads a \"#stamp -1\" receipt as empty");
        }

        System.out.println("== (R6) noteAppGone of an already-listed package does not rewrite the receipt");
        {
            File d = caseDir(root); Context ctx = new Context(d, 7); File f = new File(d, GONE);
            StoreInstaller.noteAppGone(ctx, A);
            long old = 1_000_000_000_000L;
            check(f.setLastModified(old) && f.lastModified() == old, "the receipt's mtime is set to a fixed old value");
            String before = read(f);
            StoreInstaller.noteAppGone(ctx, A);
            check(read(f).equals(before) && before.equals("#stamp 7\n" + A + "\n"), "the receipt is byte for byte unchanged");
            check(f.lastModified() == old, "the receipt's mtime is unchanged (no rewrite)");
        }

        System.out.println("== (R7) noteAppGone under serial 7 over a receipt stamped \"#stamp 8\": truncates and re-stamps");
        {
            File d = caseDir(root); Context ctx = new Context(d, 7); File f = new File(d, GONE);
            put(f, "#stamp 8\n" + B + "\n");
            StoreInstaller.noteAppGone(ctx, A);
            check(read(f).equals("#stamp 7\n" + A + "\n"), "the receipt reads \"#stamp 7\", a (session 8's b is gone)");
            check(StoreInstaller.appGoneThisSession(ctx).equals(set(A)), "appGoneThisSession reads {a}");
        }

        System.out.println("== (R8) blank and '#' lines are not packages");
        {
            File d = caseDir(root); Context ctx = new Context(d, 7);
            String body = "#stamp 7\n\n  \n# note\n" + A + "\n#" + B + "\n";
            put(new File(d, SEEN), body);
            put(new File(d, GONE), body);
            check(StoreInstaller.appSeenThisSession(ctx).equals(set(A)), "appSeenThisSession reads exactly {a}");
            check(StoreInstaller.appGoneThisSession(ctx).equals(set(A)), "appGoneThisSession reads exactly {a}");
        }

        System.out.println("== (R9) stampFor: a serial names a session, a negative serial names none");
        {
            check("#stamp 0".equals(StoreInstaller.stampFor(0)), "stampFor(0) is \"#stamp 0\"");
            check("#stamp 7".equals(StoreInstaller.stampFor(7)), "stampFor(7) is \"#stamp 7\"");
            check(StoreInstaller.stampFor(-1) == null, "stampFor(-1) is null");
            check(StoreInstaller.stampFor(-2) == null, "stampFor(-2) is null");
        }

        System.out.println(failed == 0 ? "== all cases pass" : "== " + failed + " check(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
