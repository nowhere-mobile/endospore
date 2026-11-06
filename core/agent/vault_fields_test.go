package main

import (
	"reflect"
	"sort"
	"strings"
	"testing"
)

// TestVaultFieldsAreClassified is a maintenance guard, not a behaviour test, and it exists because of how
// NWP-20260915-02 happened.
//
// The two credential-change paths are not symmetric. rotateVault MUTATES the vault it read, so every field
// it does not touch survives for free. recoverVault BUILDS A NEW ONE with buildVault and hand-carries a list
// of fields -- and a hand-carried list is a list someone can forget to extend. `Scopes` is now on that list,
// and the cost of a future field being forgotten is exactly this bug again: silent, because a dropped index
// is indistinguishable from a profile that predates the index.
//
// So every exported field of `vault` must land in exactly one of three buckets below. Adding a field to the
// struct without deciding which bucket it belongs to fails this test with a message that says so. The test
// deliberately asserts on NAMES rather than behaviour: it cannot tell you the carry is correct, only that
// somebody made a decision about it.
func TestVaultFieldsAreClassified(t *testing.T) {
	// BUILT: set by buildVault from its arguments on every rebuild, so there is nothing to carry.
	built := map[string]string{
		"V":           "schema version, literal 1",
		"Slots":       "the point of a rebuild -- a NEW pass slot + the recovery slot",
		"Manifest":    "passed in by the caller (the recovered/rotated head's manifest)",
		"RecoveryRef": "f(name, entropy), unchanged by a credential change",
	}
	// CARRIED: copied by carryForward. If you add a field here you must add the line there.
	carried := map[string]string{
		"Version":    "BUMPED, not copied -- a rebuild publishes a new head and a reset would read as a rollback",
		"LastSeal":   "when the profile was last active; survives a credential change",
		"History":    "#58 rollback snapshots",
		"HeadKind":   "#58 the live head's kind",
		"TelPub":     "#135 telephony pubkey, published in the SIM binding",
		"TelPriv":    "#135 telephony privkey, sealed under the DK, which a rebuild does not change",
		"Scopes":     "NWP-20260915-02 the scope index -- sealed under the DK, so it survives a rebuild",
		"ReleaseGen": "NWP-20261029-04 the release generation -- a rebuild must not make other handsets miss a release",
	}
	// RESET: deliberately NOT carried. Each entry is a decision, recorded so it cannot be mistaken for an
	// oversight later -- which is the failure mode this whole test exists to prevent.
	reset := map[string]string{
		"Sig": "re-computed by signVault over the NEW header; carrying it would carry a signature that no " +
			"longer matches",
		"Hardened": "a recovery re-adds a pass slot, so the vault is by definition no longer pass-only-dropped; " +
			"carrying true would mark a vault hardened that is not",
		"Pin": "NOT carried today, and this is a classification of existing behaviour rather than a change " +
			"made here: a recovery drops the remembered session PIN, so the user sets one again. Defensible " +
			"(a credential reset resetting the local convenience factor), but it was never written down as a " +
			"decision -- if it should be carried, that is its own slice with its own test",
	}

	var unclassified []string
	rt := reflect.TypeOf(vault{})
	for i := 0; i < rt.NumField(); i++ {
		f := rt.Field(i)
		if f.PkgPath != "" {
			continue // unexported: not part of the stored shape
		}
		n := f.Name
		in := 0
		for _, m := range []map[string]string{built, carried, reset} {
			if _, ok := m[n]; ok {
				in++
			}
		}
		switch {
		case in == 0:
			unclassified = append(unclassified, n)
		case in > 1:
			t.Errorf("vault field %q is in more than one bucket -- it can only be built, carried or reset", n)
		}
	}
	sort.Strings(unclassified)
	if len(unclassified) > 0 {
		t.Fatalf("vault gained %d field(s) that nothing classifies: %s\n"+
			"\tDecide which bucket each belongs to in this test, and if it is CARRIED add the line to "+
			"carryForward() too. A field that is neither built nor carried is silently DROPPED by every "+
			"rebuild path (recoverVault), and a dropped field is indistinguishable from a profile that "+
			"predates it -- which is how NWP-20260915-02 stayed invisible.",
			len(unclassified), strings.Join(unclassified, " "))
	}
}

// TestCarryForwardActuallyCarries is the behavioural half: every field the test above calls CARRIED must
// survive carryForward with a non-zero value. It plants a sentinel in each and checks it arrives, so a
// carryForward line that is deleted or mistyped is caught by more than a name list.
func TestCarryForwardActuallyCarries(t *testing.T) {
	old := &vault{
		Version:  7,
		LastSeal: 1234567890,
		History:  []headSnap{{}},
		HeadKind: "manual",
		TelPub:   "tel-pub-sentinel",
		TelPriv:  "tel-priv-sentinel",
		Scopes:   "scope-index-sentinel",
	}
	nv := &vault{}
	carryForward(old, nv)

	if nv.Version != old.Version+1 {
		t.Errorf("Version: got %d, want %d (a rebuild BUMPS, so the anchor does not read a rollback)", nv.Version, old.Version+1)
	}
	if nv.LastSeal != old.LastSeal {
		t.Error("LastSeal was not carried")
	}
	if len(nv.History) != len(old.History) {
		t.Error("History was not carried -- the #58 rollback snapshots would be lost by a recovery")
	}
	if nv.HeadKind != old.HeadKind {
		t.Error("HeadKind was not carried")
	}
	if nv.TelPub != old.TelPub || nv.TelPriv != old.TelPriv {
		t.Error("the #135 telephony keypair was not carried -- the DK is unchanged, so it stays valid")
	}
	if nv.Scopes != old.Scopes {
		t.Fatal("THE SCOPE INDEX WAS NOT CARRIED. A rebuild that drops it puts the profile straight back " +
			"into NWP-20260915-02 -- every scope unfindable after the next recovery -- and does so silently, " +
			"because an absent index reads as a profile that predates the index.")
	}
}
