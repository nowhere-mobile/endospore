package com.nowhere.chooser;

/** The status line of the setup Wi-Fi screen (NWP-20261020-29). Pure java.lang so it runs under plain javac
 *  (core/vendor-common/bin/test-wifi-scan-copy-java.sh). The point is the one line it must never say: "no
 *  networks found" when the screen could not scan at all (no fine location, location off, or Wi-Fi off) -- an
 *  empty list then means "not able to yet", and the owner is told so and can re-run the scan. */
final class WifiScanCopy {
    private WifiScanCopy() {}

    static String wifiListStatus(int networks, boolean connected, boolean canScan) {
        if (!canScan && networks == 0) {
            return "can't scan for networks yet — tap to try again, or type the name below";
        }
        if (networks == 0) {
            return connected ? "no other networks found" : "no networks found — type the name below";
        }
        return connected ? "tap another network to switch, or type one below:"
                         : "tap a network, or type one below:";
    }
}
