package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.Set;

/**
 * The contract and every decision of a signed-in profile's shared connection (NWP-20261028-08;
 * docs/product-decisions.md 2026-10-19, the hotspot entry's item 1 and the session-settings entry's item 1).
 *
 * Pure Java: nothing here touches the platform, so a javac suite runs all of it. HotspotService and HotspotReceiver
 * are the glue. The session's chooser (NOWHERE-718) binds HotspotService in user 0 and roamd (NOWHERE-717) calls
 * HotspotReceiver; both code against these constants byte for byte. The name and passphrase cross only as a Binder
 * parcel, never argv, and are never logged or replied.
 */
final class Hotspot {
    private Hotspot() {}

    // Transaction codes of the bound HotspotService. START in: type, then for wifi ssid and passphrase. STOP in: type.
    // STATE in: nothing. Every reply is one string.
    static final int START = 1;
    static final int STOP = 2;
    static final int STATE = 3;

    static final String TYPE_WIFI = "wifi";
    static final String TYPE_USB = "usb";
    static final String TYPE_BLUETOOTH = "bluetooth";
    private static final String[] TYPE_LIST = {TYPE_WIFI, TYPE_USB, TYPE_BLUETOOTH};

    /** The release receiver: explicit component, int extra EXTRA_UID (a session's user id, -1 = unconditional). */
    static final String ACTION_RELEASE = "com.nowhere.chooser.action.HOTSPOT_RELEASE";
    static final String EXTRA_UID = "uid";

    static final String OK_RELEASED = "OK RELEASED";
    static final String OK_KEPT = "OK KEPT";

    static final String R_USER = "user";
    static final String R_CALLER = "caller";
    static final String R_TYPE = "type";
    static final String R_SSID = "ssid";
    static final String R_PASSPHRASE = "passphrase";
    static final String R_CONFIG = "config";
    static final String R_FAILED = "failed";
    static final String R_TIMEOUT = "timeout";
    static final String R_DENIED = "denied";
    static final String R_RESET = "reset";
    private static final Set<String> REASONS = new HashSet<>(Arrays.asList(
            R_USER, R_CALLER, R_TYPE, R_SSID, R_PASSPHRASE, R_CONFIG, R_FAILED, R_TIMEOUT, R_DENIED, R_RESET));

    static final int START_TIMEOUT_MS = 10_000;
    static final int STOP_TIMEOUT_MS = 10_000;
    static final int RESET_READBACK_MS = 5_000;

    static final String RESET_SSID_PREFIX = "AndroidAP_";
    static final String ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    static final int PASS_LEN_RESET = 16;

    enum Release { RELEASE, KEEP }

    /** The three types, in the order STATE reports them. */
    static List<String> types() {
        return Collections.unmodifiableList(Arrays.asList(TYPE_LIST));
    }

    /** The canonical type equal to t (exact, case-sensitive), else null. */
    static String typeOf(String t) {
        for (String s : TYPE_LIST) if (s.equals(t)) return s;
        return null;
    }

    /** 1-32 UTF-8 bytes, no character below 0x20 and no 0x7f. */
    static boolean validSsid(String s) {
        if (s == null || s.isEmpty()) return false;
        int n = s.getBytes(StandardCharsets.UTF_8).length;
        if (n < 1 || n > 32) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || c == 0x7f) return false;
        }
        return true;
    }

    /** WPA2-PSK: 8-63 characters, each 0x20-0x7e. */
    static boolean validPassphrase(String p) {
        if (p == null || p.length() < 8 || p.length() > 63) return false;
        for (int i = 0; i < p.length(); i++) {
            char c = p.charAt(i);
            if (c < 0x20 || c > 0x7e) return false;
        }
        return true;
    }

    /** Only the same app, from the foreground session (a user of 10 or more), may start. */
    static boolean mayStart(boolean sameApp, int callerUser, int foregroundUser) {
        return sameApp && callerUser >= 10 && callerUser == foregroundUser;
    }

    /** Only the same app, from a session, and only the owner (or anyone while the owner is unknown), may stop. */
    static boolean mayStop(boolean sameApp, int callerUser, Integer owner) {
        return sameApp && callerUser >= 10 && (owner == null || owner.intValue() == callerUser);
    }

    /** uid -1 is unconditional (the boot sweep's); an unknown owner is released; another session's is kept. */
    static Release releaseDecision(Integer owner, int uid) {
        return (uid == -1 || owner == null || owner.intValue() == uid) ? Release.RELEASE : Release.KEEP;
    }

    /** The fresh name a release writes over a session's: AndroidAP_ and four decimal digits. */
    static String resetSsid(Random r) {
        return RESET_SSID_PREFIX + String.format(Locale.ROOT, "%04d", r.nextInt(10000));
    }

    /** The fresh passphrase a release writes over a session's. Callers pass a SecureRandom. */
    static String resetPassphrase(Random r) {
        StringBuilder sb = new StringBuilder(PASS_LEN_RESET);
        for (int i = 0; i < PASS_LEN_RESET; i++) {
            sb.append(ALNUM.charAt(r.nextInt(ALNUM.length())));
        }
        return sb.toString();
    }

    /** The location rule: only a STORED session that is not offline is offered the hotspot (NOWHERE-718). */
    static boolean offered(String sessionType, boolean offline) {
        return "STORED".equals(sessionType) && !offline;
    }

    /** The profile's saved hotspot, "ssid=<s>\npass=<p>\n"; null unless both are valid. */
    static String configText(String ssid, String pass) {
        if (!validSsid(ssid) || !validPassphrase(pass)) return null;
        return "ssid=" + ssid + "\npass=" + pass + "\n";
    }

    /** {ssid, pass} from configText's format: CR stripped, the first line of each key decides, invalid reads null. */
    static String[] parseConfig(String text) {
        String[] out = {null, null};
        if (text == null) return out;
        boolean seenSsid = false, seenPass = false;
        for (String line : text.split("\n", -1)) {
            if (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
            if (line.startsWith("ssid=") && !seenSsid) {
                seenSsid = true;
                String v = line.substring(5);
                out[0] = validSsid(v) ? v : null;
            } else if (line.startsWith("pass=") && !seenPass) {
                seenPass = true;
                String v = line.substring(5);
                out[1] = validPassphrase(v) ? v : null;
            }
        }
        return out;
    }

    /** The label of a type on the screen and in its toasts; null for a name that is not a type. */
    static String label(String type) {
        if (TYPE_WIFI.equals(type)) return "Wi-Fi hotspot";
        if (TYPE_USB.equals(type)) return "USB tethering";
        if (TYPE_BLUETOOTH.equals(type)) return "Bluetooth tethering";
        return null;
    }

    /**
     * What a tap on a type's switch tells the user, from the gate's one-line reply (NWP-20261028-11). Only the type,
     * the direction and the reply's verdict are read: it never contains the name or the passphrase, which the reply
     * does not carry either. A timeout or no reply at all (an empty or null reply) says the phone didn't answer
     * (NWP-20261113-07); any other unconfirmed change (any other ERR-HS) says it didn't confirm it. Both ask to try
     * again, so a switch is never reported as moved when the gate did not say it moved.
     */
    static String toast(String type, boolean wantOn, String reply) {
        String label = label(type);
        if (label == null) label = "The connection";
        if (wantOn && okOn(String.valueOf(type)).equals(reply)) {
            return label + " on — only while you're signed in to this profile";
        }
        if (!wantOn && okOff(String.valueOf(type)).equals(reply)) {
            return label + " off";
        }
        if (reply == null || "".equals(reply) || errLine(R_TIMEOUT).equals(reply)) {
            return "Couldn't turn " + label + (wantOn ? " on" : " off") + " — the phone didn't answer. Try again.";
        }
        if (errLine(R_CALLER).equals(reply)) {
            return "Couldn't change this — this profile isn't the one in front.";
        }
        return "Couldn't turn " + label + (wantOn ? " on" : " off") + " — the phone didn't confirm it. Try again.";
    }

    /** True only for "<type>=1" in a STATE line (stateLine's format); a missing type or a malformed line is false. */
    static boolean switchOn(String stateReply, String type) {
        if (stateReply == null || type == null || !stateReply.startsWith("STATE ")) return false;
        for (String tok : stateReply.substring(6).split(" ")) {
            if (tok.equals(type + "=1")) return true;
        }
        return false;
    }

    static String okOn(String type) {
        return "OK ON " + type;
    }

    static String okOff(String type) {
        return "OK OFF " + type;
    }

    static String stateLine(boolean wifi, boolean usb, boolean bluetooth) {
        return "STATE " + TYPE_WIFI + "=" + (wifi ? 1 : 0) + " " + TYPE_USB + "=" + (usb ? 1 : 0)
                + " " + TYPE_BLUETOOTH + "=" + (bluetooth ? 1 : 0);
    }

    /** ERR-HS plus the reason; a reason outside the list is ERR-HS failed. */
    static String errLine(String reason) {
        return "ERR-HS " + (REASONS.contains(reason) ? reason : R_FAILED);
    }

    /** True when any interface name matches any regex (null-safe; a bad regex is skipped). */
    static boolean anyMatches(List<String> ifaces, List<String> regexs) {
        if (ifaces == null || regexs == null) return false;
        for (String re : regexs) {
            if (re == null) continue;
            java.util.regex.Pattern p;
            try {
                p = java.util.regex.Pattern.compile(re);
            } catch (java.util.regex.PatternSyntaxException e) {
                continue;
            }
            for (String i : ifaces) if (i != null && p.matcher(i).matches()) return true;
        }
        return false;
    }

    /**
     * The tethered-interface / regexp callback cache. Unknown (either half not yet reported) reads as ON, and a stop is
     * confirmed only by a tethered-INTERFACE event that arrives after the stop was requested: a regexp event is not
     * evidence about what is tethered.
     */
    static final class TetherCache {
        private List<String> ifaces = Collections.emptyList();
        private List<String> usbRegexs = Collections.emptyList();
        private List<String> btRegexs = Collections.emptyList();
        private boolean haveIfaces;
        private boolean haveRegexs;
        private int ifaceEvents;

        synchronized void onIfaces(List<String> l) {
            ifaces = l == null ? Collections.<String>emptyList() : l;
            haveIfaces = true;
            ifaceEvents++;
        }

        synchronized void onRegexs(List<String> usb, List<String> bt) {
            usbRegexs = usb;
            btRegexs = bt;
            haveRegexs = true;
        }

        synchronized boolean known() {
            return haveIfaces && haveRegexs;
        }

        /** Mark taken when a stop is requested; pass it to {@link #stopConfirmed}. */
        synchronized int mark() {
            return ifaceEvents;
        }

        synchronized boolean isOn(String type) {
            if (!known()) return true;
            return anyMatches(ifaces, TYPE_USB.equals(type) ? usbRegexs : btRegexs);
        }

        synchronized boolean stopConfirmed(String type, int mark) {
            return ifaceEvents != mark && !isOn(type);
        }
    }
}
