package com.nowhere.chooser;

/** Q050 (decided 2026-10-20, docs/product-decisions.md; NWP-20261112-06): at the TAP on an On-demand app, when the
 *  catalog pins a newer version from the same signer, the materialise installs that instead of the sealed #apps copy,
 *  and falls back to the sealed copy when the catalog cannot be reached or the fetch or install fails. This is the
 *  decision logic of that tap, kept pure (java.lang / java.util / java.security only) so a javac suite compiles it
 *  with its cases (core/vendor-common/bin/test-tap-update-java.sh). UnarchiveService.tapUpdateLocked does the I/O. */
final class TapUpdate {
    private TapUpdate() {}

    /** The catalog's version is installed: the caller skips the sealed fetch. */
    static final int INSTALLED = 1;
    /** Take the sealed copy, as before Q050. */
    static final int SEALED = 2;
    /** Stop the tap: neither the catalog's nor the sealed copy is installed now. */
    static final int STOP = 3;

    /** The daemon's CATALOG-PIN answer: the catalog's versionCode and its signer (SHA-256 of the cert, lower hex). */
    static final class Pin {
        final long vc;
        final String cert;
        Pin(long vc, String cert) { this.vc = vc; this.cert = cert; }
    }

    /** Parses CATALOG-PIN's reply. Only "OK <positive versionCode> <64 hex>" is a pin (the cert lower-cased); NONE,
     *  ERR-*, an empty reply (no daemon), null and any other shape are null, which means "take the sealed copy". */
    static Pin parse(String reply) {
        if (reply == null) return null;
        String[] t = reply.trim().split("\\s+");
        if (t.length != 3 || !"OK".equals(t[0])) return null;
        if (!allDigits(t[1])) return null; // rejects "x", "+42", "-1"
        long vc;
        try { vc = Long.parseLong(t[1]); } catch (NumberFormatException e) { return null; }
        if (vc <= 0) return null;
        if (!isHex64(t[2])) return null;
        return new Pin(vc, t[2].toLowerCase(java.util.Locale.ROOT));
    }

    /** True only when the pin is strictly newer than the archived (sealed) versionCode AND its signer is one of the
     *  archived package's signers (case ignored). No pin, an equal or older pin, another signer, or no known signer
     *  is false: the sealed copy is taken. */
    static boolean takeCatalog(long sealedVc, java.util.Collection<String> sealedCerts, Pin pin) {
        if (pin == null || sealedCerts == null || sealedCerts.isEmpty()) return false;
        if (!(pin.vc > sealedVc)) return false; // strictly newer only: an equal pin is the sealed copy itself
        for (String c : sealedCerts) if (c != null && c.equalsIgnoreCase(pin.cert)) return true;
        return false;
    }

    /** Lower-case hex SHA-256 of a signing cert's DER bytes (Signature.toByteArray()), the same function as
     *  StoreInstaller.sha256hex and the catalog's cert field. */
    static String certHex(byte[] der) {
        try {
            byte[] h = java.security.MessageDigest.getInstance("SHA-256").digest(der);
            final char[] hx = "0123456789abcdef".toCharArray();
            StringBuilder sb = new StringBuilder(h.length * 2);
            for (byte b : h) { sb.append(hx[(b >> 4) & 0xf]); sb.append(hx[b & 0xf]); }
            return sb.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** What the tap does after FETCH-APP (and, on an OK reply, StoreInstaller.installStaged's verdict):
     *  - ERR-CANCELLED -> STOP. A FORWARD GUARD for a cancel-aware FETCH-APP: today FETCH-APP does not answer it,
     *    because roamd's stageapp worker answers only OK, ERR-PKG or ERR-STAGE, and the only ERR-CANCELLED producer
     *    is roamd's materializeapp arm, the sealed fetch. The arm exists so that a FETCH-APP that later honours a
     *    sign-out's od-cancel stops the tap instead of starting a sealed fetch that would fight the sign-out.
     *  - any other reply that is not "OK ..." (ERR-*, NONE, no daemon) -> SEALED.
     *  - verdict OK -> INSTALLED.
     *  - verdict PENDING -> STOP: the package manager owns the outcome, and the install hook
     *    (AppInstallReceiver.heal) restores the parked data if the install lands. A sealed install now would race it.
     *  - any other verdict (FAIL, NOSIGNER, none) -> SEALED. */
    static int afterFetch(String fetchReply, String installVerdict) {
        if (fetchReply != null && fetchReply.startsWith("ERR-CANCELLED")) return STOP;
        if (fetchReply == null || !fetchReply.startsWith("OK ")) return SEALED;
        if ("OK".equals(installVerdict)) return INSTALLED;
        if ("PENDING".equals(installVerdict)) return STOP;
        return SEALED;
    }

    private static boolean allDigits(String s) {
        if (s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) if (s.charAt(i) < '0' || s.charAt(i) > '9') return false;
        return true;
    }

    private static boolean isHex64(String s) {
        if (s.length() != 64) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
        }
        return true;
    }
}
