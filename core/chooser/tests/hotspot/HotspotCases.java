package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Random;
import java.util.Set;

/** Cases for Hotspot (NWP-20261028-08). Exit 1 on any failure. */
public class HotspotCases {
    static int bad = 0;

    static void ok(boolean c, String what) {
        if (!c) { bad++; System.out.println("--- FAIL: " + what); }
    }

    static String rep(String s, int n) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < n; i++) b.append(s);
        return b.toString();
    }

    public static void main(String[] a) {
        // validSsid
        ok(!Hotspot.validSsid(""), "empty ssid");
        ok(!Hotspot.validSsid(null), "null ssid");
        ok(Hotspot.validSsid(rep("a", 32)), "32 ascii bytes");
        ok(!Hotspot.validSsid(rep("a", 33)), "33 ascii bytes");
        ok(!Hotspot.validSsid(rep("€", 11)), "11 three-byte characters = 33 bytes");
        ok(Hotspot.validSsid(rep("€", 10)), "10 three-byte characters = 30 bytes");
        ok(!Hotspot.validSsid("ab\ncd"), "newline in ssid");
        ok(!Hotspot.validSsid("a\u007fb"), "0x7f in ssid");
        ok(Hotspot.validSsid("home 😀"), "emoji within 32 bytes");
        // validPassphrase
        ok(!Hotspot.validPassphrase(rep("a", 7)), "7 chars");
        ok(Hotspot.validPassphrase(rep("a", 8)), "8 chars");
        ok(Hotspot.validPassphrase(rep("a", 63)), "63 chars");
        ok(!Hotspot.validPassphrase(rep("a", 64)), "64 chars");
        ok(!Hotspot.validPassphrase("abcdefg\th"), "tab in passphrase");
        ok(!Hotspot.validPassphrase("abcdefgé"), "non-ASCII letter");
        ok(!Hotspot.validPassphrase(null), "null passphrase");
        ok(Hotspot.validPassphrase("a b c d e"), "spaces are allowed");
        // typeOf
        ok("wifi".equals(Hotspot.typeOf("wifi")), "typeOf wifi");
        ok("usb".equals(Hotspot.typeOf("usb")), "typeOf usb");
        ok("bluetooth".equals(Hotspot.typeOf("bluetooth")), "typeOf bluetooth");
        ok(Hotspot.typeOf("WIFI") == null && Hotspot.typeOf(" wifi") == null && Hotspot.typeOf("") == null
                && Hotspot.typeOf(null) == null, "typeOf refuses anything else");
        ok(Hotspot.types().equals(Arrays.asList("wifi", "usb", "bluetooth")), "type order");
        // mayStart
        ok(!Hotspot.mayStart(true, 0, 0), "the gate itself may not start");
        ok(!Hotspot.mayStart(false, 10, 10), "another app may not start");
        ok(!Hotspot.mayStart(true, 11, 10), "a background session may not start");
        ok(Hotspot.mayStart(true, 10, 10), "the foreground session may start");
        // mayStop
        ok(Hotspot.mayStop(true, 10, null), "stop with no owner");
        ok(Hotspot.mayStop(true, 10, 10), "stop own");
        ok(!Hotspot.mayStop(true, 10, 11), "stop another's");
        ok(!Hotspot.mayStop(false, 10, null), "other app stop");
        ok(!Hotspot.mayStop(true, 0, null), "gate stop");
        // releaseDecision
        ok(Hotspot.releaseDecision(11, -1) == Hotspot.Release.RELEASE, "uid -1 releases");
        ok(Hotspot.releaseDecision(null, 10) == Hotspot.Release.RELEASE, "unknown owner releases");
        ok(Hotspot.releaseDecision(10, 10) == Hotspot.Release.RELEASE, "own releases");
        ok(Hotspot.releaseDecision(11, 10) == Hotspot.Release.KEEP, "another owner's is kept");
        // reset values
        Random r = new Random(1);
        Set<Character> seen = new HashSet<>();
        for (int i = 0; i < 1000; i++) {
            String s = Hotspot.resetSsid(r), p = Hotspot.resetPassphrase(r);
            ok(s.matches("AndroidAP_[0-9]{4}"), "reset ssid shape " + s);
            ok(p.matches("[A-Za-z0-9]{16}"), "reset passphrase shape");
            for (char c : p.toCharArray()) seen.add(c);
        }
        ok(seen.size() == 62, "the reset passphrase draws from all 62 characters, saw " + seen.size());
        ok(!(Hotspot.resetSsid(new Random(1)) + Hotspot.resetPassphrase(new Random(1)))
                .equals(Hotspot.resetSsid(new Random(2)) + Hotspot.resetPassphrase(new Random(2))),
                "two seeds give different values");
        // offered
        ok(Hotspot.offered("STORED", false), "STORED online");
        ok(!Hotspot.offered("STORED", true), "STORED offline");
        ok(!Hotspot.offered("LOCAL", false), "LOCAL");
        ok(!Hotspot.offered("", false), "empty type");
        ok(!Hotspot.offered(null, false), "null type");
        // configText / parseConfig
        String t = Hotspot.configText("home", "secret123");
        ok("ssid=home\npass=secret123\n".equals(t), "configText text");
        String[] rt = Hotspot.parseConfig(t);
        ok("home".equals(rt[0]) && "secret123".equals(rt[1]), "round trip");
        ok(Hotspot.configText("", "secret123") == null && Hotspot.configText("home", "short") == null,
                "configText refuses invalid values");
        String[] cr = Hotspot.parseConfig("ssid=a\r\npass=12345678\r\n");
        ok("a".equals(cr[0]) && "12345678".equals(cr[1]), "CR stripped");
        String[] dup = Hotspot.parseConfig("ssid=first\nssid=second\npass=12345678\n");
        ok("first".equals(dup[0]), "first duplicate wins");
        String[] dupBad = Hotspot.parseConfig("ssid=" + rep("a", 33) + "\nssid=good\npass=12345678\n");
        ok(dupBad[0] == null && "12345678".equals(dupBad[1]), "invalid first ssid reads absent and is not replaced");
        String[] bad33 = Hotspot.parseConfig("ssid=" + rep("a", 33) + "\npass=12345678\n");
        ok(bad33[0] == null && "12345678".equals(bad33[1]), "invalid ssid absent, pass still read");
        String[] nul = Hotspot.parseConfig(null), emp = Hotspot.parseConfig("");
        ok(nul[0] == null && nul[1] == null && emp[0] == null && emp[1] == null, "null and empty text");
        // reply lines
        ok("OK ON wifi".equals(Hotspot.okOn("wifi")), "okOn");
        ok("OK OFF usb".equals(Hotspot.okOff("usb")), "okOff");
        ok("STATE wifi=1 usb=0 bluetooth=1".equals(Hotspot.stateLine(true, false, true)), "stateLine");
        for (String re : new String[] {"user", "caller", "type", "ssid", "passphrase", "config", "failed", "timeout",
                "denied", "reset"}) {
            ok(("ERR-HS " + re).equals(Hotspot.errLine(re)), "errLine " + re);
        }
        ok("ERR-HS failed".equals(Hotspot.errLine("nope")) && "ERR-HS failed".equals(Hotspot.errLine(null)),
                "errLine refuses an unlisted reason");
        ok("OK RELEASED".equals(Hotspot.OK_RELEASED) && "OK KEPT".equals(Hotspot.OK_KEPT), "release replies");
        ok(Hotspot.START == 1 && Hotspot.STOP == 2 && Hotspot.STATE == 3, "codes");
        ok("com.nowhere.chooser.action.HOTSPOT_RELEASE".equals(Hotspot.ACTION_RELEASE)
                && "uid".equals(Hotspot.EXTRA_UID), "action and extra");
        // anyMatches
        ok(Hotspot.anyMatches(Arrays.asList("wlan1"), Arrays.asList("wlan\\d")), "wlan1");
        ok(Hotspot.anyMatches(Arrays.asList("rndis0"), Arrays.asList("rndis\\d", "ncm\\d")), "rndis0");
        ok(!Hotspot.anyMatches(Collections.<String>emptyList(), Arrays.asList("wlan\\d")), "no interfaces");
        ok(!Hotspot.anyMatches(null, Arrays.asList("wlan\\d")) && !Hotspot.anyMatches(Arrays.asList("x"), null),
                "null lists");
        ok(Hotspot.anyMatches(Arrays.asList("ncm0"), Arrays.asList("[", "ncm\\d")), "a bad regex is skipped");
        // TetherCache: stale / regexp-only events never confirm a stop
        Hotspot.TetherCache c = new Hotspot.TetherCache();
        ok(c.isOn("usb") && c.isOn("bluetooth"), "unreported cache reads ON");
        c.onRegexs(Arrays.asList("rndis\\d"), Arrays.asList("bt-pan"));
        ok(c.isOn("usb"), "regexps alone: still unknown, ON");
        c.onIfaces(Collections.<String>emptyList());
        ok(!c.isOn("usb"), "both reported, nothing tethered: off");
        int m = c.mark();
        c.onRegexs(Arrays.asList("rndis\\d"), Arrays.asList("bt-pan"));
        ok(!c.stopConfirmed("usb", m) && !c.stopConfirmed("bluetooth", m), "a regexp event is not a stop confirmation");
        c.onIfaces(Collections.<String>emptyList());
        ok(c.stopConfirmed("usb", m), "a fresh interface event with nothing tethered confirms");
        c.onIfaces(Arrays.asList("rndis0"));
        int m2 = c.mark();
        ok(!c.stopConfirmed("usb", m2), "no event since the mark: not confirmed");
        c.onIfaces(Arrays.asList("rndis0"));
        ok(!c.stopConfirmed("usb", m2), "a fresh event still showing it on is not confirmation");
        // toast / switchOn (NWP-20261028-11)
        String[] types = {"wifi", "usb", "bluetooth"};
        String[] labels = {"Wi-Fi hotspot", "USB tethering", "Bluetooth tethering"};
        String ssid = "PlantedSsid-Zq", pw = "PlantedPass-Zq7!";
        for (int i = 0; i < 3; i++) {
            String ty = types[i], l = labels[i];
            ok(l.equals(Hotspot.label(ty)), "label of " + ty);
            ok((l + " on — only while you're signed in to this profile").equals(Hotspot.toast(ty, true, Hotspot.okOn(ty))),
                    "toast OK ON " + ty);
            ok((l + " off").equals(Hotspot.toast(ty, false, Hotspot.okOff(ty))), "toast OK OFF " + ty);
            ok("Couldn't change this — this profile isn't the one in front.".equals(
                    Hotspot.toast(ty, true, "ERR-HS caller")), "toast caller on " + ty);
            ok("Couldn't change this — this profile isn't the one in front.".equals(
                    Hotspot.toast(ty, false, "ERR-HS caller")), "toast caller off " + ty);
            // A timeout or no reply at all is "didn't answer" (NWP-20261113-07); every other ERR-HS "didn't confirm it".
            for (String rp : new String[]{"ERR-HS timeout", "", null}) {
                ok(("Couldn't turn " + l + " on — the phone didn't answer. Try again.").equals(Hotspot.toast(ty, true, rp)),
                        "toast no answer on " + ty + " " + rp);
                ok(("Couldn't turn " + l + " off — the phone didn't answer. Try again.").equals(Hotspot.toast(ty, false, rp)),
                        "toast no answer off " + ty + " " + rp);
            }
            ok(Hotspot.toast(ty, true, "ERR-HS timeout").equals(Hotspot.toast(ty, true, Hotspot.errLine(Hotspot.R_TIMEOUT))),
                    "the timeout literal is errLine(R_TIMEOUT) " + ty);
            for (String rp : new String[]{"ERR-HS failed", "ERR-HS user", "ERR-HS type", "ERR-HS ssid",
                    "ERR-HS passphrase", "ERR-HS config", "ERR-HS denied", "ERR-HS reset"}) {
                ok(("Couldn't turn " + l + " on — the phone didn't confirm it. Try again.").equals(Hotspot.toast(ty, true, rp)),
                        "toast unconfirmed on " + ty + " " + rp);
                ok(("Couldn't turn " + l + " off — the phone didn't confirm it. Try again.").equals(Hotspot.toast(ty, false, rp)),
                        "toast unconfirmed off " + ty + " " + rp);
            }
            ok(Hotspot.toast(ty, true, Hotspot.okOff(ty)).startsWith("Couldn't turn"), "an OFF reply to an ON tap is unconfirmed");
            ok(Hotspot.toast(ty, false, Hotspot.okOn(ty)).startsWith("Couldn't turn"), "an ON reply to an OFF tap is unconfirmed");
            for (String rp : new String[]{Hotspot.okOn(ty), Hotspot.okOff(ty), "ERR-HS caller", "ERR-HS failed", "", null,
                    "OK ON " + ssid + " " + pw}) {
                for (boolean w : new boolean[]{true, false}) {
                    String x = Hotspot.toast(ty, w, rp);
                    ok(!x.contains(ssid) && !x.contains(pw), "a toast never carries the name or passphrase: " + rp);
                }
            }
        }
        // switchOn
        String st = "STATE wifi=1 usb=0 bluetooth=0";
        ok(Hotspot.switchOn(st, "wifi") && !Hotspot.switchOn(st, "usb") && !Hotspot.switchOn(st, "bluetooth"), "switchOn wifi=1");
        ok(!Hotspot.switchOn("STATE wifi=0 usb=0 bluetooth=0", "wifi"), "switchOn wifi=0 is off");
        ok(Hotspot.switchOn("STATE wifi=0 usb=0 bluetooth=1", "bluetooth"), "switchOn bluetooth=1");
        ok(!Hotspot.switchOn("STATE wifi=1 usb=1", "bluetooth"), "a missing type is off");
        ok(!Hotspot.switchOn("garbage wifi=1", "wifi") && !Hotspot.switchOn("", "wifi") && !Hotspot.switchOn(null, "wifi")
                && !Hotspot.switchOn("ERR-HS user", "wifi") && !Hotspot.switchOn(st, null) && !Hotspot.switchOn("STATE wifi=11", "wifi"),
                "a malformed line is off");
        ok(Hotspot.switchOn(Hotspot.stateLine(true, false, true), "bluetooth") && !Hotspot.switchOn(Hotspot.stateLine(true, false, true), "usb"),
                "stateLine round trip");
        if (bad > 0) { System.out.println(bad + " case(s) failed"); System.exit(1); }
        System.out.println("hotspot cases passed");
    }
}
