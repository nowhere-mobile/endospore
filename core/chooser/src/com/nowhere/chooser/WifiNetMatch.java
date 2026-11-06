package com.nowhere.chooser;

import java.util.List;

/** Which saved Wi-Fi network a gate join may reuse, decided apart from WifiManager (NWP-20261116-18,
 *  docs/wifi-retention-spec.md §5 F2). Pure java.lang/java.util so it runs under plain javac
 *  (core/vendor-common/bin/test-wifi-netmatch-java.sh). Android keys a saved config on (SSID, security type), so an
 *  open "Cafe" and a WPA2 "Cafe" are two networks; matching on SSID alone let a join of one overwrite the other.
 *  A security type is one of "open", "psk", "sae", "eap" (spec §2.4). */
final class WifiNetMatch {
    private WifiNetMatch() {}

    /** The security type of a saved config, from its allowedKeyManagement bits. PSK is tested before SAE, so a
     *  WPA2/WPA3 transition config that carries both bits reads "psk": that order is an inference about how the
     *  platform stores a transition network, and the device check confirms it. */
    static String secOf(boolean eap, boolean psk, boolean sae) {
        if (eap) return "eap";
        if (psk) return "psk";
        if (sae) return "sae";
        return "open";
    }

    /** The security type connectWifi builds for a join, in its own branch order: an identity is WPA-EAP, an empty
     *  password is open (KeyMgmt.NONE), any other password is a PSK. */
    static String joinSec(String pw, String identity) {
        if (identity != null && !identity.isEmpty()) return "eap";
        if (pw == null || pw.isEmpty()) return "open";
        return "psk";
    }

    /** The netId of the first saved entry {quotedSsid, sec, netId} whose quoted SSID equals "\"" + ssid + "\"" and
     *  whose sec equals sec, else -1. An entry that is null, short, or has an unparseable netId is skipped. */
    static int find(List<String[]> saved, String ssid, String sec) {
        if (saved == null || ssid == null || sec == null) return -1;
        String q = "\"" + ssid + "\"";
        for (String[] e : saved) {
            if (e == null || e.length < 3) continue;
            if (q.equals(e[0]) && sec.equals(e[1])) {
                try {
                    return Integer.parseInt(e[2]);
                } catch (NumberFormatException ignore) {
                    // skipped: a later entry may still match
                }
            }
        }
        return -1;
    }
}
