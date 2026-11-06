package com.nowhere.chooser;

/**
 * The contract of the gate's data-roaming write (NWP-20261028-06). The global settings key for data roaming is
 * inert on the device (docs/product-decisions.md, 2026-10-19, the hotspot entry's item 2), so roamd asks the gate's
 * chooser to write it through the telephony API and reads telephony's own record back. DataRoamingReceiver does the
 * platform work; the strings roamd parses are decided here.
 *
 * The receiver's ordered result DATA is one line: {@code OK sub=<n> data_roaming=<0|1>} (what siminfo holds AFTER
 * the step) or {@code ERR-DR <reason>}, the reason being one of user, arg, nosub, denied, failed, unreadable.
 *
 * Pure Java, no android.* import: core/chooser/test-data-roaming-java.sh compiles this file directly.
 */
final class DataRoaming {
    private DataRoaming() {}

    static final String ACTION = "com.nowhere.chooser.action.DATA_ROAMING";
    static final String EXTRA_OP = "op";
    static final String EXTRA_VALUE = "value";
    static final String EXTRA_SUB = "sub";
    static final String OP_GET = "get";
    static final String OP_SET = "set";

    /** Telephony applies a write on its own handler, so a read-back re-reads for at most this long. */
    static final long READBACK_MS = 3000;
    static final long READBACK_STEP_MS = 100;

    private static final String[] REASONS = {"user", "arg", "nosub", "denied", "failed", "unreadable"};

    /** "get", "set" (with a 0 or 1 value) or null for anything else. Case-sensitive. */
    static String parseOp(String op, boolean hasValue, int value) {
        if (OP_GET.equals(op)) return OP_GET;
        if (OP_SET.equals(op) && hasValue && (value == 0 || value == 1)) return OP_SET;
        return null;
    }

    /** The subscription to use: a positive extra, else a positive default, else -1. */
    static int pickSub(int extraSub, int defaultSub) {
        if (extraSub > 0) return extraSub;
        return defaultSub > 0 ? defaultSub : -1;
    }

    static String okLine(int sub, boolean roaming) {
        return "OK sub=" + sub + " data_roaming=" + (roaming ? 1 : 0);
    }

    /** An error line; a reason outside the contract's list is reported as "failed", never passed through. */
    static String errLine(String reason) {
        for (String r : REASONS) if (r.equals(reason)) return "ERR-DR " + r;
        return "ERR-DR failed";
    }

    /** A get reads once; a set stops when the read shows the wanted value or the bound is spent. */
    static boolean readBackDone(boolean isSet, int want, int seen, long elapsedMs) {
        return !isSet || seen == want || elapsedMs >= READBACK_MS;
    }
}
