package com.nowhere.chooser;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** NWP-20261129-39: AlarmCarry's file and its tokens. Each failed case prints "FAIL C<n> ..."; exits 1 on any. */
public final class AlarmCarryCases {
    private static int fails = 0;

    private static void eq(String id, String what, String got, String want) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("ok " + id + " " + what);
        } else {
            System.out.println("FAIL " + id + " " + what + ": got [" + got + "] want [" + want + "]");
            fails++;
        }
    }

    private static File dir() throws Exception {
        return Files.createTempDirectory("alarm-carry").toFile();
    }

    private static void write(File d, byte[] b) throws Exception {
        Files.write(new File(d, AlarmCarry.FILE).toPath(), b);
    }

    private static void write(File d, String s) throws Exception {
        write(d, s.getBytes(StandardCharsets.US_ASCII));
    }

    private static String exists(File d) {
        return String.valueOf(new File(d, AlarmCarry.FILE).exists());
    }

    /** record(sealed), then the verdict at now 1000 with that registered alarm. */
    private static void token(String sealedTok, long sealed, String nowTok, long registered) throws Exception {
        File d = dir();
        AlarmCarry.record(d, sealed);
        eq("C1", sealed + " against " + registered, AlarmCarry.verdict(d, 1000L, registered), "sealed=" + sealedTok + " now=" + nowTok);
    }

    public static void main(String[] a) throws Exception {
        for (long[] s : new long[][] {{999L, 0L}, {1000L, 0L}, {1001L, 1L}}) { // sealed == now counts as past
            String tok = s[1] == 0L ? "past" : "future";
            token(tok, s[0], "none", 0L);
            token(tok, s[0], "none", -1L);
            token(tok, s[0], "same", s[0]);
            token(tok, s[0], "earlier", s[0] - 1L);
            token(tok, s[0], "later", s[0] + 1L);
        }

        File d = dir();
        AlarmCarry.record(d, 5000L);
        eq("C2", "the first verdict reports", AlarmCarry.verdict(d, 1000L, 5000L), "sealed=future now=same");
        eq("C2", "a second verdict returns null", AlarmCarry.verdict(d, 1000L, 5000L), null);
        eq("C2", "the file is gone", exists(d), "false");

        for (long none : new long[] {0L, -5L}) {
            d = dir();
            AlarmCarry.record(d, 5000L);
            AlarmCarry.record(d, none);
            eq("C3", "record(" + none + ") deletes the file", exists(d), "false");
            eq("C3", "record(" + none + ") leaves no verdict", AlarmCarry.verdict(d, 1000L, 5000L), null);
        }

        eq("C4", "an absent file returns null", AlarmCarry.verdict(dir(), 1000L, 5000L), null);

        String[] bad = {"", "soon", "12x", "1 ", "5\n", "0", "-7", "99999999999999999999", "123456789012345678901234567890123"};
        for (String s : bad) {
            d = dir();
            write(d, s);
            String label = s.replace("\n", "\\n");
            eq("C5", "[" + label + "] with no alarm", AlarmCarry.verdict(d, 1000L, 0L), "sealed=bad now=none");
            eq("C5", "[" + label + "] is deleted", exists(d), "false");
            write(d, s);
            eq("C5", "[" + label + "] with an alarm", AlarmCarry.verdict(d, 1000L, 5000L), "sealed=bad now=later");
        }
        d = dir();
        write(d, new byte[] {(byte) 0xff, (byte) 0xfe, 0});
        eq("C5", "binary bytes", AlarmCarry.verdict(d, 1000L, 0L), "sealed=bad now=none");
        d = dir();
        new File(d, AlarmCarry.FILE).mkdir(); // a read that fails: a directory stands where the file should be
        eq("C5", "an unreadable file", AlarmCarry.verdict(d, 1000L, 0L), "sealed=bad now=none");
        eq("C5", "an unreadable file is deleted", exists(d), "false");

        d = dir();
        AlarmCarry.record(d, 1760000000000L);
        eq("C6", "the dir holds only the file", String.join(",", d.list()), AlarmCarry.FILE);
        eq("C6", "the file holds the decimal value",
                new String(Files.readAllBytes(new File(d, AlarmCarry.FILE).toPath()), StandardCharsets.US_ASCII), "1760000000000");
        AlarmCarry.record(d, 1760000000001L);
        eq("C6", "a second record replaces the first",
                new String(Files.readAllBytes(new File(d, AlarmCarry.FILE).toPath()), StandardCharsets.US_ASCII), "1760000000001");

        File gone = new File(dir(), "missing");
        AlarmCarry.record(gone, 5000L); // neither call throws: this is evidence, never a reason to stop a sign-out
        eq("C7", "a missing dir: record writes nothing", String.valueOf(gone.exists()), "false");
        eq("C7", "a missing dir: verdict returns null", AlarmCarry.verdict(gone, 1000L, 5000L), null);

        if (fails > 0) {
            System.out.println("-- " + fails + " failed");
            System.exit(1);
        }
    }
}
