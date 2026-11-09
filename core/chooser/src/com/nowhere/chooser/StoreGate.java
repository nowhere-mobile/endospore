package com.nowhere.chooser;

/** NWP-20261031-04: where the owner verify may lead, and whether the Store screen sits behind it (pure, java.lang only).
 *  Decision of record: docs/product-decisions.md, 2026-10-20 -- the gate's Store settings sit behind the owner
 *  passphrase. ChooserActivity.buildOwnerVerifyScreen takes a DEST_* and openStoreSettings asks needsOwnerVerify.
 *  NWP-20261124-11: decision #13 of 2026-11-02 puts the Settings screen's device-wide controls (Backup cadence,
 *  automatic install, install time) behind the same verify; ChooserActivity.deviceControlsOpen asks devicePickersOpen.
 *  NWP-20261126-03: decision 2026-11-03 moves Store settings to Owner settings, behind DEST_MENU's verify, which opens
 *  the Store screen with no second verify. openStoreSettings and DEST_STORE now serve first run's store step only.
 *  NWP-20261129-09: the visit rule of deviceVerifyLands now bounds every destination of the owner verify.
 *  NWP-20261130-14: decision 2026-11-06 moves Backup cadence to Owner settings the same way, so DEST_DEVICE and
 *  devicePickersOpen now guard automatic install and install time only. */
final class StoreGate {
    private StoreGate() {}

    /** The owner menu (the shield), the unassigned-line inbox (the notice banner), first run's Store step
     *  (openStoreSettings, NWP-20261126-03), the Settings screen's device-wide controls (automatic install, install time). */
    static final int DEST_MENU = 0, DEST_INBOX = 1, DEST_STORE = 2, DEST_DEVICE = 3;

    /** Store settings need the owner verify whenever a device passphrase exists. With none (first run, whose store
     *  step comes before its passphrase step) there is nothing to verify against. */
    static boolean needsOwnerVerify(boolean ownerSecretSet) { return ownerSecretSet; }

    /** NWP-20261124-11 (#13, 2026-11-02): the automatic-install switch and the install-time row change a setting
     *  only when no device passphrase exists (first run: nothing to verify against, as for needsOwnerVerify) or the
     *  owner verified during this visit of the Settings screen. */
    static boolean devicePickersOpen(boolean ownerSecretSet, boolean verifiedThisVisit) {
        return !ownerSecretSet || verifiedThisVisit;
    }

    /** NWP-20261124-11, NWP-20261129-09: a verify's success, for every DEST_*, and its lost-key screen count only for
     *  the visit the verify was submitted in. A Cancel, a screen-off or any other screen before the answer ends that
     *  visit, and the late answer is ignored. */
    static boolean deviceVerifyLands(int visitAtSubmit, int visitNow) { return visitAtSubmit == visitNow; }

    /** The Inbox verbs derive their pepper from the passphrase held in RAM; the Store screen and the device-wide
     *  controls do not use it. Only an answer that lands (deviceVerifyLands) sets that passphrase. */
    static boolean keepsOwnerPass(int dest) { return dest == DEST_MENU || dest == DEST_INBOX; }
}
