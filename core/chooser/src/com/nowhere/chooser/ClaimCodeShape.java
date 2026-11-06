package com.nowhere.chooser;

/**
 * NWP-20261125-14 (h55 #1, docs/product-decisions.md 2026-11-03): the shape of a claim code, checked at the create
 * tap before anything is sent. The rule mirrors nowhere-cloud cmd/storefront/checkout.go newClaimCode, the only
 * minter: 18 random bytes as base64.RawURLEncoding, so exactly 24 characters, each in [A-Za-z0-9_-], no padding.
 * The agent's claimCodeWellFormed holds the same rule. Pure java.lang, so test-claim-code-shape-java.sh compiles it.
 */
final class ClaimCodeShape {
    private ClaimCodeShape() {}

    static boolean wellFormed(String code) {
        if (code == null || code.length() != 24) return false;
        for (int i = 0; i < code.length(); i++) {
            char c = code.charAt(i);
            boolean ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || c == '-' || c == '_';
            if (!ok) return false;
        }
        return true;
    }
}
