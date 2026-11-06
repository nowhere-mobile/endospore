package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/** Cases for WifiNetMatch (NWP-20261116-18), compiled with it by core/vendor-common/bin/test-wifi-netmatch-java.sh. */
public final class WifiNetMatchCases {
    private static int fails = 0;

    private static void eq(String name, Object want, Object got) {
        if (want.equals(got)) {
            System.out.println("  ok    " + name);
        } else {
            System.out.println("  FAIL  " + name + ": want " + want + ", got " + got);
            fails++;
        }
    }

    private static List<String[]> saved(String[]... es) {
        List<String[]> l = new ArrayList<>();
        for (String[] e : es) l.add(e);
        return l;
    }

    public static void main(String[] args) {
        eq("secOf eap+psk is eap", "eap", WifiNetMatch.secOf(true, true, false));
        eq("secOf eap alone is eap", "eap", WifiNetMatch.secOf(true, false, false));
        eq("secOf psk+sae is psk (a WPA2/WPA3 transition config)", "psk", WifiNetMatch.secOf(false, true, true));
        eq("secOf psk alone is psk", "psk", WifiNetMatch.secOf(false, true, false));
        eq("secOf sae alone is sae", "sae", WifiNetMatch.secOf(false, false, true));
        eq("secOf none is open", "open", WifiNetMatch.secOf(false, false, false));

        eq("joinSec identity + pw is eap", "eap", WifiNetMatch.joinSec("pw", "alice"));
        eq("joinSec identity + empty pw is eap", "eap", WifiNetMatch.joinSec("", "alice"));
        eq("joinSec empty pw, empty identity is open", "open", WifiNetMatch.joinSec("", ""));
        eq("joinSec null pw is open", "open", WifiNetMatch.joinSec(null, ""));
        eq("joinSec pw, empty identity is psk", "psk", WifiNetMatch.joinSec("pw", ""));
        eq("joinSec pw, null identity is psk", "psk", WifiNetMatch.joinSec("pw", null));

        eq("find: the same SSID under another sec is -1", -1,
                WifiNetMatch.find(saved(new String[]{"\"Cafe\"", "open", "3"}), "Cafe", "psk"));
        List<String[]> two = saved(new String[]{"\"Cafe\"", "open", "3"}, new String[]{"\"Cafe\"", "psk", "7"});
        eq("find: open first, psk second, asked psk gives the psk id", 7, WifiNetMatch.find(two, "Cafe", "psk"));
        eq("find: open first, psk second, asked open gives the open id", 3, WifiNetMatch.find(two, "Cafe", "open"));
        eq("find: an SSID with a space matches exactly", 5,
                WifiNetMatch.find(saved(new String[]{"\"My Cafe\"", "psk", "5"}), "My Cafe", "psk"));
        eq("find: a space is not dropped", -1,
                WifiNetMatch.find(saved(new String[]{"\"My Cafe\"", "psk", "5"}), "MyCafe", "psk"));
        eq("find: the compare is case-sensitive", -1,
                WifiNetMatch.find(saved(new String[]{"\"cafe\"", "psk", "5"}), "Cafe", "psk"));
        eq("find: a saved SSID without quotes does not match", -1,
                WifiNetMatch.find(saved(new String[]{"Cafe", "psk", "5"}), "Cafe", "psk"));
        eq("find: no entry gives -1", -1, WifiNetMatch.find(saved(), "Cafe", "psk"));
        eq("find: an unparseable netId is skipped", 9, WifiNetMatch.find(
                saved(new String[]{"\"Cafe\"", "psk", "x"}, new String[]{"\"Cafe\"", "psk", "9"}), "Cafe", "psk"));
        eq("find: a null or short entry is skipped", 4, WifiNetMatch.find(
                saved(null, new String[]{"\"Cafe\""}, new String[]{"\"Cafe\"", "psk", "4"}), "Cafe", "psk"));

        if (fails > 0) {
            System.out.println("  " + fails + " case(s) failed");
            System.exit(1);
        }
    }
}
