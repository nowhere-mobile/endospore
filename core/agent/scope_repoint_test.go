package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// sealScopeFixture creates a profile, seals the bare vault and one #de scope, and returns the mnemonic.
func sealScopeFixture(t *testing.T, base, name, pass string) string {
	t.Helper()
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	for _, suf := range []string{"", "#de"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name+suf, pass, d)
	}
	// ⚠ A SECOND BARE SEAL, AND IT IS NOT PADDING (NWP-20260915-18). The scope index is minted by
	// createVault, i.e. at a moment when no scope is on the store yet, so every entry starts DERIVED. A bare
	// seal upgrades an entry to OBSERVED once the head resolves -- and roamd pushes the bare vault BEFORE the
	// scopes (nowhere_roamd.sh `_push vault` then `_push de`), which the loop above reproduces. So the seal
	// that sealed #de could not yet see it, exactly as in production, and one more cycle is what records it.
	//
	// That makes this fixture a profile that has been USED -- the 120s seal loop runs constantly, so every
	// real profile is one. A profile that has sealed exactly once in its life is the case the guard cannot
	// cover, and TestATombstoneIsNotEvidenceUntilSomebodySawTheScope pins that boundary directly.
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, d)
	return mnemonic
}

// TestRepointPreservesTheScopeKey is the invariant the whole design rests on: THE SCOPE DATA KEY IS CARRIED,
// NEVER RE-DERIVED.
//
// A re-pointed scope head is a vault whose `pass` slot wraps the ORIGINAL key under deriveKey(scoped,
// newpass). So after a recovery there are two different values in play and they are easy to confuse:
//
//	deriveKey(scoped, newpass) -- the KEK that OPENS the wrapper
//	the original scope key     -- what the wrapper CONTAINS, and what the data is sealed under
//
// If the index records the first, everything still works -- until the NEXT recovery, which would re-point
// using a KEK as if it were the key and publish a head whose manifest is gibberish. The damage would surface
// one credential change later, on a user who had already lost a phone once.
//
// ⚠ This test exists because an earlier version of TestRecoveryCarriesTheIndexEndToEnd did NOT catch that
// mutation: its fixture never sealed a scope, so repointScopes took the "never sealed" branch, where the
// recorded key legitimately IS deriveKey(scoped, newpass) and the two values coincide.
func TestRepointPreservesTheScopeKey(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "repointkey", "horse battery staple correct", "a brand new passphrase"
	mnemonic := sealScopeFixture(t, base, name, pass)

	originalKey, _, ok := resolveKey(base, name+"#de", pass)
	if !ok {
		t.Fatal("precondition: #de does not resolve before the recovery")
	}
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	dk, _, ok := resolveKey(base, name, newpass)
	if !ok {
		t.Fatal("vault does not resolve after recovery")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, newpass))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index after recovery")
	}
	recorded, ok := unwrap(kekScopes(dk), idx["#de"].Wrapped)
	if !ok {
		t.Fatal("#de: the recorded key does not unwrap")
	}

	if string(recorded) != string(originalKey) {
		t.Error("#de: THE INDEX DOES NOT RECORD THE PRESERVED SCOPE KEY. The data is still sealed under the " +
			"original key, so a later recovery re-pointing with this value would publish a head whose " +
			"manifest cannot be decrypted -- and it would only surface one credential change from now.")
	}
	// The discriminating half: the recorded value must NOT be the new KEK. Without this the test passes for
	// a scope that was never sealed, where the two happen to be equal.
	if string(recorded) == string(deriveKey(name+"#de", newpass)) {
		t.Error("#de: the index recorded deriveKey(scoped, newpass) -- that is the KEK that OPENS the " +
			"wrapper, not the key the data is sealed under")
	}
	// ...and the re-pointed head must actually hand that key back.
	if got, _, ok := resolveKey(base, name+"#de", newpass); !ok {
		t.Error("#de does not resolve after the re-point")
	} else if string(got) != string(originalKey) {
		t.Error("#de resolves, but to a different key than the data was sealed under")
	}
}

// TestRepointRefusesATombstonedScope pins the backlog:287 guard. delRef leaves an empty object that EXISTS,
// so "resolves empty" and "was never created" are different states, and a DELETE tombstone must never be
// mistaken for an unused scope. Skipping one silently would publish a recovered profile that reports success
// while a scope quietly went missing.
func TestRepointRefusesATombstonedScope(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "repointtomb", "horse battery staple correct", "a brand new passphrase"
	sealScopeFixture(t, base, name, pass) // the mnemonic is not needed: this test drives repointScopes directly

	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("vault does not resolve")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index to work from")
	}

	// Tombstone the #de head the way a delete does: empty value, ref still present.
	putRef(base, idx["#de"].Ref, "")
	if !refExists(base, idx["#de"].Ref) {
		t.Fatal("FIXTURE BROKE: the #de scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
	}

	_, _, err := repointScopes(base, name, idx, newpass, dk, "", nil) // "": the RECOVERY shape, which is what this test drives
	if err == nil {
		t.Fatal("repointScopes SKIPPED A TOMBSTONED SCOPE AND REPORTED SUCCESS. An empty-but-present ref is " +
			"a delete tombstone, not an unused scope; treating it as 'nothing to do' publishes a recovered " +
			"profile with a scope silently missing.")
	}
	if !errors.Is(err, ErrScopeTombstoned) {
		t.Errorf("wrong error for a tombstoned scope: %v", err)
	}
}

// TestRotationPreservesTheScopes: a rotation moves every scope head for the same reason it moves the bare
// one, and until NWP-20260915-02 it survived that by ACCIDENT -- the acting handset still held the data live,
// so the next seal simply re-created each scope under the new credential. That silently orphaned the old
// scope objects and lost outright anything not live on this device (un-materialised on-demand media, or a
// scope another handset owns). Here the fixture seals #de and then rotates WITHOUT re-sealing, which is the
// case the accident never covered.
func TestRotationPreservesTheScopes(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "rotscope", "horse battery staple correct", "a brand new passphrase"
	sealScopeFixture(t, base, name, pass)

	originalKey, _, ok := resolveKey(base, name+"#de", pass)
	if !ok {
		t.Fatal("precondition: #de does not resolve before the rotation")
	}
	if _, err := rotateVault(base, name, pass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	got, _, ok := resolveKey(base, name+"#de", newpass)
	if !ok {
		t.Fatal("#de IS UNREACHABLE AFTER A ROTATION. The scope head is still at the OLD passphrase's ref, " +
			"and nothing re-points it -- so any data not live on this handset is stranded.")
	}
	if string(got) != string(originalKey) {
		t.Error("#de resolves after the rotation, but to a different key than its data was sealed under")
	}
}

// TestDeleteReachesRepointedScopes proves the purge path still works after a recovery has moved every scope
// head. It matters because delete derives its refs from (name, pass) while the index RECORDS them: if those
// two ever disagreed, a delete would report success while leaving billed, unreachable objects behind -- and
// that drift would be invisible until someone audited the bucket.
func TestDeleteReachesRepointedScopes(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "delrepoint", "horse battery staple correct", "a brand new passphrase"
	mnemonic := sealScopeFixture(t, base, name, pass)
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	if _, _, ok := resolveKey(base, name+"#de", newpass); !ok {
		t.Fatal("precondition: #de did not survive the recovery")
	}
	// What delete derives must be what the re-point published.
	dk, _, _ := resolveKey(base, name, newpass)
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, newpass))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index after the recovery")
	}
	for _, suf := range []string{"#de"} {
		derived, _ := headWriteRef(name+suf, newpass)
		if idx[suf].Ref != derived {
			t.Fatalf("%s: the index records %q but deleteProfile would derive %q -- the purge would miss it",
				suf, idx[suf].Ref, derived)
		}
	}
	deleteProfile(base, name, newpass)
	if _, _, ok := resolveKey(base, name+"#de", newpass); ok {
		t.Error("#de still resolves after deleteProfile -- the re-pointed head was not purged")
	}
}
