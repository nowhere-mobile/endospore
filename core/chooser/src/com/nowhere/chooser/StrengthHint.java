package com.nowhere.chooser;

/**
 * The live strength hint line for a CHECK-PASSPHRASE reply (NWP-20261116-25, docs/credential-tiers.md tier 1a: a
 * refusal is never the first feedback). CHECK-PASSPHRASE answers from passphraseStrong(name, pass), the same floor
 * ROTATE enforces before it reads the session, so the hint and the refusal cannot disagree. The words are
 * ReplyCopy.strength's, never new ones: "✓ " before a strong verdict, "• " before a weak one, no prefix when the
 * daemon did not answer. Pure java, no android.* import: test-change-pass-hint-java.sh compiles it with ReplyCopy.
 */
final class StrengthHint {
    private StrengthHint() {}

    static String line(String reply) {
        ReplyCopy.Strength st = ReplyCopy.strength(reply);
        if (st.state == ReplyCopy.State.STRONG) return "✓ " + st.text;
        if (st.state == ReplyCopy.State.WEAK) return "• " + st.text;
        return st.text;
    }

    static boolean strong(String reply) {
        return ReplyCopy.strength(reply).state == ReplyCopy.State.STRONG;
    }
}
