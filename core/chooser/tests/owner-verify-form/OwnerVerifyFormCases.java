package com.nowhere.chooser;

/** NWP-20261108-07: the cases for OwnerVerifyForm (made-up hex only, no real secrets); NWP-20261120-04 adds lostKey and
 *  OwnerConf.body, read back by ChooserActivity.readOwnerConf lifted into LiftedConf. */
public final class OwnerVerifyFormCases {
    private static int failed = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got != null : !want.equals(got)) {
            failed++;
            System.out.println("FAIL " + what + ": want " + want + " got " + got);
        }
    }

    private static String rep(char c) { return String.valueOf(c).repeat(64); }

    private static void row(String what, OwnerVerifyForm.Outcome want, String stored, String chip, String pbkdf, boolean sb) {
        eq(what, want, OwnerVerifyForm.check(stored, chip, pbkdf, sb));
    }

    /** Writes body to a temp file in java.io.tmpdir (the suite's own dir), reads it with the lifted readOwnerConf, and
     *  deletes it. */
    private static java.util.HashMap<String, String> readBack(String body) {
        java.io.File f = null;
        try {
            f = java.io.File.createTempFile("owner", ".conf", new java.io.File(System.getProperty("java.io.tmpdir")));
            java.nio.file.Files.write(f.toPath(), body.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return new LiftedConf(f).read();
        } catch (java.io.IOException e) {
            failed++;
            System.out.println("FAIL readBack: " + e);
            return null;
        } finally {
            if (f != null) f.delete();
        }
    }

    public static void main(String[] args) {
        final String S = rep('a'), C = rep('b'), P = rep('c');
        final OwnerVerifyForm.Outcome W = OwnerVerifyForm.Outcome.WRONG;
        // Nothing stored, or no PBKDF2 output: WRONG whatever the chip says, even when an empty equals an empty.
        for (boolean sb : new boolean[] { true, false }) {
            for (String chip : new String[] { C, "", null }) {
                row("null stored", W, null, chip, P, sb);
                row("empty stored", W, "", chip, "", sb);
                row("empty stored, pbkdf set", W, "", chip, P, sb);
                row("null pbkdf", W, S, chip, null, sb);
                row("empty pbkdf", W, S, chip, "", sb);
            }
        }
        // The chip answered.
        row("chip form matches", OwnerVerifyForm.Outcome.MATCH, S, S, P, true);
        row("chip form matches, no StrongBox flag", OwnerVerifyForm.Outcome.MATCH, S, S, P, false);
        row("PBKDF2 form matches while the chip answers", OwnerVerifyForm.Outcome.UPGRADE, S, C, S, true);
        row("PBKDF2 form matches while the chip answers, no flag", OwnerVerifyForm.Outcome.UPGRADE, S, C, S, false);
        row("neither form matches, chip answers", W, S, C, P, true);
        row("neither form matches, chip answers, no flag", W, S, C, P, false);
        // The chip is silent.
        for (String silent : new String[] { "", null }) {
            row("PBKDF2 match, chip silent, StrongBox", OwnerVerifyForm.Outcome.MATCH_NO_CHIP, S, silent, S, true);
            row("PBKDF2 match, chip silent, FP3", OwnerVerifyForm.Outcome.MATCH, S, silent, S, false);
            row("mismatch, chip silent, StrongBox", OwnerVerifyForm.Outcome.CHIP_DOWN, S, silent, P, true);
            row("mismatch, chip silent, FP3", W, S, silent, P, false);
        }
        // An empty chip never matches an empty-looking stored value, and near misses do not match.
        String near = S.substring(0, 63) + 'b';
        row("one digit off, chip form", W, S, near, P, true);
        row("one digit off, PBKDF2 form", W, S, C, near, true);
        row("shorter than stored", W, S, S.substring(0, 63), P, true);
        row("longer than stored", W, S, S + "a", P, true);
        row("one digit off, chip silent, FP3", W, S, "", near, false);

        eq("Outcome count", 5, OwnerVerifyForm.Outcome.values().length);
        for (OwnerVerifyForm.Outcome o : OwnerVerifyForm.Outcome.values()) {
            boolean want = o == OwnerVerifyForm.Outcome.MATCH || o == OwnerVerifyForm.Outcome.UPGRADE
                    || o == OwnerVerifyForm.Outcome.MATCH_NO_CHIP;
            eq("matched(" + o + ")", want, OwnerVerifyForm.matched(o));
            eq("toStore(" + o + ")", o == OwnerVerifyForm.Outcome.UPGRADE ? C : S, OwnerVerifyForm.toStore(o, S, C));
        }
        eq("CHIP_DOWN_LINE", "this phone's security chip didn't answer — try again", OwnerVerifyForm.CHIP_DOWN_LINE);

        // NWP-20261108-11: the enrol result. Nothing on disk is FAILED whatever the chip did; on disk, a silent chip is
        // NO_CHIP (never refused, never reported as plain OK).
        eq("enrolResult(not on disk, chip answered)", OwnerVerifyForm.ENROL_FAILED, OwnerVerifyForm.enrolResult(false, false));
        eq("enrolResult(not on disk, chip silent)", OwnerVerifyForm.ENROL_FAILED, OwnerVerifyForm.enrolResult(false, true));
        eq("enrolResult(on disk, chip answered)", OwnerVerifyForm.ENROL_OK, OwnerVerifyForm.enrolResult(true, false));
        eq("enrolResult(on disk, chip silent)", OwnerVerifyForm.ENROL_OK_NO_CHIP, OwnerVerifyForm.enrolResult(true, true));
        eq("ENROL_* pairwise distinct", 3, new java.util.HashSet<>(java.util.Arrays.asList(
                OwnerVerifyForm.ENROL_FAILED, OwnerVerifyForm.ENROL_OK, OwnerVerifyForm.ENROL_OK_NO_CHIP)).size());
        eq("ENROL_NO_CHIP_LINE", "device passphrase set — this phone's security chip didn't respond, so the chip's part isn't set up yet."
                + " Opening Owner settings with this passphrase sets it up once the chip responds.", OwnerVerifyForm.ENROL_NO_CHIP_LINE);

        // NWP-20261120-04 (#26): the lost chip key, by exactly two signals, and never for anything else.
        final String K = rep('d'), K2 = rep('e');
        final int UNK = OwnerVerifyForm.ALIAS_UNKNOWN, PRE = OwnerVerifyForm.ALIAS_PRESENT, MIS = OwnerVerifyForm.ALIAS_MISSING;
        eq("ALIAS_* pairwise distinct", 3, new java.util.HashSet<>(java.util.Arrays.asList(UNK, PRE, MIS)).size());
        eq("lostKey: alias missing", true, OwnerVerifyForm.lostKey(true, K, MIS, ""));
        eq("lostKey: alias missing, kcvNow null", true, OwnerVerifyForm.lostKey(true, K, MIS, null));
        eq("lostKey: alias present, key changed", true, OwnerVerifyForm.lostKey(true, K, PRE, K2));
        eq("lostKey: alias present, one digit off", true, OwnerVerifyForm.lostKey(true, K, PRE, K.substring(0, 63) + 'e'));
        eq("lostKey: no StrongBox, alias missing", false, OwnerVerifyForm.lostKey(false, K, MIS, ""));
        eq("lostKey: no StrongBox, key changed", false, OwnerVerifyForm.lostKey(false, K, PRE, K2));
        eq("lostKey: no stored kcv, alias missing", false, OwnerVerifyForm.lostKey(true, "", MIS, ""));
        eq("lostKey: null stored kcv, alias missing", false, OwnerVerifyForm.lostKey(true, null, MIS, ""));
        eq("lostKey: no stored kcv, chip answers", false, OwnerVerifyForm.lostKey(true, "", PRE, K2));
        eq("lostKey: alias present, kcv equal", false, OwnerVerifyForm.lostKey(true, K, PRE, K));
        eq("lostKey: alias present, chip silent", false, OwnerVerifyForm.lostKey(true, K, PRE, ""));
        eq("lostKey: alias present, chip silent (null)", false, OwnerVerifyForm.lostKey(true, K, PRE, null));
        eq("lostKey: Keystore threw, chip silent", false, OwnerVerifyForm.lostKey(true, K, UNK, ""));
        eq("lostKey: Keystore threw, a different kcvNow", false, OwnerVerifyForm.lostKey(true, K, UNK, K2));
        eq("LOST_KEY_TITLE", "Set up Owner settings again", OwnerVerifyForm.LOST_KEY_TITLE);
        eq("LOST_KEY_LINE", "This phone's security chip no longer has the key that protected Owner settings, so the device passphrase"
                + " can't be checked. Set a new device passphrase. Messages and calls for the unassigned line that arrived before"
                + " now can't be opened.", OwnerVerifyForm.LOST_KEY_LINE);

        // NWP-20261120-04: owner.conf's body, with and without a kcv, read back by ChooserActivity's own readOwnerConf.
        eq("KCV_CONST", "nowhere-owner-kcv-v1", OwnerConf.KCV_CONST);
        final String salt = "0123456789abcdef0123456789abcdef", old4 = "v1\nsalt=" + salt + "\nverifier=" + S + "\nfails=3\nlast=42\n";
        eq("body, empty kcv: the old four-field bytes", old4, OwnerConf.body(salt, S, 3, 42, ""));
        eq("body, null kcv: the old four-field bytes", old4, OwnerConf.body(salt, S, 3, 42, null));
        eq("body, empty kcv: no kcv= line", false, OwnerConf.body(salt, S, 3, 42, "").contains("kcv="));
        eq("body, a kcv: its line last", old4 + "kcv=" + K + "\n", OwnerConf.body(salt, S, 3, 42, K));
        java.util.HashMap<String, String> m = readBack(OwnerConf.body(salt, S, 3, 42, ""));
        eq("read back, no kcv: parsed", true, m != null);
        if (m != null) {
            eq("read back, no kcv: salt", salt, m.get("salt"));
            eq("read back, no kcv: verifier", S, m.get("verifier"));
            eq("read back, no kcv: fails", "3", m.get("fails"));
            eq("read back, no kcv: last", "42", m.get("last"));
            eq("read back, no kcv: no kcv key", false, m.containsKey("kcv"));
        }
        m = readBack(OwnerConf.body(salt, S, 0, 0, K));
        eq("read back, a kcv: parsed", true, m != null);
        if (m != null) eq("read back, a kcv: kcv", K, m.get("kcv"));
        eq("read back, a kcv not 64 hex: damaged", null, readBack(old4 + "kcv=xyz\n"));
        eq("read back, an empty kcv line: damaged", null, readBack(old4 + "kcv=\n"));
        eq("read back, a kcv of upper-case hex: damaged", null, readBack(old4 + "kcv=" + K.toUpperCase() + "\n"));

        System.out.println(failed == 0 ? "OwnerVerifyFormCases: all passed" : "OwnerVerifyFormCases: " + failed + " FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
