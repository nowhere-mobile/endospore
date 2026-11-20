package com.nowhere.chooser;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/** NWP-20261207-15: evidence for the backlog row "The gate may be unable to join a WPA3-SAE-only AP at all"
 *  (docs/wifi-retention-spec.md L6, hardware check HW4). Every gate Wi-Fi join writes ONE gate.log line through
 *  GateTrace: an outcome verb below and KEY=code(...), so a gate report filed after a WPA3-only join says whether
 *  it worked. Pure java.util so it runs under plain javac (core/vendor-common/bin/test-wifi-join-trace-java.sh).
 *
 *  <p>⚠ THE SSID NEVER LEAVES THIS PROCESS. The scan map lives in RAM and dies with the chooser process. Nothing
 *  here is written, logged or sent: only a verb constant and one integer leave this class, and gate.log's closed
 *  grammar (core/agent/gate_log.go) could not carry a network name anyway.
 *
 *  <p>Known limit: a scan that returns null or throws leaves the previous scan's map in place. */
final class WifiJoinTrace {
    private WifiJoinTrace() {}

    static final String OK = "wifi-join-ok";           // validated or internet
    static final String ASSOC = "wifi-join-assoc";     // associated, not validated in the window
    static final String NOASSOC = "wifi-join-noassoc"; // never associated
    static final String ADDFAIL = "wifi-join-addfail"; // addNetwork refused and no saved entry matched
    static final String NOWIFI = "wifi-join-nowifi";   // no Wi-Fi service
    static final String ERR = "wifi-join-err";         // the join threw
    static final String KEY = "sec";

    // SSID -> apClass of the newest scan. Immutable and replaced whole, so a reader sees one whole scan.
    private static volatile Map<String, Integer> last = Collections.emptyMap();

    /** The AP's advertised security from ScanResult.capabilities: 0 null, 1 open, 2 psk, 3 psk+sae, 4 sae only,
     *  5 eap / suite-b, 6 owe, 7 other (wep, or a WPA/RSN element with no key management recognised here). The
     *  order is load-bearing: EAP first, then SAE before PSK so a transition AP reads 3 and an SAE-only AP 4. */
    static int apClass(String caps) {
        if (caps == null) return 0;
        if (caps.contains("EAP") || caps.contains("SUITE-B") || caps.contains("SUITE_B")) return 5;
        if (caps.contains("SAE")) return caps.contains("PSK") ? 3 : 4;
        if (caps.contains("PSK")) return 2;
        if (caps.contains("OWE")) return 6;
        if (caps.contains("WEP") || caps.contains("WPA") || caps.contains("RSN")) return 7;
        return 1;
    }

    /** Replace the whole map with the newest scan's SSID -> apClass. Never merges. */
    static void rememberScan(Map<String, Integer> scan) {
        last = scan == null ? Collections.<String, Integer>emptyMap()
                : Collections.unmodifiableMap(new HashMap<>(scan));
    }

    /** The class the gate's last scan saw for ssid, 0 when it did not see it. */
    static int apFor(String ssid) {
        if (ssid == null) return 0;
        Integer c = last.get(ssid);
        return c == null ? 0 : c;
    }

    /** How the gate configured the join (WifiNetMatch.joinSec): 1 open, 2 psk, 3 eap, 0 anything else. */
    static int joinCode(String joinSec) {
        if ("open".equals(joinSec)) return 1;
        if ("psk".equals(joinSec)) return 2;
        if ("eap".equals(joinSec)) return 3;
        return 0;
    }

    /** gate.log's `sec`: hundreds = reused a saved entry, tens = joinCode, units = apFor. */
    static int code(boolean reused, String joinSec, String ssid) {
        return (reused ? 100 : 0) + 10 * joinCode(joinSec) + apFor(ssid);
    }
}
