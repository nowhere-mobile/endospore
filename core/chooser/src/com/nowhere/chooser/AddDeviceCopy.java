package com.nowhere.chooser;

/**
 * What the Add this phone screen says about an ADD-DEVICE reply (NWP-20261116-28). Lifted out of
 * {@code ChooserActivity.buildAddPhoneScreen} -- pure, java.lang only -- because that screen read the reply through an
 * inline startsWith chain that no suite named, and anything it did not match, a lost reply ("") included, read
 * "couldn't reach the store". {@code test-add-device-copy-java.sh} compiles this with its cases and pins every code the
 * daemon's handleAddDevice can send to a copy of its own.
 *
 * <p>WHY EACH REFUSAL IS SAFE TO NAME. Unlike the reset screen, this one names WHICH field was wrong. None of the
 * codes separates an unknown name from a wrong phrase (the reasoning is recorded against the sentinels in the agent's
 * add_device.go). ERR-BADPASS is the one that discloses most, and it is reachable only when the 12 words matched this
 * profile: naming the passphrase then tells the holder of those words nothing they could not already get by resetting
 * it outright. BLANK, NOSTORE and ERR-BADSECRET name no profile at all.
 *
 * <p>WHY A LOST REPLY SAYS "TAP ADD AGAIN". The gate's sendDaemon reads for 90 s and collapses a read timeout and a dead
 * socket to "". The daemon's ADD-DEVICE arm allows itself 120 s (two Argon2id passes plus a metered publish). So an add
 * that lands after 90 s, or a daemon that dies after the publish, reads "" here although the add may have landed. A
 * repeat is safe and cheap: enrollSEViaRecovery checks the words and the passphrase again, hardenVaultTo returns
 * without a write when this phone's se slot already opens the vault, and addScopeSESlots skips a scope that already
 * has this phone's slot. A second add after a landed first one writes nothing and answers OK.
 *
 * <p>WHY THE COPY NEVER SAYS TO SIGN IN FIRST. On a profile hardened to another phone where the add did not land, a
 * sign-in here opens no slot, and a sign-in this phone cannot open is a blind throwaway session. The user would see an
 * empty space and could conclude the profile is gone. So the safe retry comes first: tap Add again, then sign in.
 *
 * <p>⚠ EQUALITY, NOT startsWith. "ERR-BADP" and "ERR-BADPASSX" must not borrow ERR-BADPASS's text, and "OKAY" is not
 * "OK". The test's check (a) also refuses a daemon code that is a prefix of another, the bare ERR excepted.
 */
final class AddDeviceCopy {
    private AddDeviceCopy() {}

    /** True only for the daemon's "OK" (after trim): this phone's slot is in the vault. */
    static boolean added(String r) {
        return r != null && "OK".equals(r.trim());
    }

    /** The text for a reply that is not OK; null reads as "" (no answer). */
    static String failText(String r) {
        if (r == null) r = "";
        if ("ERR-BADPASS".equals(r)) return "that recovery code is right, but that is not this profile's passphrase";
        if ("ERR-BADPHRASE".equals(r)) return "that is not a valid 12-word recovery code — check for a typo";
        if ("ERR-NOPROFILE".equals(r)) return "couldn't find that profile — check the name and the recovery code";
        if ("ERR-BADSECRET".equals(r)) return "this phone's secure chip didn't answer — try again";
        if ("NOSTORE".equals(r)) return "this phone has no store set up yet";
        if ("BLANK".equals(r)) return "fill in all three fields";
        if (r.isEmpty()) return "the phone didn't answer, so this phone may or may not have been added — tap Add "
                + "again (adding a phone twice is safe), then sign in with your passphrase";
        return "couldn't reach the store — check your connection and try again";
    }
}
