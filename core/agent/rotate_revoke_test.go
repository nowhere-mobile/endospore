package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20260906-05. docs/backlog.md and docs/multi-device.md both described the #91 keyslot gap as "applies
// to the ACTING unit's head only" -- a propagation delay. It was worse: it did not take effect on the acting
// unit either. With the flag on, putHead resolves to unitHeadRef(name, NEWpass, thisUnit) while the
// revocation loop tombstoned only the v2/legacy refs, so unitHeadRef(name, OLDpass, thisUnit) -- written by
// every prior seal on this device -- kept resolving, and headRef probes the unit ref FIRST.
//
// The old passphrase therefore still opened the profile ON THE PHONE THAT ROTATED, to CURRENT data: the old
// vault blob is untouched, its pass slot still wraps the same DK, and rotateVault re-wraps that same DK over
// the same manifest.

// TestRotationRevokesTheOldPassphraseOnTheActingUnit is the security assertion.
func TestRotationRevokesTheOldPassphraseOnTheActingUnit(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldpass, newpass = "rotu", "the old passphrase", "a brand new passphrase"

	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	createVault(base, name, oldpass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, oldpass, src) // adopts to THIS unit's head, under the OLD passphrase

	if getRef(base, unitHeadRef(name, oldpass, deviceUnitID())) == "" {
		t.Fatal("fixture: no unit head under the old passphrase after a seal")
	}

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	// THE ASSERTION: the old passphrase must no longer resolve, on this very device.
	if _, _, ok := resolveKey(base, name, oldpass); ok {
		t.Fatal("the OLD passphrase still opens this profile on the phone that rotated it -- rotation " +
			"revoked nothing here, so \"change my passphrase\" is not a security control")
	}
	// ...and the new one must.
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("the NEW passphrase does not open the profile after rotation -- the rotation locked the user out")
	}
}

// TestRotationStillWorksWithTheFlagOff pins that the fleet's behaviour is unchanged: multiDeviceEnabled() is
// off everywhere shipped, and this fix must be inert there.
func TestRotationStillWorksWithTheFlagOff(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldpass, newpass = "rotoff", "the old passphrase", "a brand new passphrase"
	createVault(base, name, oldpass)

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault with the flag off: %v", err)
	}
	if _, _, ok := resolveKey(base, name, oldpass); ok {
		t.Fatal("the old passphrase still resolves with the flag off")
	}
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("the new passphrase does not resolve with the flag off")
	}
}

// TestRotationRefusesWhenTheAccountHasSeveralLineages. A rotation reaches only the heads THIS unit writes,
// and cross-lineage credential sync is unbuilt -- a remote unit's `se` slot mixes that handset's own
// secure-element secret and cannot be re-wrapped from here at all. A stated refusal beats reporting success
// while the old passphrase still opens the account on another phone.
func TestRotationRefusesWhenTheAccountHasSeveralLineages(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldpass, newpass = "rotmulti", "the old passphrase", "a brand new passphrase"

	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	createVault(base, name, oldpass)
	dk := resolveDK(base, name, oldpass, nil)
	if dk == nil {
		t.Fatal("fixture: no DK")
	}
	// Two enrolled lineages: this device, and one it has never met.
	writeAccountDir(base, name, oldpass, dk, &accountDir{Units: []unitEntry{
		{ID: deviceUnitID(), Label: "this phone", Edition: "endospore", Added: time.Now().Unix()},
		{ID: "a-second-handset", Label: "the other phone", Edition: "endospore", Added: time.Now().Unix()},
	}})

	_, err := rotateVault(base, name, oldpass, newpass, nil, true)
	if err == nil {
		t.Fatal("rotation SUCCEEDED on a two-lineage account -- the other phone keeps a vault whose pass slot " +
			"still wraps the same DK under the OLD passphrase, so this reports success while the old " +
			"passphrase still opens the account")
	}
	// And it must not have half-applied: the old passphrase still works, because nothing was rotated.
	if _, _, ok := resolveKey(base, name, oldpass); !ok {
		t.Fatal("the refusal still disturbed the profile -- a refused rotation must change nothing")
	}
	if _, _, ok := resolveKey(base, name, newpass); ok {
		t.Fatal("a refused rotation nevertheless published a head under the new passphrase")
	}
}
