package com.nowhere.chooser;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** Cases P1-P6 for NetPolicyWifi (NWP-20261210-17). Args: case names to run (none = all). Exit 1 on any failure. */
public class NetPolicyWifiCases {
    static int bad = 0;

    static void ok(String c, boolean cond, String what) {
        if (!cond) { bad++; System.out.println("--- FAIL: " + c + ": " + what); }
    }

    static final int MOBILE = 1, WIFI = 4, WILDCARD = 7, CARRIER = 10;

    public static void main(String[] a) {
        Set<String> only = new HashSet<>(Arrays.asList(a));
        if (only.isEmpty() || only.contains("P1")) {
            boolean[] k = NetPolicyWifi.keep(new int[] {MOBILE, WIFI, CARRIER, WIFI}, new int[] {WIFI, WILDCARD});
            ok("P1", Arrays.equals(k, new boolean[] {true, false, true, false}), "keep is [t,f,t,f], got " + Arrays.toString(k));
            ok("P1", NetPolicyWifi.removed(k) == 2, "removed is 2, got " + NetPolicyWifi.removed(k));
            ok("P1", "OK RESET 2".equals(NetPolicyWifi.reply(NetPolicyWifi.removed(k))), "reply is OK RESET 2");
            // P1's input keeps two and drops two, so a removed() that counted the kept would still say 2: count an
            // asymmetric vector too.
            ok("P1", NetPolicyWifi.removed(new boolean[] {true, false, true, true}) == 1, "removed counts only the dropped (1 of 4)");
        }
        if (only.isEmpty() || only.contains("P2")) {
            boolean[] k = NetPolicyWifi.keep(new int[] {MOBILE, CARRIER, MOBILE}, new int[] {WIFI, WILDCARD});
            ok("P2", Arrays.equals(k, new boolean[] {true, true, true}), "no Wi-Fi rule: all kept, got " + Arrays.toString(k));
            ok("P2", NetPolicyWifi.removed(k) == 0, "removed is 0");
            ok("P2", "OK NONE".equals(NetPolicyWifi.reply(NetPolicyWifi.removed(k))), "reply is OK NONE");
        }
        if (only.isEmpty() || only.contains("P3")) {
            boolean[] k = NetPolicyWifi.keep(new int[] {WIFI, WIFI, WILDCARD}, new int[] {WIFI, WILDCARD});
            ok("P3", Arrays.equals(k, new boolean[] {false, false, false}), "all Wi-Fi: none kept, got " + Arrays.toString(k));
            ok("P3", NetPolicyWifi.removed(k) == 3, "removed is 3");
            ok("P3", "OK RESET 3".equals(NetPolicyWifi.reply(NetPolicyWifi.removed(k))), "reply is OK RESET 3");
        }
        if (only.isEmpty() || only.contains("P4")) {
            boolean[] k = NetPolicyWifi.keep(new int[0], new int[] {WIFI});
            ok("P4", k.length == 0, "empty input: empty keep");
            ok("P4", NetPolicyWifi.removed(k) == 0, "empty input: removed is 0");
            ok("P4", "OK NONE".equals(NetPolicyWifi.reply(NetPolicyWifi.removed(k))), "empty input: reply is OK NONE");
        }
        if (only.isEmpty() || only.contains("P5")) {
            ok("P5", "ERR-NP failed".equals(NetPolicyWifi.errLine("bogus")), "unknown reason is ERR-NP failed");
            ok("P5", "ERR-NP failed".equals(NetPolicyWifi.errLine(null)), "null reason is ERR-NP failed");
            ok("P5", NetPolicyWifi.REASONS.equals(new HashSet<>(Arrays.asList("user", "denied", "failed", "noservice"))),
                    "REASONS is exactly {user, denied, failed, noservice}");
            for (String r : NetPolicyWifi.REASONS) {
                ok("P5", ("ERR-NP " + r).equals(NetPolicyWifi.errLine(r)), "reason " + r + " round-trips");
            }
            ok("P5", "com.nowhere.chooser.action.NETPOLICY_WIFI_RESET".equals(NetPolicyWifi.ACTION_RESET), "the action");
        }
        if (only.isEmpty() || only.contains("P6")) {
            boolean[] k = NetPolicyWifi.keep(new int[] {WILDCARD, MOBILE}, new int[] {WIFI, WILDCARD});
            ok("P6", Arrays.equals(k, new boolean[] {false, true}), "the wildcard rule is removed when listed, got " + Arrays.toString(k));
            boolean[] k2 = NetPolicyWifi.keep(new int[] {WILDCARD, MOBILE}, new int[] {WIFI});
            ok("P6", Arrays.equals(k2, new boolean[] {true, true}), "the wildcard rule stays when not listed");
        }
        if (bad == 0) System.out.println("netpolicy wifi cases passed");
        System.exit(bad == 0 ? 0 : 1);
    }
}
