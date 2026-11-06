package main

import "testing"

// NWP-20260819-03: FETCH-APP's OK reply carries the daemon-resolved signer as a fixed third token, so the
// chooser can pin provenance on the DAEMON's authority rather than a caller-supplied hex (which a hostile
// binder client stripped with ""). Since NWP-20261030-04 that token is always the 64-hex pin: an entry without
// one is refused with ERR-NOSIGNER before the OK line, so there is no "-" token any more.
func TestFetchAppSignerToken(t *testing.T) {
	const want = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	got := fetchAppSigner(&catalogEntry{SigningCert: "  " + "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF" + "  "})
	if got != want {
		t.Errorf("signer = %q, want the trimmed lower-case pin", got)
	}
	if got == "-" || len(got) != 64 {
		t.Errorf("signer = %q, want 64 hex and never the old \"-\" token", got)
	}
}
