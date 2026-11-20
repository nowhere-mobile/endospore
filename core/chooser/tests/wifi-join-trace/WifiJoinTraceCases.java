package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261207-15: the cases for WifiJoinTrace, run by core/vendor-common/bin/test-wifi-join-trace-java.sh.
 *  args[0] is core/agent/gate_log.go, whose closed verb and key sets must hold every name WifiJoinTrace sends. */
public final class WifiJoinTraceCases {
    static int bad = 0;

    static void eq(String id, String what, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        bad++;
    }

    static Map<String, Integer> scan(Object... kv) {
        Map<String, Integer> m = new HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], (Integer) kv[i + 1]);
        return m;
    }

    public static void main(String[] a) {
        int b0 = bad;
        eq("C1", "apClass([ESS])", 1, WifiJoinTrace.apClass("[ESS]"));
        eq("C1", "apClass(psk)", 2, WifiJoinTrace.apClass("[WPA2-PSK-CCMP][ESS]"));
        eq("C1", "apClass(psk+sae transition)", 3, WifiJoinTrace.apClass("[WPA2-PSK-CCMP][RSN-PSK+SAE-CCMP][ESS]"));
        eq("C1", "apClass(sae only)", 4, WifiJoinTrace.apClass("[RSN-SAE-CCMP][ESS]"));
        eq("C1", "apClass(eap)", 5, WifiJoinTrace.apClass("[RSN-EAP-CCMP][ESS]"));
        eq("C1", "apClass(owe)", 6, WifiJoinTrace.apClass("[RSN-OWE-CCMP][ESS]"));
        eq("C1", "apClass(wep)", 7, WifiJoinTrace.apClass("[WEP][ESS]"));
        eq("C1", "apClass(null)", 0, WifiJoinTrace.apClass(null));
        if (bad == b0) System.out.println("ok C1 apClass reads open, psk, transition, sae only, eap, owe, other and null");

        b0 = bad;
        eq("C2", "joinCode(open)", 1, WifiJoinTrace.joinCode("open"));
        eq("C2", "joinCode(psk)", 2, WifiJoinTrace.joinCode("psk"));
        eq("C2", "joinCode(eap)", 3, WifiJoinTrace.joinCode("eap"));
        eq("C2", "joinCode(\"\")", 0, WifiJoinTrace.joinCode(""));
        eq("C2", "joinCode(null)", 0, WifiJoinTrace.joinCode(null));
        WifiJoinTrace.rememberScan(scan("lab", 4));
        eq("C2", "code(reused, psk, an sae-only AP)", 124, WifiJoinTrace.code(true, "psk", "lab"));
        eq("C2", "code(new, open, unscanned)", 10, WifiJoinTrace.code(false, "open", "unscanned"));
        eq("C2", "code(new, eap, an sae-only AP)", 34, WifiJoinTrace.code(false, "eap", "lab"));
        eq("C2", "code(reused, open, unscanned)", 110, WifiJoinTrace.code(true, "open", "unscanned"));
        if (bad == b0) System.out.println("ok C2 joinCode and code: hundreds reused, tens joinCode, units apFor");

        b0 = bad;
        WifiJoinTrace.rememberScan(scan("a", 2, "b", 4));
        eq("C3", "apFor(a) after the first scan", 2, WifiJoinTrace.apFor("a"));
        WifiJoinTrace.rememberScan(scan("b", 3));
        eq("C3", "apFor(a) after a scan without a", 0, WifiJoinTrace.apFor("a"));
        eq("C3", "apFor(b) after the second scan", 3, WifiJoinTrace.apFor("b"));
        WifiJoinTrace.rememberScan(scan());
        eq("C3", "apFor(b) after an empty scan", 0, WifiJoinTrace.apFor("b"));
        WifiJoinTrace.rememberScan(scan("b", 3));
        try {
            WifiJoinTrace.rememberScan(null);
            eq("C3", "apFor(b) after a null scan", 0, WifiJoinTrace.apFor("b"));
        } catch (Throwable t) {
            eq("C3", "rememberScan(null) does not throw", "no throw", t.toString());
        }
        eq("C3", "apFor(null)", 0, WifiJoinTrace.apFor(null));
        if (bad == b0) System.out.println("ok C3 rememberScan replaces the whole map, never merges");

        b0 = bad;
        String go = null;
        try {
            go = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        } catch (Throwable t) {
            eq("C4", "read gate_log.go", "readable", t.toString());
        }
        if (go != null) {
            Matcher vm = Pattern.compile("(?s)var gateLogVerbs = map\\[string\\]bool\\{(.*?)\\n\\}").matcher(go);
            Matcher km = Pattern.compile("var gateLogKeys = map\\[string\\]bool\\{([^\\n]*)\\}").matcher(go);
            String verbs = vm.find() ? vm.group(1) : "";
            String keys = km.find() ? km.group(1) : "";
            eq("C4", "gateLogVerbs found", true, !verbs.isEmpty());
            eq("C4", "gateLogKeys found", true, !keys.isEmpty());
            for (String v : new String[]{WifiJoinTrace.OK, WifiJoinTrace.ASSOC, WifiJoinTrace.NOASSOC,
                    WifiJoinTrace.ADDFAIL, WifiJoinTrace.NOWIFI, WifiJoinTrace.ERR}) {
                eq("C4", "\"" + v + "\": true in gateLogVerbs", true, verbs.contains("\"" + v + "\": true"));
            }
            eq("C4", "\"sec\": true in gateLogKeys", true, keys.contains("\"sec\": true"));
        }
        eq("C4", "KEY", "sec", WifiJoinTrace.KEY);
        eq("C4", "OK", "wifi-join-ok", WifiJoinTrace.OK);
        eq("C4", "ASSOC", "wifi-join-assoc", WifiJoinTrace.ASSOC);
        eq("C4", "NOASSOC", "wifi-join-noassoc", WifiJoinTrace.NOASSOC);
        eq("C4", "ADDFAIL", "wifi-join-addfail", WifiJoinTrace.ADDFAIL);
        eq("C4", "NOWIFI", "wifi-join-nowifi", WifiJoinTrace.NOWIFI);
        eq("C4", "ERR", "wifi-join-err", WifiJoinTrace.ERR);
        if (bad == b0) System.out.println("ok C4 every verb and the sec key are in gate_log.go's closed sets");

        System.exit(bad == 0 ? 0 : 1);
    }
}
