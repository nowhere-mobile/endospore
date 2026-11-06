package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260906-24. Recovery is the THIRD credential-change path, and it was missed by the two fixes that
// closed the same hole in the other two: NWP-20260906-02 (creation) and NWP-20260906-10 (rotation).
//
// With #91 on, `putHead` writes only THIS unit's head. So `recoverVault` published the recovered vault where
// only the recovering handset could see it, and nothing existed at profileRefV2(name, newpass) -- the ref
// every OTHER device derives. Those devices resolve nothing, and the login path renders nothing as a
// throwaway BLANK, indistinguishable BY DESIGN from a wrong passphrase.
//
// The user recovers their profile on one phone and it silently ceases to exist on every other one, at the
// exact moment they have already lost their passphrase.

// TestRecoveryPublishesAnAccountHeadAtTheNewCredential is the defect.
func TestRecoveryPublishesAnAccountHeadAtTheNewCredential(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, pass, newpass = "recacct", "the original passphrase here", "a brand new passphrase here"
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("fixture: no recovery phrase")
	}
	// Give this unit a lineage of its own, so the unit head and the account head genuinely diverge.
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("this unit's data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	// The ACCOUNT ref is what every other device derives from (name, newpass).
	if h := getRef(base, profileRefV2(name, newpass)); h == "" {
		t.Fatal("no ACCOUNT head at the recovered credential -- every device except the one that performed " +
			"the recovery resolves NOTHING, which the login path renders as a blank throwaway, and the user " +
			"has already lost the passphrase that would prove otherwise")
	}
	// And it must actually open: a head that does not parse is no better than an absent one.
	v, isV := parseVault(getHeadBlob(base, getRef(base, profileRefV2(name, newpass))))
	if !isV {
		t.Fatal("the account head at the recovered credential is not a vault")
	}
	if openVaultDK(v, name, newpass) == nil {
		t.Fatal("the account head does not open with the NEW passphrase")
	}
}

// TestRecoveryIsReachableFromASecondLineage is the same property stated the way a user meets it: a DIFFERENT
// handset, which has never sealed and so has no unit head of its own, must be able to sign in afterwards.
func TestRecoveryIsReachableFromASecondLineage(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, pass, newpass = "recreach", "the original passphrase here", "a brand new passphrase here"
	mnemonic := createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	// A SECOND handset: a different unit id, no unit head of its own.
	unitIDPath = filepath.Join(t.TempDir(), "unit-id-2")
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("a second handset cannot open the profile after a recovery -- it derives its own unit head " +
			"(absent), falls through to the account ref (never written) and gets a blank")
	}
	// ⚠ NOTE WHAT IS *NOT* ASSERTED HERE. I first wrote a check that the OLD passphrase stops working, and
	// it failed -- because recovery STRUCTURALLY cannot revoke it. recoverVault(base, name, mnemonic,
	// newpass) never learns the old credential, and profileRefV2 is keyed on it, so the old head cannot
	// even be addressed to tombstone. rotateVault CAN revoke (NWP-20260906-05) precisely because it holds
	// both passphrases. The limitation is real, undocumented, and filed rather than asserted away.
}

// TestRecoveryWithTheFlagOffIsUnchanged: the fleet runs with #91 off, where putHead already IS the account
// head. The extra publish must be inert there, not a second write that could differ.
func TestRecoveryWithTheFlagOffIsUnchanged(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "recoff", "the original passphrase here", "a brand new passphrase here"
	mnemonic := createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("the profile does not open at the new passphrase with the flag off")
	}
}
