package com.nowhere.chooser;

/**
 * The WIFI-MIRROR line format, in one place: {@code ssid \t psk [\t macRandomizationSetting]}. WifiMirror.capture
 * writes it and ChooserActivity.maybeMirrorWifi reads it back at the gate; the daemon stores lines verbatim.
 * No Android types, so core/vendor-common/bin/test-wifi-mirror-java.sh compiles and runs this file alone.
 */
final class WifiMirrorLine {
    private WifiMirrorLine() {}

    /** The line (no trailing newline) for one saved network, or null where the capture skips it: an SSID that is not
     *  enclosed in quotes (the hex form, which the gate's quoted re-add would turn into a different network), an SSID
     *  that is empty or only whitespace once unquoted, a tab or newline in the SSID or the PSK, or a raw-hex
     *  (non-quoted) PSK. Exactly ONE enclosing quote pair is removed from the SSID and the PSK; nothing is trimmed, so
     *  inner quotes and edge spaces reach the gate byte for byte. The mode rides as a third field only when
     *  {@code macMode >= 0}. */
    static String encode(String rawSsid, String rawPsk, int macMode) {
        String ssid = unquote(rawSsid);
        if (ssid == null || ssid.trim().isEmpty() || ssid.contains("\t") || ssid.contains("\n")) return null;
        String psk = rawPsk == null ? "" : rawPsk;
        if (!psk.isEmpty()) {
            psk = unquote(psk);
            if (psk == null) return null; // raw hex PSK
        }
        if (psk.contains("\t") || psk.contains("\n")) return null;
        String line = ssid + "\t" + psk;
        // #118/#467: the per-network MAC-randomization mode. WITHOUT IT the gate re-adds every network at the
        // platform default (RANDOMIZATION_ALWAYS, 100 on GrapheneOS) and a MAC-allowlist AP rejects it.
        if (macMode >= 0) line += "\t" + macMode;
        return line;
    }

    /** {@code s} without its one enclosing pair of double quotes, or null when it is not enclosed in them. */
    private static String unquote(String s) {
        if (s.length() < 2 || !s.startsWith("\"") || !s.endsWith("\"")) return null;
        return s.substring(1, s.length() - 1);
    }

    /** {ssid, psk, macField} for one stored line, or null for a line with fewer than two fields or an SSID that is
     *  empty or only whitespace. The SSID and PSK are returned exactly as stored (a passphrase may begin or end with a
     *  space); an absent third field is "". */
    static String[] parse(String line) {
        String[] f = line.split("\t", -1);
        if (f.length < 2) return null;
        if (f[0].trim().isEmpty()) return null;
        return new String[] {f[0], f[1], f.length > 2 ? f[2].trim() : ""};
    }

    /** The networks in a GET-WIFI-MIRROR reply read WITHOUT trimming: none unless the first line is "OK", then
     *  {@link #parse} of every later line that is not blank, passed untrimmed. */
    static java.util.List<String[]> parseReply(java.util.List<String> raw) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        if (raw.isEmpty() || !"OK".equals(raw.get(0).trim())) return out;
        for (int i = 1; i < raw.size(); i++) {
            String l = raw.get(i);
            if (l.trim().isEmpty()) continue;
            String[] e = parse(l);
            if (e != null) out.add(e);
        }
        return out;
    }

    /** NWP-20261020-31: the request that records one gate adopt pass in the daemon's log -- counts only, never an SSID:
     *  {@code pass} (0..2), the networks added, those already saved for user 0, and those the framework refused. */
    static String adoptRequest(int pass, int added, int present, int failed) {
        return "WIFI-ADOPT\n" + pass + "\n" + added + "\n" + present + "\n" + failed + "\n";
    }
}
