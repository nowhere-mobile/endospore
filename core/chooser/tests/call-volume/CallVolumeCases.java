package com.nowhere.chooser;

/** Cases for CallVolume.callStream (NWP-20261114-30). Prints "--- FAIL: <name>" per failed case and exits 1. */
public final class CallVolumeCases {
    private static int fails = 0;

    private static void check(String name, boolean haveCall, boolean ringing, boolean outgoing, boolean wantCall) {
        boolean got = CallVolume.callStream(haveCall, ringing, outgoing);
        String what = got ? "call" : "ringer";
        if (got == wantCall) System.out.println("--- PASS: " + name + " -> " + what);
        else {
            System.out.println("--- FAIL: " + name + " (callStream(" + haveCall + ", " + ringing + ", " + outgoing
                    + ") = " + got + ", the " + what + ")");
            fails++;
        }
    }

    public static void main(String[] a) {
        check("C1 no call adjusts the ringer", false, false, false, false);
        check("C2 a ringing incoming call adjusts the ringer", true, true, false, false);
        check("C3 a connected call adjusts the call", true, false, false, true);
        check("C4 the owner's outgoing call, dialing, adjusts the call", true, false, true, true);
        check("C5 the owner's outgoing call never adjusts the ringer, even flagged ringing", true, true, true, true);
        System.exit(fails == 0 ? 0 : 1);
    }
}
