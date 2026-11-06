package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20260906-11. seal_fence.go states this bug in its own words: the fence covers the per-unit heads and
// "the PURGE does not", which "makes a multi-device build LOOK fixed while the refs survive". deleteProfile
// appended sealFenceUnitKeys to the FENCE set and iterated only `scoped` for the tombstones and the verify,
// so delete reported "deleted (all scopes purged + verified)" while every lineage's heads stayed live.
//
// On an amnesiac device delete is the one verb whose entire promise is that nothing survives.
//
// ⚠ refExists reports a TOMBSTONE as existing, so these tests read the VALUE (getRef) rather than existence
// -- the distinction that made the on-device check inconclusive on 2026-09-06.

func liveRef(base, ref string) bool { return getRef(base, ref) != "" }

// TestDeletePurgesThisUnitsHeads: the acting device's per-unit heads must stop resolving.
func TestDeletePurgesThisUnitsHeads(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, pass = "delunit", "correct horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src) // adopts to this unit's head

	uref := unitHeadRef(name, pass, deviceUnitID())
	if !liveRef(base, uref) {
		t.Fatal("fixture: no unit head after the seal")
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want deleted", got)
	}
	if liveRef(base, uref) {
		t.Fatal("this unit's head STILL RESOLVES after a delete that reported success -- the fence covered " +
			"it and the purge did not, so the profile comes back at the next login")
	}
}

// TestDeletePurgesEVERYLineagesHeads is the half sealFenceUnitKeys structurally could not reach: it derives
// from deviceUnitID(), so it only ever named the acting handset. Another lineage's heads are only findable
// through the account directory.
func TestDeletePurgesEVERYLineagesHeads(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, pass = "delmulti", "correct horse battery staple"
	createVault(base, name, pass)
	dk := resolveDK(base, name, pass, nil)
	if dk == nil {
		t.Fatal("no DK")
	}
	const other = "a-second-handset-unit-id"
	writeAccountDir(base, name, pass, dk, &accountDir{Units: []unitEntry{
		{ID: deviceUnitID(), Label: "this phone", Added: time.Now().Unix()},
		{ID: other, Label: "the other phone", Added: time.Now().Unix()},
		{ID: "a-retired-handset", Label: "old phone", Added: time.Now().Unix(), Retired: true},
	}})

	// Plant heads for the other two lineages, as their own seals would have.
	otherRef := unitHeadRef(name, pass, other)
	retiredRef := unitHeadRef(name, pass, "a-retired-handset")
	putRef(base, otherRef, postBlob(base, []byte("the other phone's head")))
	putRef(base, retiredRef, postBlob(base, []byte("the retired phone's head")))

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want deleted", got)
	}
	if liveRef(base, otherRef) {
		t.Fatal("ANOTHER lineage's head still resolves after delete -- sealFenceUnitKeys can only name this " +
			"handset, so the other devices' data survives a delete that reported success")
	}
	if liveRef(base, retiredRef) {
		t.Fatal("a RETIRED lineage's head still resolves after delete -- a retired unit keeps its head " +
			"precisely so it stays restorable, which is the opposite of what a delete may leave")
	}
}

// TestDeletePurgesTheAccountDirectory. accountDirRef is in no footprint and was in no delete path, so it
// survived every delete -- a sealed list of the user's devices left behind by the verb that promises nothing is.
func TestDeletePurgesTheAccountDirectory(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, pass = "deldir", "correct horse battery staple"
	createVault(base, name, pass)
	dk := resolveDK(base, name, pass, nil)
	if dk == nil {
		t.Fatal("no DK")
	}
	writeAccountDir(base, name, pass, dk, &accountDir{Units: []unitEntry{
		{ID: deviceUnitID(), Label: "this phone", Added: time.Now().Unix()},
	}})
	if !liveRef(base, accountDirRef(name, pass)) {
		t.Fatal("fixture: no account directory")
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want deleted", got)
	}
	if liveRef(base, accountDirRef(name, pass)) {
		t.Fatal("the account directory survives a delete -- it is a sealed list of the user's devices, and " +
			"it is in no footprint either, so nothing else would ever collect it")
	}
}

// TestDeleteWithTheFlagOffIsUnchanged: the fleet runs with #91 off and must behave exactly as before.
func TestDeleteWithTheFlagOffIsUnchanged(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "deloff", "correct horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile with the flag off = %q, want deleted", got)
	}
	if liveRef(base, profileRefV2(name, pass)) {
		t.Fatal("the bare head still resolves after a flag-off delete")
	}
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("the profile still opens after a flag-off delete")
	}
}
