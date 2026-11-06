package main

// claimCodeWellFormed reports whether code has the shape of a claim code: exactly 24 characters, each in
// [A-Za-z0-9_-]. NWP-20261125-14 (h55 #1, docs/product-decisions.md 2026-11-03): the rule mirrors nowhere-cloud
// cmd/storefront/checkout.go newClaimCode, the only minter -- 18 random bytes as base64.RawURLEncoding, no padding.
// The gate's ClaimCodeShape.wellFormed holds the same rule. A non-ASCII rune has bytes >= 0x80, so it fails.
func claimCodeWellFormed(code string) bool {
	if len(code) != 24 {
		return false
	}
	for i := 0; i < len(code); i++ {
		c := code[i]
		if !('A' <= c && c <= 'Z' || 'a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
