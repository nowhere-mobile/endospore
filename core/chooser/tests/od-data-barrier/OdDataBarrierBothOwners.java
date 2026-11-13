package com.nowhere.chooser;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/** RF-012: the real OdDataBarrier against the real roamd helpers, with one owner list behind PackageManager. `pm` prints
 *  the state of ALL suspenders, as the platform does. Args: the shell, then the dir holding lib.sh. */
public class OdDataBarrierBothOwners {
    static final String P = "org.example.parked";
    static int failed = 0;
    static String shell;
    static Path d;

    static void chk(String name, boolean ok, Object got) {
        if (ok) System.out.println("  ok    " + name + " [" + shell + "]");
        else { System.out.println("  FAIL  " + name + " [" + shell + "] (got " + got + ")"); failed++; }
    }

    static Path owners() { return d.resolve("owners"); }
    static Path pending() { return d.resolve("state/odfetch.12/pending." + P); }
    static Path record() { return d.resolve("state/odfetch.12/blocked." + P); }
    static Path markPath() { return d.resolve("user/com.nowhere.chooser/files/nowhere-odbarrier/" + P); }

    static List<String> ownerList() {
        try {
            return new ArrayList<>(Files.readAllLines(owners()));
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    static void writeOwners(List<String> l) {
        try {
            Files.write(owners(), l);
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    /** Runs a command of lib.sh under the shell. */
    static void roamd(String cmd) throws Exception {
        ProcessBuilder b = new ProcessBuilder(shell, "-c", ". \"$D/lib.sh\"; " + cmd);
        b.environment().put("D", d.toString());
        b.redirectErrorStream(true);
        Process p = b.start();
        String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        if (p.waitFor() != 0 || !out.isEmpty()) System.out.println("  note  " + cmd + ": rc " + p.exitValue() + " " + out.trim());
    }

    static String reply() throws IOException { return new String(Files.readAllBytes(d.resolve("res")), StandardCharsets.UTF_8).trim(); }

    /** The chooser's side: the suspension is one entry in the owner list, the mark the real file roamd reads. */
    static class Chooser implements OdDataBarrier.Seam {
        public String ask(String p) { return Files.exists(pending()) ? "YES" : "NO"; }
        public boolean suspend(String p, boolean f) {
            List<String> o = ownerList();
            if (!o.contains("chooser")) o.add("chooser");
            writeOwners(o);
            return true;
        }
        public boolean unsuspend(String p) {
            List<String> o = ownerList();
            o.remove("chooser");
            writeOwners(o);
            return true;
        }
        public void mark(String p) { write(new byte[0]); }
        public void confirm(String p) { write(new byte[] {'1'}); }
        void write(byte[] b) {
            try {
                Files.createDirectories(markPath().getParent());
                Files.write(markPath(), b);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
        }
        public void unmark(String p) { markPath().toFile().delete(); }
        public boolean marked(String p) { return Files.exists(markPath()); }
        public boolean claimedElsewhere(String p) { return false; }
        public void log(String l) {}
    }

    static void reset() throws IOException {
        writeOwners(new ArrayList<>());
        Files.write(pending(), new byte[0]);
        Files.deleteIfExists(record());
        Files.deleteIfExists(d.resolve("res"));
        markPath().toFile().delete();
    }

    // Root blocked the app first (the seal's backstop), then the chooser held it too: the case that used to deadlock.
    static void s1() throws Exception {
        reset();
        Chooser c = new Chooser();
        roamd("od_block_app " + P);
        chk("S1 root and chooser: root suspended first", ownerList().contains("root"), ownerList());
        OdDataBarrier.onAdded(c, P);
        chk("S1 root and chooser: both hold it", ownerList().size() == 2, ownerList());
        roamd("run_reply 1 0 " + P);
        chk("S1 root and chooser: OK reply", ("OK " + P).equals(reply()), reply());
        chk("S1 root and chooser: root's suspension removed", !ownerList().contains("root"), ownerList());
        chk("S1 root and chooser: the chooser still holds it until it reads OK", ownerList().contains("chooser"), ownerList());
        chk("S1 root and chooser: the record goes", !Files.exists(record()) || Files.size(record()) == 0, record());
        chk("S1 root and chooser: the marker goes", !Files.exists(pending()), pending());
        OdDataBarrier.afterReply(c, P, reply());
        chk("S1 root and chooser: launchable after the chooser reads OK", ownerList().isEmpty(), ownerList());
        chk("S1 root and chooser: mark removed", !Files.exists(markPath()), markPath());
    }

    // The chooser held the app first (the outside install): root adds nothing, so its dialog cannot replace the chooser's.
    static void s2() throws Exception {
        reset();
        Chooser c = new Chooser();
        OdDataBarrier.onAdded(c, P);
        roamd("od_block_app " + P);
        chk("S2 chooser first: no second suspension", ownerList().equals(List.of("chooser")), ownerList());
        roamd("run_reply 1 0 " + P);
        chk("S2 chooser first: OK reply", ("OK " + P).equals(reply()), reply());
        chk("S2 chooser first: the chooser still holds it until it reads OK", ownerList().equals(List.of("chooser")), ownerList());
        OdDataBarrier.afterReply(c, P, reply());
        chk("S2 chooser first: launchable after the chooser reads OK", ownerList().isEmpty(), ownerList());
        chk("S2 chooser first: mark removed", !Files.exists(markPath()), markPath());
    }

    // The restore keeps a hold: nothing lifts, on either side, and a later good restore still releases both.
    static void s3() throws Exception {
        reset();
        Chooser c = new Chooser();
        roamd("od_block_app " + P);
        OdDataBarrier.onAdded(c, P);
        roamd("run_reply 1 1 " + P);
        chk("S3 kept hold: ERR-NOTREADY", "ERR-NOTREADY".equals(reply()), reply());
        OdDataBarrier.afterReply(c, P, reply());
        chk("S3 kept hold: both still hold it", ownerList().size() == 2, ownerList());
        chk("S3 kept hold: the marker stays", Files.exists(pending()), pending());
        roamd("run_reply 1 0 " + P);
        OdDataBarrier.afterReply(c, P, reply());
        chk("S3 kept hold: the retry releases both", ownerList().isEmpty(), ownerList());
    }

    public static void main(String[] a) throws Exception {
        shell = a[0];
        d = Paths.get(a[1]);
        s1(); s2(); s3();
        System.exit(failed == 0 ? 0 : 1);
    }
}
