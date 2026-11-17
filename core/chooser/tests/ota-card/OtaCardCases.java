package com.nowhere.chooser;

import java.nio.file.Files;
import java.nio.file.Paths;

// NWP-20261206-19: the cases for OtaCard -- when Install update shows, which OTA-APPLY replies started an install, and
// when the Software update screen keeps "Starting update…" (run.sh). args[0] = ChooserActivity.java: the Install
// listener, startInstall and renderOtaStatus's Install line are checked as source.
public final class OtaCardCases {
    static int fails = 0;

    static void check(String name, boolean ok, Object got) {
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static void shown(String name, String head, boolean want) {
        check("installShown: " + name, OtaCard.installShown(head) == want, OtaCard.installShown(head));
    }

    static void started(String name, String reply, boolean want) {
        check("applyStarted: " + name, OtaCard.applyStarted(reply) == want, OtaCard.applyStarted(reply));
    }

    static void hold(String name, String ar, String status, long ms, boolean want) {
        boolean got = OtaCard.holdStarting(ar, status, ms);
        check("hold: " + name, got == want, got);
    }

    public static void main(String[] a) throws Exception {
        shown("AVAIL", "AVAIL", true);
        shown("FAILED", "FAILED", true);
        shown("DOWNLOADING", "DOWNLOADING", false);
        shown("APPLYING", "APPLYING", false);
        shown("NONE", "NONE", false);
        shown("UNKNOWN", "UNKNOWN", false);
        shown("empty", "", false);
        shown("null", null, false);

        started("OK", "OK", true);
        started("BUSY", "BUSY", true);
        started("padded OK", " OK\n", true);
        started("empty", "", false);
        started("null", null, false);
        started("ERR", "ERR", false);
        started("OKAY", "OKAY", false);

        hold("OK over AVAIL at 0", "OK", "AVAIL 0.6.0", 0, true);
        hold("BUSY over empty at 59999", "BUSY", "", 59999, true);
        hold("OK over FAILED ERR-STALE", "OK", "FAILED ERR-STALE", 30000, true);
        hold("null status reads as empty", "OK", null, 0, true);
        hold("ends at HOLD_MS", "OK", "AVAIL 0.6.0", 60000, false);
        hold("negative elapsed", "OK", "AVAIL 0.6.0", -1, false);
        hold("empty apply reply", "", "AVAIL 0.6.0", 1000, false);
        hold("null apply reply", null, "AVAIL 0.6.0", 1000, false);
        hold("DOWNLOADING ends it", "OK", "DOWNLOADING", 1000, false);
        hold("APPLYING ends it", "OK", "APPLYING 0.6.0", 1000, false);
        hold("NONE ends it", "OK", "NONE", 1000, false);
        hold("UNKNOWN ends it", "OK", "UNKNOWN checking", 1000, false);
        hold("FAILED ERR-APPLY ends it", "OK", "FAILED ERR-APPLY", 1000, false);
        hold("FAILED ERR-CHECK ends it", "OK", "FAILED ERR-CHECK", 1000, false);
        check("HOLD_MS is 60 s", OtaCard.HOLD_MS == 60000, OtaCard.HOLD_MS);

        String src = new String(Files.readAllBytes(Paths.get(a[0])), "UTF-8");
        check("pin: the listener disables Install before its thread",
                src.contains("install.setOnClickListener(v -> {\n            install.setEnabled(false);\n            new Thread(() -> {"),
                "absent");

        int at = src.indexOf("install.setOnClickListener(");
        int end = at < 0 ? -1 : src.indexOf("TextView back = new TextView(this);", at);
        String l = at >= 0 && end > at ? src.substring(at, end) : "";
        check("pin: the confirm path re-enables Install",
                l.contains("install.setEnabled(true); // the dialog is modal: Cancel leaves Install usable\n"
                        + "                    confirmInstallOverParked(parsed, lost, startInstall);"),
                "absent");

        int sb = src.indexOf("final Runnable startInstall = () -> {");
        int se = sb < 0 ? -1 : src.indexOf("install.setOnClickListener(", sb);
        String s = sb >= 0 && se > sb ? src.substring(sb, se) : "";
        int ar = s.indexOf("final String ar = daemonCmd(\"OTA-APPLY\");");
        int hs = s.indexOf("OtaCard.holdStarting(ar, rp[0], android.os.SystemClock.uptimeMillis() - t0)");
        int dc = s.indexOf("doCheck.run();");
        check("pin: startInstall holds before doCheck", ar >= 0 && hs > ar && dc > hs, ar + "/" + hs + "/" + dc);

        int rb = src.indexOf("private void renderOtaStatus(");
        int re = rb < 0 ? -1 : src.indexOf("private static String otaApplyPhase(", rb);
        String r = rb >= 0 && re > rb ? src.substring(rb, re) : "";
        check("pin: renderOtaStatus asks OtaCard.installShown",
                r.contains("install.setVisibility(OtaCard.installShown(head) ? View.VISIBLE : View.GONE);")
                        && !r.contains("\"AVAIL\".equals(head) || \"FAILED\".equals(head)"),
                r.isEmpty() ? "renderOtaStatus not found" : "inline or absent");
        check("pin: a shown Install is enabled",
                r.contains("if (OtaCard.installShown(head)) install.setEnabled(true);"), "absent");

        System.out.println(fails == 0 ? "OK" : fails + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
