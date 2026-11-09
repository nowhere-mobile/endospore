package com.nowhere.chooser;

/** NWP-20261031-04, NWP-20261124-11, NWP-20261129-09: the cases for StoreGate. */
public final class StoreGateCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + want + " got " + got);
        }
    }

    public static void main(String[] args) {
        eq("needsOwnerVerify(true)", true, StoreGate.needsOwnerVerify(true));
        eq("needsOwnerVerify(false)", false, StoreGate.needsOwnerVerify(false));
        eq("keepsOwnerPass(DEST_MENU)", true, StoreGate.keepsOwnerPass(StoreGate.DEST_MENU));
        eq("keepsOwnerPass(DEST_INBOX)", true, StoreGate.keepsOwnerPass(StoreGate.DEST_INBOX));
        eq("keepsOwnerPass(DEST_STORE)", false, StoreGate.keepsOwnerPass(StoreGate.DEST_STORE));
        eq("keepsOwnerPass(DEST_DEVICE)", false, StoreGate.keepsOwnerPass(StoreGate.DEST_DEVICE));
        eq("devicePickersOpen(no passphrase, not verified)", true, StoreGate.devicePickersOpen(false, false));
        eq("devicePickersOpen(no passphrase, verified)", true, StoreGate.devicePickersOpen(false, true));
        eq("devicePickersOpen(passphrase, not verified)", false, StoreGate.devicePickersOpen(true, false));
        eq("devicePickersOpen(passphrase, verified)", true, StoreGate.devicePickersOpen(true, true));
        eq("deviceVerifyLands(any destination: answer in the visit it was submitted in)", true, StoreGate.deviceVerifyLands(3, 3));
        eq("deviceVerifyLands(any destination: Cancel or screen-off before the answer)", false, StoreGate.deviceVerifyLands(3, 4));
        eq("deviceVerifyLands(any destination: several screens before the answer)", false, StoreGate.deviceVerifyLands(3, 9));
        final int[] dests = { StoreGate.DEST_MENU, StoreGate.DEST_INBOX, StoreGate.DEST_STORE, StoreGate.DEST_DEVICE };
        for (int i = 0; i < dests.length; i++)
            for (int j = i + 1; j < dests.length; j++)
                eq("DEST_* values " + i + " and " + j + " differ", true, dests[i] != dests[j]);
        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("store-gate cases: ok");
    }
}
