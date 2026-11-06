package com.nowhere.chooser;

/**
 * NWP-20261023-04: the signer pin a store install must hold, read from the daemon's FETCH-APP success line.
 *
 * The daemon writes it as {@code OK <pkg> <signer>} (core/agent catalog.go handleFetchApp), the signer being
 * the lowercased 64-hex cert of the entry it resolved from the SIGNED catalog/index, or "-" when the catalog
 * genuinely omits it. Anything else -- a short line, a cut-off line at EOF, another package, a malformed cert,
 * an older agent's reply -- is NOT "the catalog omits the cert": it is a reply nobody vouched for, and the
 * install is refused. Pure java.lang/java.util so a javac suite executes it (test-store-signer-pin-java.sh).
 */
final class StoreSignerPin {
    private StoreSignerPin() {}

    /** The pin the install must hold: the lowercased cert, "" when the daemon said "-", or null == REFUSE. */
    static String fromFetchReply(String reply, String pkg) {
        if (reply == null || pkg == null) return null;
        String t = reply.trim();
        if (t.isEmpty()) return null;
        String[] tok = t.split("\\s+");
        if (tok.length != 3) return null;
        if (!"OK".equals(tok[0])) return null;
        if (!tok[1].equals(pkg)) return null;
        if ("-".equals(tok[2])) return "";
        if (!isHex64(tok[2])) return null;
        return tok[2].toLowerCase(java.util.Locale.ROOT);
    }

    private static boolean isHex64(String s) {
        if (s.length() != 64) return false;
        for (int i = 0; i < 64; i++) {
            char c = s.charAt(i);
            boolean hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hex) return false;
        }
        return true;
    }
}
