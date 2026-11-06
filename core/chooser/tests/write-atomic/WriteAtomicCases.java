import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** NWP-20261021-06: StoreInstaller.writeAtomic (lifted verbatim by run.sh) must leave its target byte for byte, and no
 *  .tmp, whenever the open, the write, the close or the rename fails. Each case has its own directory under the root in
 *  args[0]. The failing Writers are real FileWriters on the path they are given: they flush every write and then fail
 *  where the case says, so the bytes are on the disk when the exception is thrown. Every caller writes with
 *  FileWriter's platform charset, so the files are read back in it. */
public class WriteAtomicCases {
    static final String CONTENT = "new\ncontent\n";
    static int failed = 0;

    static String read(File f) throws IOException {
        return new String(Files.readAllBytes(f.toPath()), Charset.defaultCharset());
    }
    static void put(File f, String s) throws IOException {
        try (FileWriter w = new FileWriter(f)) { w.write(s); }
    }
    static File tmpOf(File f) { return new File(f.getParentFile(), f.getName() + ".tmp"); }

    enum Mode { OK, CLOSE_THROWS, WRITE_THROWS_PARTWAY, OPEN_THROWS }

    /** Closes the file, then reports the close as failed: the text is on the disk, as after an ENOSPC at the flush. */
    static class CloseFails extends FileWriter {
        CloseFails(File f) throws IOException { super(f); }
        @Override public void write(String s, int off, int len) throws IOException { super.write(s, off, len); flush(); }
        @Override public void close() throws IOException { super.close(); throw new IOException("close failed (injected)"); }
    }

    /** Writes part of the text, flushes it, and fails. */
    static class WriteFails extends FileWriter {
        WriteFails(File f) throws IOException { super(f); }
        @Override public void write(String s, int off, int len) throws IOException {
            super.write(s, off, Math.max(1, len / 2));
            flush();
            throw new IOException("write failed partway (injected)");
        }
    }

    /** Records every path it is asked to open. */
    static class Recording implements StoreInstaller.AtomicIo {
        final List<String> opened = new ArrayList<>();
        final Mode mode;
        final boolean renameOk;
        Recording(Mode mode, boolean renameOk) { this.mode = mode; this.renameOk = renameOk; }
        @Override public java.io.Writer open(File f) throws IOException {
            opened.add(f.getPath());
            switch (mode) {
                case OPEN_THROWS: throw new IOException("open failed (injected)");
                case CLOSE_THROWS: return new CloseFails(f);
                case WRITE_THROWS_PARTWAY: return new WriteFails(f);
                default: return new FileWriter(f);
            }
        }
        @Override public boolean rename(File from, File to) {
            return renameOk && StoreInstaller.FILE_IO.rename(from, to);
        }
    }

    static void check(String name, boolean ok, String why) {
        if (ok) System.out.println("  ok    " + name);
        else { System.out.println("  FAIL  " + name + ": " + why); failed++; }
    }

    interface Body { void run(File dir) throws Exception; }
    static void kase(File root, String name, Body b) {
        File dir = new File(root, name.substring(0, 1));
        try { dir.mkdirs(); b.run(dir); }
        catch (Throwable t) { check(name, false, "unexpected " + t); }
    }

    /** target "old", io fails the way mode says: IOException, target "old", no .tmp, only <name>.tmp opened. */
    static void failedWriteKeepsTarget(File dir, String name, Mode mode) throws Exception {
        File target = new File(dir, "keep");
        put(target, "old");
        Recording io = new Recording(mode, true);
        boolean threw = false;
        try { StoreInstaller.writeAtomic(target, CONTENT, io); } catch (IOException e) { threw = true; }
        check(name + " throws IOException", threw, "no IOException");
        check(name + " target still old", read(target).equals("old"), "target holds [" + read(target) + "]");
        check(name + " no .tmp", !tmpOf(target).exists(), tmpOf(target) + " left behind");
        check(name + " opened only the .tmp", io.opened.equals(Arrays.asList(tmpOf(target).getPath())),
              "opened " + io.opened);
    }

    public static void main(String[] a) {
        File root = new File(a[0]);
        kase(root, "a absent target is created", dir -> {
            File target = new File(dir, "made");
            StoreInstaller.writeAtomic(target, CONTENT, StoreInstaller.FILE_IO);
            check("a absent target is created", target.isFile() && read(target).equals(CONTENT), "target missing or wrong");
            check("a no .tmp", !tmpOf(target).exists(), tmpOf(target) + " left behind");
        });
        kase(root, "b close fails", dir -> failedWriteKeepsTarget(dir, "b close fails", Mode.CLOSE_THROWS));
        kase(root, "c write fails partway", dir -> failedWriteKeepsTarget(dir, "c write fails partway", Mode.WRITE_THROWS_PARTWAY));
        kase(root, "d open fails", dir -> failedWriteKeepsTarget(dir, "d open fails", Mode.OPEN_THROWS));
        kase(root, "e rename fails", dir -> {
            File target = new File(dir, "keep");
            put(target, "old");
            Recording io = new Recording(Mode.OK, false);
            String msg = null;
            try { StoreInstaller.writeAtomic(target, CONTENT, io); } catch (IOException e) { msg = e.getMessage(); }
            check("e rename fails throws IOException", msg != null && msg.startsWith("rename "), "message " + msg);
            check("e rename fails target still old", read(target).equals("old"), "target holds [" + read(target) + "]");
            check("e rename fails no .tmp", !tmpOf(target).exists(), tmpOf(target) + " left behind");
            check("e rename fails opened only the .tmp", io.opened.equals(Arrays.asList(tmpOf(target).getPath())),
                  "opened " + io.opened);
        });
        kase(root, "f target is a non-empty directory", dir -> {
            File target = new File(dir, "isdir");
            target.mkdir();
            put(new File(target, "inside"), "kept");
            boolean threw = false;
            try { StoreInstaller.writeAtomic(target, CONTENT); } catch (IOException e) { threw = true; }
            check("f directory throws IOException", threw, "no IOException");
            check("f directory still a directory", target.isDirectory(), "target is no longer a directory");
            check("f directory file untouched", read(new File(target, "inside")).equals("kept"), "inside changed");
            check("f directory holds only inside", Arrays.equals(target.list(), new String[] {"inside"}),
                  "holds " + Arrays.toString(target.list()));
            check("f directory no .tmp", !tmpOf(target).exists(), tmpOf(target) + " left behind");
        });
        kase(root, "g two-argument round trip", dir -> {
            File target = new File(dir, "keep");
            put(target, "old");
            StoreInstaller.writeAtomic(target, CONTENT);
            check("g round trip content", read(target).equals(CONTENT), "target holds [" + read(target) + "]");
            check("g round trip no .tmp", !tmpOf(target).exists(), tmpOf(target) + " left behind");
        });
        System.out.println(failed == 0 ? "  all checks passed" : "  " + failed + " check(s) FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
