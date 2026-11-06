package com.nowhere.napps;

/**
 * What a catalog row's action button offers (NWP-20261119-19).
 *
 * docs/product-decisions.md, h49 #1 (2026-10-31): for an On-demand app that is already in the session, nApps shows
 * "Download" instead of "Get", the grey line "In your apps · not on this phone yet", then "Downloading your copy of
 * <App>…"; a newer catalog version from the same publisher keeps "Update" and the grey line. Q051 (2026-10-20): the
 * tap materialises the sealed copy through the chooser, so the group brings its Play dependencies.
 *
 * Before this slice the row painted "Get" whenever getPackageInfo(pkg, 0) failed, which an archived placeholder does,
 * and the tap downloaded the catalog build although the profile's own copy was in #apps.
 *
 * Pure (java.* only), so core/vendor-common/bin/test-napps-action-java.sh compiles it alone under plain javac.
 */
final class NappsAction {

    enum State { GET, DOWNLOAD, UPDATE, ADDED }

    static final String GREY = "In your apps · not on this phone yet";

    private NappsAction() {}

    /** hasCode: the flags-0 read resolves (the code is on this phone). archivedHere: only the archived read resolves
     *  (an On-demand placeholder of this session). haveVc: the version PM reports for either; <= 0 is unreadable.
     *  catalogVc: the catalog entry's version; <= 0 names none. sameSigner: the catalog's pinned signer is one of the
     *  package's signers, false when that cannot be told. */
    static State state(boolean hasCode, boolean archivedHere, long haveVc, long catalogVc, boolean sameSigner) {
        if (hasCode) return catalogVc > 0 && catalogVc > haveVc && sameSigner ? State.UPDATE : State.ADDED;
        // An unreadable placeholder version must never make every catalog pin look newer (TapUpdate.takeCatalog's rule).
        if (archivedHere) return haveVc > 0 && catalogVc > haveVc && sameSigner ? State.UPDATE : State.DOWNLOAD;
        return State.GET;
    }

    static String label(State s) {
        switch (s) {
            case DOWNLOAD: return "Download";
            case UPDATE:   return "Update";
            case ADDED:    return "Added";
            default:       return "Get";
        }
    }

    /** The grey line under the row, or null for none: Download, and Update of an archived placeholder. */
    static String greyLine(State s, boolean archivedHere) {
        if (s == State.DOWNLOAD) return GREY;
        if (s == State.UPDATE && archivedHere) return GREY;
        return null;
    }

    /** The status line while the chooser materialises the sealed copy. */
    static String downloadingStatus(String app) {
        return "Downloading your copy of " + app + "…";
    }

    /** The catalog's signingCert (64 hex, the catalog's own field) is one of the package's signer digests, case
     *  ignored. A missing or malformed pin, or no known signer, is false: the row offers the sealed copy. */
    static boolean sameSigner(String catalogCert, java.util.Collection<String> haveCerts) {
        if (catalogCert == null || haveCerts == null || haveCerts.isEmpty()) return false;
        String pin = catalogCert.trim();
        if (!pin.matches("[0-9a-fA-F]{64}")) return false;
        for (String c : haveCerts) if (c != null && c.trim().equalsIgnoreCase(pin)) return true;
        return false;
    }

    /** Lower-case hex SHA-256 of a signing cert's DER bytes, the same function as the chooser's TapUpdate.certHex and
     *  the catalog's signingCert field. nApps depends on the chooser for data only, so it restates it. */
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
}
