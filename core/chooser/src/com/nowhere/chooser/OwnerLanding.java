package com.nowhere.chooser;

/** NWP-20261129-12: whether an owner action's late answer, or a confirm dialog left open, may still act (pure, java.lang only).
 *  Slice D's rule (ChooserActivity.onPause, NWP-20261001-02) ends owner mode on a screen-off: it drops ownerSessionPass
 *  and shows the gate. "Back to gate" does the same. An action that started in owner mode and is answered after that
 *  must open nothing, because every owner screen leads back to the owner menu, which asks no passphrase. buildReportScreen
 *  guards its callbacks for the same reason (NWP-20260819-01).
 *
 *  The eight sites, all in ChooserActivity. Six landings: buildOwnerInboxScreen's Clear all, buildOwnerInboxItemScreen's
 *  Delete, confirmRepairBindings, buildBindSimScreen's Unbind and its mark-mine row, buildStoreScreen's Save. Two dialog
 *  buttons, in front of Repair and Unbind: onPause does not dismiss an AlertDialog, so the button stays live over the gate.
 *
 *  startedInOwnerMode is read on the UI thread when the action starts, before any dialog is built. A read in the dialog's
 *  button or in the worker sees false once owner mode has ended, and lands(false, false) is true, so the guard would pass.
 *  First run's Store step holds no passphrase (StoreGate.keepsOwnerPass), so startedInOwnerMode is false and its Save lands. */
final class OwnerLanding {
    private OwnerLanding() {}

    static boolean lands(boolean startedInOwnerMode, boolean ownerModeNow) { return !startedInOwnerMode || ownerModeNow; }
}
