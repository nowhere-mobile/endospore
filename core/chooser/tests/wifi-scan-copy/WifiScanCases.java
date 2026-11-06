package com.nowhere.chooser;

/** wifiListStatus over all eight combinations of (networks 0/>0, connected, canScan). */
public final class WifiScanCases {
    static int fails = 0;

    static void eq(String what, String got, String want) {
        if (!want.equals(got)) { fails++; System.out.println("--- FAIL " + what + ": got \"" + got + "\" want \"" + want + "\""); }
    }

    public static void main(String[] a) {
        String retry = "can't scan for networks yet — tap to try again, or type the name below";
        eq("0 net, not connected, canScan", WifiScanCopy.wifiListStatus(0, false, true), "no networks found — type the name below");
        eq("0 net, connected, canScan", WifiScanCopy.wifiListStatus(0, true, true), "no other networks found");
        eq("3 net, not connected, canScan", WifiScanCopy.wifiListStatus(3, false, true), "tap a network, or type one below:");
        eq("3 net, connected, canScan", WifiScanCopy.wifiListStatus(3, true, true), "tap another network to switch, or type one below:");
        eq("0 net, not connected, !canScan", WifiScanCopy.wifiListStatus(0, false, false), retry);
        eq("0 net, connected, !canScan", WifiScanCopy.wifiListStatus(0, true, false), retry);
        eq("3 net, not connected, !canScan", WifiScanCopy.wifiListStatus(3, false, false), "tap a network, or type one below:");
        eq("3 net, connected, !canScan", WifiScanCopy.wifiListStatus(3, true, false), "tap another network to switch, or type one below:");
        for (boolean c : new boolean[]{false, true}) {
            if (WifiScanCopy.wifiListStatus(0, c, false).contains("no networks found")) {
                fails++; System.out.println("--- FAIL !canScan 0-network text says \"no networks found\"");
            }
        }
        if (fails > 0) { System.out.println("FAILED " + fails); System.exit(1); }
        System.out.println("ok: 8 combinations");
    }
}
