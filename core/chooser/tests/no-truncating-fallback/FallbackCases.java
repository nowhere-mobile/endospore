import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;

/** NWP-20261022-06: GosState.write and AppClaim.writeReceipt (lifted by run.sh) publish through
 *  StoreInstaller.writeAtomic, so a refused rename or open leaves a target that held "old" byte for byte, leaves no
 *  .tmp, logs the failure and lets nothing escape. Each case has its own directory under the root in args[0]. */
public class FallbackCases {
    static final String OLD = "old";
    static final String GOS_NEW = "pkg\t1\t2\nother\t3\t4\n";
    static final String RECEIPT_NEW = "#user 10\ncom.a\ncom.b\n";
    static int failed = 0;
    static File root;
    static int seq = 0;

    /** The real file I/O, with an open or a rename that can be made to fail. */
    static class Seam implements StoreInstaller.AtomicIo {
        boolean refuseOpen, refuseRename;
        @Override public java.io.Writer open(File f) throws IOException {
            if (refuseOpen) throw new IOException("open refused (injected)");
            return new FileWriter(f);
        }
        @Override public boolean rename(File from, File to) { return !refuseRename && from.renameTo(to); }
    }

    static String read(File f) throws IOException {
        return new String(Files.readAllBytes(f.toPath()), Charset.defaultCharset());
    }
    static void put(File f, String s) throws IOException {
        try (FileWriter w = new FileWriter(f)) { w.write(s); }
    }
    static void fail(String id, String what) { failed++; System.out.println("FAIL (" + id + "): " + what); }

    interface Writer { void run(File dir, File target) throws Throwable; }

    /** One writer, one target, one seam: returns normally with the checks made. */
    static void run(String id, String who, String targetName, String fresh, Writer w, boolean refuseOpen,
                    boolean refuseRename, boolean expectNew) throws IOException {
        File dir = new File(root, "c" + (seq++));
        if (!dir.mkdir()) throw new IOException("mkdir " + dir);
        File target = new File(dir, targetName);
        File tmp = new File(dir, targetName + ".tmp");
        put(target, OLD);
        Seam seam = new Seam();
        seam.refuseOpen = refuseOpen;
        seam.refuseRename = refuseRename;
        StoreInstaller.FILE_IO = seam;
        int warned = Log.warned;
        try { w.run(dir, target); }
        catch (Throwable t) { fail(id, who + ": " + t + " escaped"); return; }
        String want = expectNew ? fresh : OLD;
        String got = target.isFile() ? read(target) : "<not a regular file>";
        if (!got.equals(want)) fail(id, who + ": target holds [" + got.replace("\n", "\\n") + "], want [" +
                want.replace("\n", "\\n") + "]");
        if (tmp.exists()) fail(id, who + ": " + tmp.getName() + " left behind");
        boolean logged = Log.warned > warned;
        if (expectNew == logged) fail(id, who + (expectNew ? ": logged a failure on a good write" : ": logged nothing for the failure"));
    }

    static void both(String id, boolean refuseOpen, boolean refuseRename, boolean expectNew) throws IOException {
        run(id, "GosState.write", "nowhere-gos-carry", GOS_NEW,
                (dir, t) -> GosState.write(t, GOS_NEW), refuseOpen, refuseRename, expectNew);
        run(id, "AppClaim.writeReceipt", "nowhere-appclaim", RECEIPT_NEW, (dir, t) -> {
            java.util.LinkedHashSet<String> pkgs = new java.util.LinkedHashSet<>();
            pkgs.add("com.a"); pkgs.add("com.b");
            AppClaim.writeReceipt(new Context(dir), 10, pkgs, "hold");
        }, refuseOpen, refuseRename, expectNew);
    }

    public static void main(String[] args) throws Exception {
        root = new File(args[0]);
        both("a rename refused", false, true, false);
        both("b open refused", true, false, false);
        both("c both refused", true, true, false);
        both("d nothing refused", false, false, true);
        // the receipt's temp is its own name + .tmp, the one writeAtomic cleans up
        if (!"nowhere-appclaim".equals(AppClaim.RECEIPT)) fail("e receipt name", AppClaim.RECEIPT);
        System.out.println(failed == 0 ? "all cases passed" : failed + " case failure(s)");
        System.exit(failed == 0 ? 0 : 1);
    }
}
