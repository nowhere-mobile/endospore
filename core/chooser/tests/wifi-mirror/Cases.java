package com.nowhere.chooser;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;

/** NWP-20261015-31: the WIFI-MIRROR line format, encoder and parser, and the two call sites that must use them. */
public final class Cases {
    private static int failed = 0;

    private static void check(String what, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failed++;
    }

    private static void eq(String what, String got, String want) {
        boolean ok = want == null ? got == null : want.equals(got);
        check(what + (ok ? "" : " (got " + (got == null ? "null" : "\"" + got.replace("\t", "\\t") + "\"") + ")"), ok);
    }

    private static boolean has(String text, String needle) { return text.contains(needle); }

    public static void main(String[] a) throws Exception {
        eq("quoted PSK, mode 0", WifiMirrorLine.encode("\"Home\"", "\"pw\"", 0), "Home\tpw\t0");
        eq("mode -1 omits the field", WifiMirrorLine.encode("\"Home\"", "\"pw\"", -1), "Home\tpw");
        eq("open network, mode -1", WifiMirrorLine.encode("\"Cafe\"", null, -1), "Cafe\t");
        eq("open network, empty PSK, mode -1", WifiMirrorLine.encode("\"Cafe\"", "", -1), "Cafe\t");
        eq("open network, mode 0", WifiMirrorLine.encode("\"Cafe\"", null, 0), "Cafe\t\t0");
        eq("raw-hex PSK is skipped", WifiMirrorLine.encode("\"Home\"", "0123456789abcdef", 0), null);
        eq("tab in SSID is skipped", WifiMirrorLine.encode("\"Ho\tme\"", "\"pw\"", 0), null);
        eq("newline in SSID is skipped", WifiMirrorLine.encode("\"Ho\nme\"", "\"pw\"", 0), null);
        eq("newline in PSK is skipped", WifiMirrorLine.encode("\"Home\"", "\"p\nw\"", 0), null);
        eq("empty SSID is skipped", WifiMirrorLine.encode("\"\"", "\"pw\"", 0), null);

        for (int mode : new int[] {0, 1, 100, -1}) {
            String line = WifiMirrorLine.encode("\"Home\"", "\"pw\"", mode);
            String[] p = WifiMirrorLine.parse(line);
            String want = mode >= 0 ? String.valueOf(mode) : "";
            check("round trip mode " + mode + (mode < 0 ? " (absent field)" : ""),
                    p != null && p.length == 3 && p[0].equals("Home") && p[1].equals("pw") && p[2].equals(want));
        }
        String[] open = WifiMirrorLine.parse(WifiMirrorLine.encode("\"Cafe\"", "", 0));
        check("open network round trip keeps the mode", open != null && open[0].equals("Cafe") && open[1].isEmpty() && open[2].equals("0"));
        check("parse rejects a one-field line", WifiMirrorLine.parse("Home") == null);
        check("parse rejects an empty SSID", WifiMirrorLine.parse("\tpw\t0") == null && WifiMirrorLine.parse("  \tpw") == null);
        check("parse keeps the SSID's and the PSK's edge spaces",
                Arrays.equals(WifiMirrorLine.parse(" Home \t pw \t 0 "), new String[] {" Home ", " pw ", "0"}));

        for (String[] rt : new String[][] {
                {"\"Bob's \"Den\"\"", "\"pw\"", "Bob's \"Den\"", "pw"},
                {"\"Home\"", "\"my \"home\" net \"", "Home", "my \"home\" net "},
                {"\" Lounge\"", "\"pw\"", " Lounge", "pw"}}) {
            String line = WifiMirrorLine.encode(rt[0], rt[1], 0);
            String[] p = line == null ? null : WifiMirrorLine.parse(line);
            check("round trip keeps quotes and edge spaces: " + rt[2] + " / " + rt[3],
                    p != null && p[0].equals(rt[2]) && p[1].equals(rt[3]) && p[2].equals("0"));
        }
        eq("unquoted (hex) SSID is skipped", WifiMirrorLine.encode("0123456789abcdef", "\"pw\"", 0), null);
        eq("lone quote SSID is skipped", WifiMirrorLine.encode("\"", "\"pw\"", 0), null);
        eq("tab in PSK is skipped", WifiMirrorLine.encode("\"Home\"", "\"p\tw\"", 0), null);
        eq("whitespace-only SSID is skipped", WifiMirrorLine.encode("\"  \"", "\"pw\"", 0), null);

        java.util.List<String[]> rep = WifiMirrorLine.parseReply(Arrays.asList("OK", "Cafe\t", "  ", "Home\t pw \t0"));
        check("parseReply keeps an open network's bare tab and the PSK's spaces",
                rep.size() == 2 && Arrays.equals(rep.get(0), new String[] {"Cafe", "", ""})
                        && Arrays.equals(rep.get(1), new String[] {"Home", " pw ", "0"}));
        check("parseReply without OK is empty", WifiMirrorLine.parseReply(Arrays.asList("NONE")).isEmpty()
                && WifiMirrorLine.parseReply(new java.util.ArrayList<String>()).isEmpty());
        eq("adoptRequest is the WIFI-ADOPT counts request", WifiMirrorLine.adoptRequest(0, 3, 1, 0),
                "WIFI-ADOPT\n0\n3\n1\n0\n");

        String wm = new String(Files.readAllBytes(Paths.get(a[0])), "UTF-8");
        String ca = new String(Files.readAllBytes(Paths.get(a[1])), "UTF-8");
        String ds = new String(Files.readAllBytes(Paths.get(a[2])), "UTF-8");
        check("WifiMirror.capture builds its lines with WifiMirrorLine.encode",
                has(wm, "WifiMirrorLine.encode(c.SSID, c.preSharedKey, c.macRandomizationSetting)"));
        check("maybeMirrorWifi reads the mirror untrimmed and parses it with WifiMirrorLine.parseReply",
                has(ca, "DaemonSocket.roundTripLinesRaw(\"GET-WIFI-MIRROR\\n\"") && has(ca, "WifiMirrorLine.parseReply(")
                        && !has(ca, "sendDaemonLines(\"GET-WIFI-MIRROR"));
        // NWP-20261020-31: the adopt log branches on the id, and each pass's counts are sent after the per-entry loop.
        int mm = ca.indexOf("void maybeMirrorWifi() {");
        int mmEnd = mm < 0 ? -1 : ca.indexOf("\n    }\n", mm);
        String mb = mmEnd < 0 ? "" : ca.substring(mm, mmEnd);
        int ifId = mb.indexOf("if (id >= 0) {"), adopted = mb.indexOf("wifi-mirror: adopted ");
        int els = ifId < 0 ? -1 : mb.indexOf("} else {", ifId), fail = mb.indexOf("wifi-mirror: adopt FAILED");
        check("maybeMirrorWifi logs \"adopted\" only inside if (id >= 0), and \"adopt FAILED\" in its else",
                ifId >= 0 && adopted > ifId && els > adopted && fail > els
                        && mb.indexOf("wifi-mirror: adopted ") == mb.lastIndexOf("wifi-mirror: adopted "));
        int req = mb.indexOf("WifiMirrorLine.adoptRequest(pass, added, present, failed)");
        check("maybeMirrorWifi sends WifiMirrorLine.adoptRequest after the per-entry loop", fail >= 0 && req > fail);
        int sig = ds.indexOf("static List<String> roundTripLinesRaw(");
        int end = sig < 0 ? -1 : ds.indexOf("\n    }\n", sig);
        String body = end < 0 ? "" : ds.substring(sig, end);
        check("roundTripLinesRaw adds the line as read and never trims it",
                !body.isEmpty() && has(body, "lines.add(line)") && !has(body, "line = line.trim()"));

        System.out.println(failed == 0 ? "all cases passed" : failed + " case(s) failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
