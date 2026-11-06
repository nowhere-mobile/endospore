package main

// NWP-20260916-04: a credential change retires the scope heads it supersedes.
//
// DEVICE-OBSERVED 2026-09-16 on lynx 2026091501. A profile was rotated, then DELETED, then re-created at
// the ORIGINAL passphrase with no data added -- and its photos and downloads came back. repointScopes had
// deliberately left every superseded scope head resolving; deleteProfile only tombstones refs derived from
// the passphrase IT is given, so those were never in scope; and createVault derives an index that lands on
// exactly them.
//
// ⚠ THE EXPOSURE IS NOT ONLY STORAGE. A superseded head is still the ORIGINAL bare head under
// deriveKey(name#scope, oldpass), so an old passphrase is a working LOCATOR and a working KEY -- and a
// rotation is the operation you perform BECAUSE somebody may know that passphrase.

import (
	"os"
	"path/filepath"
	"testing"
)

// scopedProfile seals a bare profile plus one real scope, and returns the scope's head ref under `pass`.
func scopedProfile(t *testing.T, base, name, pass string) string {
	t.Helper()
	createVault(base, name, pass)
	for _, suf := range []string{"", "#de"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name+suf, pass, d)
	}
	ref, _ := headWriteRef(name+"#de", pass)
	if getRef(base, ref) == "" {
		t.Fatal("fixture did not seal #de -- the test would prove nothing about retiring it")
	}
	return ref
}

// TestARotationRetiresTheScopeHeadItSupersedes is the mechanism, at the seam.
func TestARotationRetiresTheScopeHeadItSupersedes(t *testing.T) {
	base := newHTTPStore(t)
	const name, p1, p2 = "retirerot", "horse battery staple correct", "a brand new passphrase"
	oldRef := scopedProfile(t, base, name, p1)

	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	if got := getRef(base, oldRef); got != "" {
		t.Errorf("the superseded #de head still resolves to %q. It is the ORIGINAL bare head, sealed under "+
			"deriveKey(name#de, oldpass), so anyone holding the old passphrase can both find AND open it -- "+
			"and a delete will never reach it, because deleteProfile only tombstones refs derived from the "+
			"passphrase it is given.", short(got))
	}
	// ...and the scope is still reachable under the NEW passphrase: retiring must not destroy the data.
	newRef, _ := headWriteRef(name+"#de", p2)
	if getRef(base, newRef) == "" {
		t.Fatal("the rotation retired the old #de head WITHOUT leaving a live one at the new passphrase -- " +
			"that is the unrecoverable outcome repointScopes' never-retire rule exists to prevent")
	}
}

// TestADeletedProfileStaysDeletedAfterARotation is the user-facing bug, end to end, in the exact order it
// was hit on the device: rotate, delete, re-create at the ORIGINAL passphrase, expect nothing.
func TestADeletedProfileStaysDeletedAfterARotation(t *testing.T) {
	base := newHTTPStore(t)
	const name, p1, p2 = "deletedstays", "horse battery staple correct", "a brand new passphrase"
	scopedProfile(t, base, name, p1)

	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if got := deleteProfile(base, name, p2); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want \"deleted\"", got)
	}

	// Re-create at the ORIGINAL passphrase -- the address the superseded heads were derived from.
	if createVault(base, name, p1) == "" {
		t.Fatal("re-create returned no recovery code")
	}
	oldRef, _ := headWriteRef(name+"#de", p1)
	if got := getRef(base, oldRef); got != "" {
		t.Fatalf("a profile re-created at the ORIGINAL passphrase found live #de data at %s after the "+
			"profile had been DELETED. The delete promise is the product's floor, and a rotation at any "+
			"point before the delete was defeating it.", short(got))
	}
}

// TestARecoveryRetiresTheScopeHeadItSupersedes covers the other credential change -- and the one that
// matters more, because you recover precisely when somebody may already hold the old passphrase.
//
// ⚠ A recovery cannot retire the old BARE head: deriving that ref needs the passphrase just lost. The
// scope refs are RECORDED in the index, so their locations are known without it -- which is why this half
// is reachable at all.
func TestARecoveryRetiresTheScopeHeadItSupersedes(t *testing.T) {
	base := newHTTPStore(t)
	const name, p1, p2 = "retirerec", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	mnemonic := ""
	{ // re-create the fixture but keep the recovery code
		deleteProfile(base, name, p1)
		mnemonic = createVault(base, name, p1)
		for _, suf := range []string{"", "#de"} {
			d := t.TempDir()
			if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
				t.Fatal(err)
			}
			pushProfile(base, name+suf, p1, d)
		}
	}
	oldRef, _ := headWriteRef(name+"#de", p1)
	if getRef(base, oldRef) == "" {
		t.Fatal("fixture did not seal #de")
	}

	if err := recoverVault(base, name, mnemonic, p2); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	if got := getRef(base, oldRef); got != "" {
		t.Errorf("the recovery left the superseded #de head resolving at %s -- readable by the old "+
			"passphrase, which is exactly the credential a recovery exists to replace", short(got))
	}
	newRef, _ := headWriteRef(name+"#de", p2)
	if getRef(base, newRef) == "" {
		t.Fatal("the recovery retired the old #de head without leaving a live one at the new passphrase")
	}
}

// TestANeverSealedScopeLeavesNoTombstone pins the narrowness. Retiring must touch only heads that were
// really MOVED -- deleteProfile follows the same rule ("only tombstone refs that exist: no litter for
// never-used scopes"), and a tombstone minted at a derived address nobody ever wrote is the shape
// NWP-20260915-18 spent a whole slice making harmless.
func TestANeverSealedScopeLeavesNoTombstone(t *testing.T) {
	base := newHTTPStore(t)
	const name, p1, p2 = "nolitter", "horse battery staple correct", "a brand new passphrase"
	scopedProfile(t, base, name, p1) // seals the bare profile and #de only

	mediaRef, _ := headWriteRef(name+"#media", p1) // never sealed
	if refExists(base, mediaRef) {
		t.Skip("fixture unexpectedly has a #media ref")
	}
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if refExists(base, mediaRef) {
		t.Error("the rotation minted a tombstone at a #media ref nothing had ever written. Only heads that " +
			"were actually moved may be retired.")
	}
}

// TestASamePassphraseRotationDoesNotRetireWhatItJustWrote pins the one guard that is NOT bookkeeping.
//
// Nothing rejects newpass == oldpass -- not rotateVault, not the chooser -- so a user can "change" a
// passphrase to the value it already has. Then headWriteRef(scoped, newpass) IS rec.Ref, and a retire pass
// that did not compare them would tombstone the very head repointScopes had just published: the scope
// destroyed by the operation meant to preserve it.
//
// ⚠ NOT A HYPOTHETICAL SHAPE. The bare head has carried exactly this guard for as long as the retire pass
// has existed -- `if retire && oldRef != newV2` -- and this is its scope-level twin. The guard was there
// because the case is reachable; the scopes simply had no retirement to guard until now.
func TestASamePassphraseRotationDoesNotRetireWhatItJustWrote(t *testing.T) {
	base := newHTTPStore(t)
	const name, p1 = "samepass", "horse battery staple correct"
	ref := scopedProfile(t, base, name, p1)

	if _, err := rotateVault(base, name, p1, p1, nil, true); err != nil {
		t.Fatalf("rotating to the same passphrase: %v", err)
	}
	if got := getRef(base, ref); got == "" {
		t.Fatal("a rotation to the SAME passphrase retired the #de head it had just written -- the old and " +
			"new refs are the same address, so retiring the 'superseded' one destroys the live scope. The " +
			"bare head guards this with `oldRef != newV2`; the scope retirement must do the same.")
	}
}

// TestARefusedRecoveryRetiresNothing: a recovery whose publish is REFUSED must leave the superseded scope
// head alone. If the new head never lands and the old one is tombstoned anyway, the scope is named by
// nothing under EITHER passphrase -- the unrecoverable outcome repointScopes' never-retire rule was written
// to avoid, reintroduced by the fix that retires.
//
// ⚠ WHAT THIS ACTUALLY PROVES, STATED EXACTLY, because the first version of this comment claimed more.
// Arming the fence bumps its SEQUENCE, so the scope head's own publish is refused too; repointScopes' step
// (d) read-back then fails, recoverVault takes its repointErr early return, and the retirement is never
// reached at all. So this pins the OUTCOME (a refused recovery retires nothing) by way of the early return
// -- it does NOT exercise the !sealFenceHit && !sealStaleHit gate at the retirement itself, and a mutation
// run confirms that: replacing that gate with `true` leaves this test green.
//
// The gate is kept regardless, mirroring rotateVault's, because it covers the case the early return does
// not: repointScopes succeeding on every scope while a LATER publish -- the bare head -- is refused as
// STALE. Nothing here reaches that, and it is recorded as a known-surviving mutant rather than hidden.
func TestARefusedRecoveryRetiresNothing(t *testing.T) {
	// ⚠ NOWHERE_STATE IS LOAD-BEARING HERE, NOT SETUP NOISE. sealFenceDir() is empty without it, and
	// armSealFence then returns TRUE having armed NOTHING ("inert off-device") -- so a `if !armSealFence`
	// guard passes, the publish is never refused, and the test asserts its own premise away. The first
	// draft of this test did exactly that.
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	const name, p1, p2 = "refusedrec", "horse battery staple correct", "a brand new passphrase"
	mnemonic := createVault(base, name, p1)
	for _, suf := range []string{"", "#de"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name+suf, p1, d)
	}
	oldRef, _ := headWriteRef(name+"#de", p1)
	if getRef(base, oldRef) == "" {
		t.Fatal("fixture did not seal #de")
	}

	// Refuse the recovery's own publish, the way the rotation test does.
	head := profileRefV2(name, p2)
	if !armSealFence([]string{head}) {
		t.Fatal("could not arm the seal fence")
	}
	if !sealFenceBlocks(head) {
		t.Fatal("the fence reports armed but does not block -- the refusal this test needs never happens, " +
			"and every assertion below would pass for the wrong reason")
	}
	t.Cleanup(func() {
		liftSealFence([]string{head})
		sealFenceHit = false
		clearSealExpectations()
	})

	_ = recoverVault(base, name, mnemonic, p2) // expected to refuse; the assertion is about the OLD ref

	if got := getRef(base, oldRef); got == "" {
		t.Fatal("a recovery whose publish was REFUSED retired the superseded #de head anyway. The new head " +
			"never landed, so the scope is now named by nothing under either passphrase -- which is the " +
			"exact unrecoverable outcome the never-retire rule existed to prevent.")
	}
}
