package main

import "testing"

// TestRotateVerbRefusesABelowFloorPassphrase (NWP-20261115-04): the daemon's ROTATE applies the passphrase floor
// to the NEW passphrase, as create and promote do (docs/credential-tiers.md tier 1a). A below-floor change answers
// WEAK <reason> before the session marker, the keyguard or the store is touched, so the head stays keyed by the old
// passphrase and nobody can open the profile with the weak one. NOWHERE_PASS_FLOOR=0 bypasses the floor here as it
// does everywhere else. The reason is computed with passphraseStrong, never pinned as text.
func TestRotateVerbRefusesABelowFloorPassphrase(t *testing.T) {
	dest := capRotateFixture(t)
	calls := stubRekey(t, "OK")
	const name, oldp = "rotfloorprofile", "horse battery staple correct"
	const strong = "a completely different passphrase"
	if createVault("s3", name, oldp) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	liveMarker(t, dest, name, oldp, "10", "")

	// (a) A short new passphrase.
	ok, why := passphraseStrong(name, "1234")
	if ok {
		t.Fatal(`passphraseStrong accepts "1234"; this test needs a below-floor passphrase`)
	}
	if got := rotateVerb(t, dest, name, oldp, "1234"); got != "WEAK "+why {
		t.Errorf("rotation to a below-floor passphrase replied %q, want %q", got, "WEAK "+why)
	}

	// (b) The profile name as the new passphrase: long enough, refused by the name rule.
	ok, why = passphraseStrong(name, name)
	if ok {
		t.Fatal("passphraseStrong accepts the profile name; this test needs a below-floor passphrase")
	}
	if got := rotateVerb(t, dest, name, oldp, name); got != "WEAK "+why {
		t.Errorf("rotation to the profile name replied %q, want %q", got, "WEAK "+why)
	}

	// (c) A refused change touches nothing: no keyguard re-key, and the head is still keyed by the old passphrase.
	if len(*calls) != 0 {
		t.Errorf("a refused rotation re-keyed the keyguard %d time(s), want 0: %v", len(*calls), *calls)
	}
	if ok, err := headExistsStrict("s3", name, oldp); !ok || err != nil {
		t.Errorf("after a refused rotation, the old passphrase's head exists=%v err=%v, want true, nil", ok, err)
	}
	if ok, err := headExistsStrict("s3", name, "1234"); ok || err != nil {
		t.Errorf("after a refused rotation, the weak passphrase's head exists=%v err=%v, want false, nil", ok, err)
	}

	// (d) Control: a strong new passphrase goes through.
	if got := rotateVerb(t, dest, name, oldp, strong); got != "OK 0" {
		t.Fatalf("rotation to a strong passphrase replied %q, want OK 0", got)
	}

	// (e) The bypass: with the floor off, a below-floor change commits. The verb moved the marker to `strong`.
	t.Setenv("NOWHERE_PASS_FLOOR", "0")
	if got := rotateVerb(t, dest, name, strong, "1234"); got != "OK 0" {
		t.Errorf("with NOWHERE_PASS_FLOOR=0, rotation to a below-floor passphrase replied %q, want OK 0", got)
	}
}
