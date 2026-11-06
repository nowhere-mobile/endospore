package com.nowhere.chooser;

/**
 * The Store settings screen's status message, chosen from GET-STORE's configured= / managed= / keyset= lines
 * (NWP-20261113-21). Backlog row "Store settings on a managed (gateway) device says "no store yet — set one up"
 * under its own "Managed store — connected" banner": the message was picked from keyset= alone, and a managed device
 * has no keys, so it was told it had no store. Pure Java (no android.*), so tests/store-screen-copy runs it under javac.
 *
 * Precedence: managed, then a key already set, then no store. A daemon older than the managed= line reads as
 * managed=no, which is the behaviour before this class. The managed message says nothing about the S3 fields: since
 * NWP-20261124-16 (decision #15, 2026-11-02) the store screen hides them on a managed phone through showS3Fields, and
 * its subtitle names no S3 store there.
 */
final class StoreScreenCopy {
    private StoreScreenCopy() {}

    /** The message for one GET-STORE state. {@code configured} does not change it today: a managed device is always
     *  configured, and the key / no-store split reads keyset= only, as it always did. */
    static String message(boolean configured, boolean managed, boolean keyset) {
        if (managed) return "This phone saves to the managed Nowhere store.";
        if (keyset) return "a key is already set — re-enter both keys to change it";
        return "no store yet — set one up to create or unlock a profile";
    }

    /** True only for the key-already-set state, which renders through StatusLine.error; the managed message renders
     *  as a plain muted line and the no-store one in the accent colour. */
    static boolean isError(boolean managed, boolean keyset) {
        return !managed && keyset;
    }

    /** #15 (2026-11-02): a managed phone shows the managed state only, so the S3 fields, Save store and Test connection
     *  are hidden. A daemon without managed= reads as not managed, the behaviour before NWP-20261113-21. */
    static boolean showS3Fields(boolean managed) {
        return !managed;
    }

    /** The subtitle under "Store settings". The managed one names no S3 store. */
    static String subtitle(boolean managed) {
        if (managed) return "Where your encrypted data is saved.";
        return "Where your encrypted data is saved. Point this device at an S3-compatible store.";
    }
}
