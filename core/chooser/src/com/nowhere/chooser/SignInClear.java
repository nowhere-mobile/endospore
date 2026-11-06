package com.nowhere.chooser;

/** NWP-20261117-09: the gate clears its sign-in fields when the screen turns off.
 *
 *  Decision of record: docs/product-decisions.md, 2026-10-29, "three answers — the gate clears its sign-in fields
 *  when the screen turns off ...", first bullet. Chester: "clearing when screen turns off makes sense".
 *
 *  The decision's inference: the rule is the screen-off, not the failure. The gate clears whatever the fields
 *  hold at that moment, after a BLANK NET sign-in or any other line.
 *
 *  This slice's own reading (an inference, not a quote): the create form's confirm and claim-code fields go with
 *  the two sign-in fields beside them. A passphrase left in the confirm field, or a purchase code left in its
 *  field, is what the decision ends.
 *
 *  A sign-in or create already sent keeps the values it read. roamLogin reads the claim code at the tap, so a
 *  clear during the network wait cannot send CREATE without the buyer's code.
 *
 *  Pure java.lang, so test-signin-clear-java.sh compiles it with its cases off the build host. */
final class SignInClear {
    private SignInClear() {}

    /** The line a key tap paints when the fields hold no usable name and passphrase (gateNfcResult). */
    static final String NEED_CREDS = "Enter your name and passphrase first, then tap again.";

    /** True when a sign-in can start from these fields: a non-empty passphrase and a name that is not blank. */
    static boolean usable(String name, String pass) {
        return pass != null && !pass.isEmpty() && name != null && !name.trim().isEmpty();
    }

    /** True when a screen-off ends the key wait, as its Cancel does: the gate is parked on a key and no
     *  sign-in or resume round trip is running. A park whose round trip still runs is kept. */
    static boolean endsKeyWait(boolean parked, boolean roundTrip) {
        return parked && !roundTrip;
    }
}
