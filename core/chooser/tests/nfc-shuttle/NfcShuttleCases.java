package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.StringReader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

// NWP-20261020-22: the cases for the NFC APDU shuttle (NfcShuttle.run): lazy connect, setTimeout always, fail fast
// after one failed exchange, the reply mapping, the malformed-APDU refusal (odd length, non-hex, a signed pair), the
// lost-link mapping (LINK_LOST) and the NfcTapVerdict texts the gate paints for a failed tap.
public final class NfcShuttleCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    /** Records every call; a transceive replies with {0xAB,0x0F,0x90,0x00} or throws when failWith is set. */
    static final class FakeTap implements NfcShuttle.Tap {
        final List<String> calls = new ArrayList<>();
        boolean already;
        String failWith;
        public boolean isConnected() { calls.add("isConnected"); return already; }
        public void connect() { calls.add("connect"); }
        public void setTimeout(int ms) { calls.add("setTimeout:" + ms); }
        public byte[] transceive(byte[] apdu) throws IOException {
            calls.add("transceive:" + NfcShuttle.bytesToHex(apdu));
            if (failWith != null) throw new IOException(failWith);
            return new byte[]{(byte) 0xAB, 0x0F, (byte) 0x90, 0x00};
        }
        long count(String prefix) { return calls.stream().filter(c -> c.startsWith(prefix)).count(); }
    }

    static final NfcShuttle.Clock CLOCK = () -> 0L;
    static final NfcShuttle.Log LOG = new NfcShuttle.Log() {
        public void info(String m) {}
        public void warn(String m, Throwable t) {}
    };

    static String[] last;
    static String sent;
    static BufferedReader lastIn;

    static void drive(FakeTap tap, String input) throws IOException {
        lastIn = new BufferedReader(new StringReader(input));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        last = NfcShuttle.run(lastIn, out, tap, 5000, CLOCK, LOG);
        sent = out.toString("UTF-8");
    }

    public static void main(String[] a) throws Exception {
        // (1) lazy connect
        FakeTap t = new FakeTap();
        drive(t, "OK nothing\n");
        check("no tag call before the first APDU", t.calls.isEmpty(), t.calls);

        t = new FakeTap();
        drive(t, "APDU 00A4\nAPDU 00B0\nOK done\n");
        check("exactly one connect over two APDUs", t.count("connect") == 1, t.calls);
        check("setTimeout(apduTimeoutMs) follows the connect",
                t.calls.indexOf("connect") >= 0 && t.calls.indexOf("setTimeout:5000") > t.calls.indexOf("connect"), t.calls);
        check("setTimeout is applied once", t.count("setTimeout") == 1, t.calls);
        check("both APDUs are transceived", t.count("transceive") == 2, t.calls);

        t = new FakeTap();
        t.already = true;
        drive(t, "APDU 00A4\nOK done\n");
        check("an already-connected tag is not connected again", t.count("connect") == 0, t.calls);
        check("an already-connected tag still gets setTimeout", t.count("setTimeout:5000") == 1, t.calls);

        // (2) the mapping of a good exchange
        t = new FakeTap();
        drive(t, "APDU 00A4\nOK done\n");
        check("APDU 00A4 is transceived as {0x00,0xA4}", t.calls.contains("transceive:00a4"), t.calls);
        check("the reply is RESP <lowercase hex>", sent.equals("RESP ab0f9000\n"), sent);
        t = new FakeTap();
        drive(t, "APDU 0aFF\nOK done\n");
        check("upper-case hex input is accepted", t.calls.contains("transceive:0aff") && sent.equals("RESP ab0f9000\n"), t.calls + sent);

        // (3) fail fast
        t = new FakeTap();
        t.failWith = "x";
        drive(t, "APDU 00A4\nAPDU 00B0\nAPDU 00C0\nOK done\n");
        check("a failed transceive answers NFCERR <message>",
                sent.equals("NFCERR x\nNFCERR link lost\nNFCERR link lost\n"), sent);
        check("no transceive after the first failure", t.count("transceive") == 1, t.calls);

        // (4) the line mapping
        t = new FakeTap();
        drive(t, "\n   \nOK done\nAPDU 00\n");
        check("OK returns {OK, line}", Arrays.equals(last, new String[]{"OK", "OK done"}), Arrays.toString(last));
        check("nothing is read after OK", lastIn.readLine().equals("APDU 00"), "lines after OK were consumed");
        check("blank lines are skipped and nothing was sent", sent.isEmpty() && t.calls.isEmpty(), sent + t.calls);
        drive(new FakeTap(), "ERR nokey\n");
        check("ERR returns {ERR, line}", Arrays.equals(last, new String[]{"ERR", "ERR nokey"}), Arrays.toString(last));
        drive(new FakeTap(), "garbage\n");
        check("any other non-empty line returns {ERR, line}", Arrays.equals(last, new String[]{"ERR", "garbage"}), Arrays.toString(last));
        drive(new FakeTap(), "");
        check("EOF returns {ERR, closed}", Arrays.equals(last, new String[]{"ERR", "closed"}), Arrays.toString(last));

        // (5) odd length
        t = new FakeTap();
        drive(t, "APDU 00A\nAPDU 00A4\nOK done\n");
        check("an odd-length APDU is answered NFCERR bad apdu, then the link is dead",
                sent.equals("NFCERR bad apdu\nNFCERR link lost\n"), sent);
        check("an odd-length APDU never reaches the tag", t.count("transceive") == 0, t.calls);

        // (6) NWP-20261109-05: a drop inside the exchange is told apart from a refusal
        check("LINK_LOST is nfc-link-lost", NfcShuttle.LINK_LOST.equals("nfc-link-lost"), NfcShuttle.LINK_LOST);
        t = new FakeTap();
        t.failWith = "x";
        drive(t, "APDU 00A4\nERR\n");
        check("a failed transceive then ERR is {ERR, nfc-link-lost}",
                Arrays.equals(last, new String[]{"ERR", "nfc-link-lost"}), Arrays.toString(last));
        t = new FakeTap();
        t.failWith = "x";
        drive(t, "APDU 00A4\n");
        check("a failed transceive then EOF is {ERR, nfc-link-lost}",
                Arrays.equals(last, new String[]{"ERR", "nfc-link-lost"}), Arrays.toString(last));
        t = new FakeTap();
        t.failWith = "x";
        drive(t, "APDU 00A4\nOK x\n");
        check("a failed transceive then OK stays {OK, OK x}", Arrays.equals(last, new String[]{"OK", "OK x"}), Arrays.toString(last));
        drive(new FakeTap(), "APDU 00A\nERR\n");
        check("an odd-length APDU then ERR is {ERR, ERR}, not a lost link",
                Arrays.equals(last, new String[]{"ERR", "ERR"}), Arrays.toString(last));
        drive(new FakeTap(), "APDU 00A4\nERR nokey\n");
        check("a clean exchange then ERR nokey is {ERR, ERR nokey}",
                Arrays.equals(last, new String[]{"ERR", "ERR nokey"}), Arrays.toString(last));

        // (8) NWP-20261127-18: a malformed APDU (not even-length ASCII hex) is refused before the tag. It is a
        // daemon bug, not a dropped key, so the result keeps the daemon's own line and never reads LINK_LOST.
        for (String bad : new String[]{"00a4zz", "-f00"}) {
            t = new FakeTap();
            drive(t, "APDU " + bad + "\nERR\n");
            check("APDU " + bad + " is answered NFCERR bad apdu", sent.equals("NFCERR bad apdu\n"), sent);
            check("APDU " + bad + " never connects the tag", t.count("connect") == 0 && t.count("isConnected") == 0, t.calls);
            check("APDU " + bad + " never reaches the tag", t.count("transceive") == 0, t.calls);
            check("APDU " + bad + " then ERR is {ERR, ERR}, not a lost link",
                    Arrays.equals(last, new String[]{"ERR", "ERR"}), Arrays.toString(last));
        }
        t = new FakeTap();
        drive(t, "APDU 00+1\nOK x\n");
        check("APDU 00+1 (a signed pair) is answered NFCERR bad apdu", sent.equals("NFCERR bad apdu\n"), sent);
        check("APDU 00+1 is never sent to the key", t.count("transceive") == 0 && t.count("connect") == 0, t.calls);
        t = new FakeTap();
        drive(t, "APDU 00a4zz\nAPDU 00A4\nOK done\n");
        check("a malformed APDU is answered NFCERR bad apdu, then the link is dead",
                sent.equals("NFCERR bad apdu\nNFCERR link lost\n"), sent);
        check("a malformed APDU then a good one makes no tag call", t.calls.isEmpty(), t.calls);
        t = new FakeTap();
        drive(t, "APDU \nERR\n");
        check("an empty payload stays outside the APDU arm: {ERR, APDU}",
                Arrays.equals(last, new String[]{"ERR", "APDU"}), Arrays.toString(last));
        check("an empty payload sends nothing and makes no tag call", sent.isEmpty() && t.calls.isEmpty(), sent + t.calls);
        String[] hexIn = {"", "0", "00", "0aFf", "0g", "+1", "-1", " 0", "00 "};
        boolean[] hexOk = {false, false, true, true, false, false, false, false, false};
        for (int i = 0; i < hexIn.length; i++) {
            check("isHexApdu(\"" + hexIn[i] + "\") is " + hexOk[i], NfcShuttle.isHexApdu(hexIn[i]) == hexOk[i],
                    NfcShuttle.isHexApdu(hexIn[i]));
        }
        // Non-ASCII digits and letters are not hex either (Character.digit would decode both).
        check("isHexApdu of two ARABIC-INDIC DIGIT THREE is false", !NfcShuttle.isHexApdu("\u0663\u0663"), true);
        check("isHexApdu of FULLWIDTH 0 and A is false", !NfcShuttle.isHexApdu("\uFF10\uFF21"), true);
        for (String h : new String[]{"+1", "0g", "\uFF10\uFF10"}) {
            String got;
            try {
                got = "returned " + NfcShuttle.bytesToHex(NfcShuttle.hexToBytes(h));
            } catch (IllegalArgumentException e) {
                got = "IAE";
            } catch (Throwable e) {
                got = "threw " + e;
            }
            check("hexToBytes(\"" + h + "\") throws IllegalArgumentException", got.equals("IAE"), got);
        }
        check("hexToBytes(\"0aFf\") is {0x0a, 0xff}",
                Arrays.equals(NfcShuttle.hexToBytes("0aFf"), new byte[]{0x0a, (byte) 0xff}),
                Arrays.toString(NfcShuttle.hexToBytes("0aFf")));

        // (7) NWP-20261109-05: what the gate paints. The expected texts are spelled out, not read from the constants.
        final String drop = "Didn't catch the key \u2014 hold it flat and steady on the back, then tap again.";
        final String freshFail = "Couldn't sign in with that key \u2014 check your name and passphrase and try again.";
        final String resumeFail = "Couldn't read your security key.\nHold it flat against the back of the phone \u2014 no rush.";
        check("resume + LINK_LOST is the drop line", NfcTapVerdict.failText(true, "nfc-link-lost").equals(drop),
                NfcTapVerdict.failText(true, "nfc-link-lost"));
        check("resume + ERR is the key-read line", NfcTapVerdict.failText(true, "ERR").equals(resumeFail),
                NfcTapVerdict.failText(true, "ERR"));
        check("resume + closed is the drop line", NfcTapVerdict.failText(true, "closed").equals(drop),
                NfcTapVerdict.failText(true, "closed"));
        for (String d : new String[]{"nfc-link-lost", "ERR", "closed", "nfc-io", "not-fido", null, ""}) {
            String x = NfcTapVerdict.failText(true, d);
            check("resume text for " + d + " names no PIN, passphrase or Retry",
                    !x.contains("PIN") && !x.contains("passphrase") && !x.contains("Retry"), x);
        }
        check("fresh + LINK_LOST is the check line", NfcTapVerdict.failText(false, "nfc-link-lost").equals(freshFail),
                NfcTapVerdict.failText(false, "nfc-link-lost"));
        for (String d : new String[]{"closed", "nfc-io", "not-fido"}) {
            check("fresh + " + d + " is the drop line", NfcTapVerdict.failText(false, d).equals(drop),
                    NfcTapVerdict.failText(false, d));
        }
        check("fresh + ERR is the check line", NfcTapVerdict.failText(false, "ERR").equals(freshFail),
                NfcTapVerdict.failText(false, "ERR"));

        System.out.println((runs - fails) + "/" + runs + " passed");
        if (fails > 0) System.exit(1);
    }
}
