package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * The netpolicy Wi-Fi reset's pure rules (NWP-20261210-17). The decision is docs/product-decisions.md 2026-11-14,
 * "DECIDED: five answers to harvest 65 -- every recommendation accepted", item G06: the gate resets netpolicy's Wi-Fi
 * templates through the platform, and only those. NetPolicyReceiver is the glue; roamd calls it by explicit component.
 *
 * What stays: every policy whose template is not a Wi-Fi template -- the mobile and carrier templates, so the owner's
 * data limits and warnings. Per-uid background policy is not a network policy, so this reset never touches it. The
 * reset never reads, writes or deletes a file: it goes through NetworkPolicyManager only.
 *
 * Contract: action ACTION_RESET, no extras; result data exactly one of OK RESET <n> (n >= 1 Wi-Fi policies removed),
 * OK NONE (none present, nothing written), ERR-NP <reason> with the reason in REASONS.
 */
final class NetPolicyWifi {
    private NetPolicyWifi() {}

    static final String ACTION_RESET = "com.nowhere.chooser.action.NETPOLICY_WIFI_RESET";

    static final String OK_NONE = "OK NONE";
    static final String OK_RESET = "OK RESET";

    static final String R_USER = "user";
    static final String R_DENIED = "denied";
    static final String R_FAILED = "failed";
    static final String R_NOSERVICE = "noservice";
    static final Set<String> REASONS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            R_USER, R_DENIED, R_FAILED, R_NOSERVICE)));

    /** ERR-NP plus the reason; a reason outside REASONS is ERR-NP failed. */
    static String errLine(String r) {
        return "ERR-NP " + (REASONS.contains(r) ? r : R_FAILED);
    }

    /** One entry per policy, in order: true = keep (its match rule is not one of wifiRules). */
    static boolean[] keep(int[] matchRules, int[] wifiRules) {
        int n = matchRules == null ? 0 : matchRules.length;
        boolean[] k = new boolean[n];
        for (int i = 0; i < n; i++) {
            boolean wifi = false;
            if (wifiRules != null) {
                for (int w : wifiRules) {
                    if (matchRules[i] == w) { wifi = true; break; }
                }
            }
            k[i] = !wifi;
        }
        return k;
    }

    /** How many policies keep() drops. */
    static int removed(boolean[] keep) {
        int n = 0;
        if (keep != null) {
            for (boolean k : keep) if (!k) n++;
        }
        return n;
    }

    /** OK NONE when nothing was removed, else OK RESET <n>. */
    static String reply(int removed) {
        return removed <= 0 ? OK_NONE : OK_RESET + " " + removed;
    }
}
