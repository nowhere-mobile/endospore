package com.nowhere.chooser;

/**
 * NWP-20261022-01: the cases for OwnerPassChange (made-up bytes only, no real secrets). NWP-20261126-20 adds recheckCode,
 * run against OwnerVerifyForm.check, with origin/main's bare compare as the control.
 */
public final class OwnerPassChangeCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + show(want) + " got " + show(got));
        }
    }

    private static String show(Object o) { return o == null ? "null" : "\"" + o.toString().replace("\n", "\\n") + "\""; }

    private static void step(String reply, OwnerPassChange.Step want) {
        eq("step(" + show(reply) + ")", want, OwnerPassChange.step(reply));
    }

    /** The re-check before NWP-20261126-20: owConstEq(dOld.verifier, stored) ? go on : -4. The control for K4 and K5. */
    private static int bareRecheck(String verifier, String stored) { return verifier.equals(stored) ? 0 : -4; }

    public static void main(String[] args) {
        // A StrongBox pair: both peppers present.
        eq("rewrapRequest StrongBox", "OWNER-KEY-REWRAP\nv1\nT0xEUA==\nb2xk\nTkVXUA==\nbmV3\n",
                OwnerPassChange.rewrapRequest("T0xEUA==", "b2xk", "TkVXUA==", "bmV3"));
        // An FP3 pair: no pepper at all.
        eq("rewrapRequest FP3", "OWNER-KEY-REWRAP\nv1\n-\nb2xk\n-\nbmV3\n",
                OwnerPassChange.rewrapRequest(null, "b2xk", null, "bmV3"));
        eq("rewrapRequest empty peppers", "OWNER-KEY-REWRAP\nv1\n-\nb2xk\n-\nbmV3\n",
                OwnerPassChange.rewrapRequest("", "b2xk", "", "bmV3"));
        eq("rewrapRequest one pepper", "OWNER-KEY-REWRAP\nv1\n-\nb2xk\nTkVXUA==\nbmV3\n",
                OwnerPassChange.rewrapRequest(null, "b2xk", "TkVXUA==", "bmV3"));

        step("OK", OwnerPassChange.Step.WRITE_CONF);
        step(" OK\n", OwnerPassChange.Step.WRITE_CONF);
        step("NOKEY", OwnerPassChange.Step.WRITE_CONF);
        step("WRONG", OwnerPassChange.Step.WRONG);
        for (String r : new String[] {"ERR mode", "ERR version", "ERR io", "ERR request", "DENIED", "CREATED",
                "REPLACED", "REPAIRED", "", "garbage"}) {
            step(r, OwnerPassChange.Step.UNCHANGED);
        }
        step(null, OwnerPassChange.Step.UNCHANGED);

        String short8 = "use at least 8 characters — a passphrase (several words) is best";
        eq("floorError 7 chars", short8, OwnerPassChange.floorError("1234567", "1234567"));
        eq("floorError 8 differ", "the two passphrases don't match", OwnerPassChange.floorError("12345678", "12345679"));
        eq("floorError 8 equal", null, OwnerPassChange.floorError("12345678", "12345678"));
        eq("floorError empty", short8, OwnerPassChange.floorError("", ""));

        eq("CHANGED", "device passphrase changed", OwnerPassChange.CHANGED);
        eq("UNCHANGED_MSG", "couldn't change the passphrase — it is unchanged", OwnerPassChange.UNCHANGED_MSG);
        eq("NOT_NOW", "can't change the passphrase right now — try again", OwnerPassChange.NOT_NOW);

        // NWP-20261126-20: the change's re-check of the old passphrase uses the verify's form rule.
        eq("K1 recheckCode(MATCH)", 0, OwnerPassChange.recheckCode(OwnerVerifyForm.Outcome.MATCH));
        eq("K1 recheckCode(UPGRADE)", 0, OwnerPassChange.recheckCode(OwnerVerifyForm.Outcome.UPGRADE));
        eq("K1 recheckCode(MATCH_NO_CHIP)", 0, OwnerPassChange.recheckCode(OwnerVerifyForm.Outcome.MATCH_NO_CHIP));
        eq("K2 recheckCode(CHIP_DOWN)", -6, OwnerPassChange.recheckCode(OwnerVerifyForm.Outcome.CHIP_DOWN));
        eq("K3 recheckCode(WRONG)", -4, OwnerPassChange.recheckCode(OwnerVerifyForm.Outcome.WRONG));
        String chipForm = "a1".repeat(32), pbkdf = "b2".repeat(32), chipNow = "c3".repeat(32);
        // K4: owner.conf holds the chip form; the chip is silent at the second derive, so ownerDerive's verifier is
        // the PBKDF2 hex. The verify's rule says CHIP_DOWN (-6); the bare compare said -4 ("unchanged").
        OwnerVerifyForm.Outcome o4 = OwnerVerifyForm.check(chipForm, "", pbkdf, true);
        eq("K4 check", OwnerVerifyForm.Outcome.CHIP_DOWN, o4);
        eq("K4 recheckCode", -6, OwnerPassChange.recheckCode(o4));
        eq("K4 control: the bare compare answered -4", -4, bareRecheck(pbkdf, chipForm));
        // K5: verifyOwner's UPGRADE write did not land, so owner.conf holds the PBKDF2 form; the chip answers, so
        // ownerDerive's verifier is the chip hex. The verify's rule says UPGRADE (go on); the bare compare said -4.
        OwnerVerifyForm.Outcome o5 = OwnerVerifyForm.check(pbkdf, chipNow, pbkdf, true);
        eq("K5 check", OwnerVerifyForm.Outcome.UPGRADE, o5);
        eq("K5 recheckCode", 0, OwnerPassChange.recheckCode(o5));
        eq("K5 control: the bare compare answered -4", -4, bareRecheck(chipNow, pbkdf));

        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
