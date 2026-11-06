package com.nowhere.napps;

/**
 * Cases for NappsAction (NWP-20261119-19), compiled with NappsAction.java alone by
 * core/vendor-common/bin/test-napps-action-java.sh. args[0]: a UTF-8 file holding the three h49 #1 strings the suite
 * extracts from docs/product-decisions.md, one per line -- the button, the grey line, and the status with "<App>" as
 * the app. A file, not three arguments: argument decoding follows the locale, and the strings hold U+00B7 and U+2026.
 */
public class NappsActionCases {
    static int failed, run;

    static void eq(String what, Object want, Object got) {
        run++;
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + want + ", got " + got);
        }
    }

    static final String CERT = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    public static void main(String[] args) throws Exception {
        java.util.List<String> a = args.length == 1
                ? java.nio.file.Files.readAllLines(java.nio.file.Paths.get(args[0]), java.nio.charset.StandardCharsets.UTF_8)
                : java.util.Collections.<String>emptyList();
        if (a.size() != 3) { System.out.println("FAIL usage: <file of three h49 #1 lines>"); System.exit(1); }
        NappsAction.State GET = NappsAction.State.GET, DOWNLOAD = NappsAction.State.DOWNLOAD,
                UPDATE = NappsAction.State.UPDATE, ADDED = NappsAction.State.ADDED;

        // C1: h49 #1 verbatim, against the decision record's own text.
        eq("C1 Download label = h49", a.get(0), NappsAction.label(DOWNLOAD));
        eq("C1 grey line = h49", a.get(1), NappsAction.GREY);
        eq("C1 status = h49", a.get(2), NappsAction.downloadingStatus("<App>"));

        // C2: every state. state(hasCode, archivedHere, haveVc, catalogVc, sameSigner)
        eq("C2 absent -> Get", GET, NappsAction.state(false, false, -1, 10, true));
        eq("C2 absent, no catalog version -> Get", GET, NappsAction.state(false, false, -1, 0, false));
        eq("C2 installed, catalog equal -> Added", ADDED, NappsAction.state(true, false, 10, 10, true));
        eq("C2 installed, catalog older -> Added", ADDED, NappsAction.state(true, false, 10, 9, true));
        eq("C2 installed, newer, other signer -> Added", ADDED, NappsAction.state(true, false, 10, 11, false));
        eq("C2 installed, no catalog version -> Added", ADDED, NappsAction.state(true, false, 10, 0, true));
        eq("C2 installed, newer, same signer -> Update", UPDATE, NappsAction.state(true, false, 10, 11, true));
        eq("C2 archived, catalog equal -> Download", DOWNLOAD, NappsAction.state(false, true, 10, 10, true));
        eq("C2 archived, catalog older -> Download", DOWNLOAD, NappsAction.state(false, true, 10, 9, true));
        eq("C2 archived, newer, other signer -> Download", DOWNLOAD, NappsAction.state(false, true, 10, 11, false));
        eq("C2 archived, version 0, newer same signer -> Download", DOWNLOAD, NappsAction.state(false, true, 0, 11, true));
        eq("C2 archived, version -1, newer same signer -> Download", DOWNLOAD, NappsAction.state(false, true, -1, 11, true));
        eq("C2 archived, newer, same signer -> Update", UPDATE, NappsAction.state(false, true, 10, 11, true));
        eq("C2 code wins over archived", ADDED, NappsAction.state(true, true, 10, 10, true));

        // C3: labels.
        eq("C3 Get", "Get", NappsAction.label(GET));
        eq("C3 Download", "Download", NappsAction.label(DOWNLOAD));
        eq("C3 Update", "Update", NappsAction.label(UPDATE));
        eq("C3 Added", "Added", NappsAction.label(ADDED));

        // C4: the grey line.
        eq("C4 Download", NappsAction.GREY, NappsAction.greyLine(DOWNLOAD, true));
        eq("C4 Update of an archived app", NappsAction.GREY, NappsAction.greyLine(UPDATE, true));
        eq("C4 Update of an installed app", null, NappsAction.greyLine(UPDATE, false));
        eq("C4 Get", null, NappsAction.greyLine(GET, false));
        eq("C4 Added", null, NappsAction.greyLine(ADDED, false));

        // C5: sameSigner and certHex.
        java.util.List<String> have = java.util.Arrays.asList("ff", CERT);
        eq("C5 match", true, NappsAction.sameSigner(CERT, have));
        eq("C5 match, case ignored", true, NappsAction.sameSigner(CERT.toUpperCase(), have));
        eq("C5 no match", false, NappsAction.sameSigner(CERT.replace('0', '1'), have));
        eq("C5 null pin", false, NappsAction.sameSigner(null, have));
        eq("C5 empty pin", false, NappsAction.sameSigner("", have));
        eq("C5 63 hex", false, NappsAction.sameSigner(CERT.substring(1), java.util.Arrays.asList(CERT.substring(1))));
        eq("C5 not hex", false, NappsAction.sameSigner(CERT.replace('a', 'g'), java.util.Arrays.asList(CERT.replace('a', 'g'))));
        eq("C5 no signers", false, NappsAction.sameSigner(CERT, java.util.Collections.<String>emptyList()));
        eq("C5 null signers", false, NappsAction.sameSigner(CERT, null));
        eq("C5 certHex of \"abc\"", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                NappsAction.certHex("abc".getBytes(java.nio.charset.StandardCharsets.US_ASCII)));

        System.out.println(run + " cases, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
