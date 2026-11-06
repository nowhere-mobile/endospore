package main

import (
	"path/filepath"
	"testing"
)

// NWP-20260906-02. #91's gated per-unit head model is written around the ACCOUNT head existing: putHead calls
// it "the safety net + the source a not-yet-sealed device adopts from", and headRef's ladder
// (unit -> v2 -> legacy) leans on that fallback so a device that has never sealed can still SEE the account.
//
// That precondition held for a MIGRATED profile and never held for a CREATED one, because createVault ->
// putHead took the per-unit short-circuit. TestPerUnitHeadMigration does not catch it: it plants its v2 head
// BY HAND (`putRef(base, profileRefV2(name, pass), legacy)`) and never calls createVault. Build-300 proved
// migration on hardware; creation under the flag was exercised nowhere.
//
// These tests pin the rule the fix establishes: a path that publishes a NEW VAULT writes the ACCOUNT head;
// only a SEAL writes a per-unit head.

// asUnit points the per-device unit id at its own file, so one test process can act as two physical devices.
func asUnit(t *testing.T, dir string) {
	t.Helper()
	unitIDPath = filepath.Join(dir, "unit-id")
}

// TestFlagOnCreateIsReachableFromASecondUnit is the primary multi-device case: create an account on one
// phone, sign in on another. Before the fix the second device resolved NOTHING and the login path renders
// that as a throwaway blank -- indistinguishable, by design, from a wrong passphrase.
func TestFlagOnCreateIsReachableFromASecondUnit(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "twophones", "correct horse battery staple"

	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")

	// Phone A creates the account.
	dirA := t.TempDir()
	asUnit(t, dirA)
	if m := createVault(base, name, pass); m == "" {
		t.Fatal("createVault returned no recovery mnemonic")
	}
	unitA := deviceUnitID()

	// Phone B: a different handset, so a different unit id and its own (absent) unit head.
	asUnit(t, t.TempDir())
	if deviceUnitID() == unitA {
		t.Fatal("test bug: both units minted the same id")
	}
	if got := getRef(base, unitHeadRef(name, pass, deviceUnitID())); got != "" {
		t.Fatal("test bug: phone B already has a unit head")
	}

	// THE ASSERTION. B must resolve the account from (name, pass) alone.
	ref, val, _ := headRef(base, name, pass)
	if val == "" && getRef(base, ref) == "" {
		t.Fatalf("phone B resolves NOTHING for an account created on phone A -- headRef -> %q. The login path "+
			"renders this as a throwaway blank, indistinguishable from a wrong passphrase: two phones, one "+
			"account, two silently disjoint profiles", ref)
	}
	// And it must be openable -- reachability is worthless if the vault will not yield its DK, which is what
	// the slice-4b restore picker needs before it can list the account's other lineages.
	if dk := resolveDK(base, name, pass, nil); dk == nil {
		t.Fatal("phone B resolved a head but could not open it -- no DK, so openAccountDir cannot run and the " +
			"'Restore from another device' picker has no lineage list")
	}
}

// TestFlagOnCreateStillSealsToItsOwnUnitHead pins the other half: publishing the account head must NOT undo
// the per-unit model. Divergence begins at the FIRST SEAL, exactly as it does for a migrated profile.
func TestFlagOnCreateStillSealsToItsOwnUnitHead(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "stillperunit", "correct horse battery staple"

	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")

	asUnit(t, t.TempDir())
	createVault(base, name, pass)
	account := getRef(base, profileRefV2(name, pass))
	if account == "" {
		t.Fatal("creation did not publish the account head")
	}

	sealed := postBlob(base, []byte("unit A seal"))
	putHead(base, name, pass, sealed)

	if got := getRef(base, unitHeadRef(name, pass, deviceUnitID())); got != sealed {
		t.Fatal("the first seal did not adopt to this device's unit head -- the per-unit model is broken")
	}
	if got := getRef(base, profileRefV2(name, pass)); got != account {
		t.Fatal("the seal disturbed the account head, which must stay intact as the safety net a " +
			"not-yet-sealed device reads from")
	}
	if got := headKey(base, name, pass); got != unitHeadRef(name, pass, deviceUnitID()) {
		t.Fatalf("after sealing, reads must resolve to this device's unit head; got %s", got)
	}
}

// TestFlagOnHardeningIsNotBypassableViaTheAccountHead. enrollSE drops the pass-only keyslot so a captured
// store ciphertext is not offline-brute-forceable by passphrase alone. Writing the hardened vault to the UNIT
// head left the OLD vault -- pass slot intact -- at the account ref, which headRef falls through to for any
// device that has not sealed. The hardening was bypassable through its own fallback.
func TestFlagOnHardeningIsNotBypassableViaTheAccountHead(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "hardened", "correct horse battery staple"

	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")

	asUnit(t, t.TempDir())
	createVault(base, name, pass)
	if err := enrollSE(base, name, pass, []byte("this-device-secure-element-secret")); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}

	// Read the vault the ACCOUNT head points at -- the copy a second device would open.
	head := getRef(base, profileRefV2(name, pass))
	if head == "" {
		t.Fatal("no account head after hardening")
	}
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		t.Fatal("account head is not a vault")
	}
	if !v.Hardened {
		t.Fatal("the vault at the account head is NOT hardened -- hardening wrote only this unit's head, so " +
			"the account fallback still serves the pre-hardening vault")
	}
	for _, s := range v.Slots {
		if s.Kind == "pass" {
			t.Fatal("a `pass` keyslot survives at the account head after hardening -- the captured ciphertext " +
				"is still openable by passphrase alone, which is exactly what enrollSE exists to prevent")
		}
	}
	if dk := unwrapDK(v, "pass", deriveKey(name, pass)); dk != nil {
		t.Fatal("the account head's vault still unwraps its DK from the passphrase after hardening")
	}
}
