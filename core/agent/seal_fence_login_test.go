package main

// #144 / NW-af2c -- the login-side half of the publish fence.
//
// The fence is armed by an on-device delete and, until NWP-20260910-18, was lifted by exactly one caller:
// createVault. That is the on-device re-create path, so a name deleted on the handset and re-created
// ANYWHERE ELSE left the markers armed for the rest of the boot. The storefront import page is the one
// users actually hit: it mints the vault in the browser and PUTs it straight to the store, so nothing on
// the handset ever runs createVault for that name. The user logs in fine and can never log off, because
// every seal is refused at flush time. Reported on frankel 2026091001.
//
// These tests take the sequence in turns rather than racing it, and each asserts the user-visible outcome
// (the seal lands / the seal stays refused) rather than that a marker file moved.

import (
	"fmt"
	"os"
	"sort"
	"testing"
)

// asOtherDevice runs fn with NOWHERE_STATE pointed at a DIFFERENT RAM state dir, which is what "somewhere
// that is not this handset" means to the fence: sealFenceDir() is derived from it, and it is per-boot and
// per-device by construction. Deliberately NOT t.Setenv, whose restore is deferred to the end of the test;
// this has to be scoped to fn so the markers the delete left in THIS device's state are still there when
// the login runs.
func asOtherDevice(t *testing.T, fn func()) {
	t.Helper()
	saved, had := os.LookupEnv("NOWHERE_STATE")
	if err := os.Setenv("NOWHERE_STATE", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			os.Setenv("NOWHERE_STATE", saved)
		} else {
			os.Unsetenv("NOWHERE_STATE")
		}
	}()
	fn()
}

// sealDone models the seal having been a SEPARATE PROCESS, which it is: a push runs in the `push` CLI while
// the delete and the create run in the daemon, where pushFenceSeq/pushFenceSampled are never set. Leaving
// them set across a later create is not a stricter test but a WRONG one -- the create's own #142 purge arms
// and lifts, which moves the sequence, so createVault's putHead then refuses and the profile is created
// HEADLESS. seal_fence.go calls that asymmetry deliberate; TestInFlightSealRefusesEvenAfterRecreate depends
// on it. Cost me the first run of this file: the off-device re-create left no head at all.
func sealDone() { pushFenceSeq, pushFenceSampled = 0, false }

// fenceSnapshot renders every marker AND the sequence, so an assertion can say "this changed nothing" rather
// than "the one ref I thought to check is still armed". The narrower form let a mutation straight through:
// a scoped lift derives sealFenceRefKeys from "alice#de", so it clears alice#de's own marker and leaves the
// BARE one -- invisible to a bare-ref check, and a fence half-cleared by a name that never owned it.
func fenceSnapshot(t *testing.T) (int64, map[string]bool) {
	t.Helper()
	ents, err := os.ReadDir(sealFenceDir())
	if err != nil {
		t.Fatalf("fence dir: %v", err)
	}
	markers := map[string]bool{}
	for _, e := range ents {
		if e.Name() != sealFenceSeqName {
			markers[e.Name()] = true
		}
	}
	return sealFenceSeq(), markers
}

// fenceDrift renders what MOVED between two snapshots, not the fifteen hex refs that did not. A delete arms
// a marker per (scope x KDF generation), so a whole-set dump buries the two entries that are the finding.
func fenceDrift(beforeSeq, afterSeq int64, before, after map[string]bool) string {
	var gone, added []string
	for r := range before {
		if !after[r] {
			gone = append(gone, r[:12])
		}
	}
	for r := range after {
		if !before[r] {
			added = append(added, r[:12])
		}
	}
	sort.Strings(gone)
	sort.Strings(added)
	return fmt.Sprintf("seq %d->%d, %d marker(s) CLEARED %v, %d added %v",
		beforeSeq, afterSeq, len(gone), gone, len(added), added)
}

// THE WEDGE. Delete on this handset, re-create off it, log back in -- and the seal that logoff depends on
// must land. Without the lift in resolveKeyHeadForLogin this fails at the "left the publish fence armed"
// check, and then again on the seal, which is exactly how the bug presented in the field.
func TestLoginLiftsFenceAfterOffDeviceRecreate(t *testing.T) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1") // isolate the fence: the receipt and shrink guards are not the subject

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)
	pushProfile(base, name, pass, seedDir(t, 2))
	sealDone()

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	if !sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("setup: the delete did not arm the fence, so the rest of this test proves nothing")
	}

	// The web import. No createVault runs on this handset, so nothing lifts the markers the delete left in
	// this device's RAM state -- which is the whole bug.
	var webHead string
	asOtherDevice(t, func() {
		createVault(base, name, pass)
		webHead = getRef(base, profileRefV2(name, pass))
	})
	if webHead == "" {
		t.Fatal("setup: the off-device re-create left no head")
	}
	if !sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("setup: the off-device re-create cleared THIS device's fence -- the wedge is not reproduced")
	}

	// The login. roamd runs `nowhere_agent restore <store> <profile> ...`, and its head resolution is this.
	_, _, head, ok := resolveKeyHeadForLogin(base, name, pass)
	if !ok || head != webHead {
		t.Fatalf("login did not resolve the re-created head: ok=%v head=%q want %q", ok, head, webHead)
	}
	if sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("login left the publish fence ARMED -- this is NW-af2c: the user can log in and never log off")
	}

	sealFenceHit = false
	pushProfile(base, name, pass, seedDir(t, 3))
	if sealFenceHit {
		t.Fatal("the seal was still refused by the fence after a login that resolved a live head")
	}
	if got := getRef(base, profileRefV2(name, pass)); got == "" || got == webHead {
		t.Fatalf("the post-login seal did not advance the head: got %q, head at login %q", got, webHead)
	}
}

// The safety half, and the reason the lift hangs off ok rather than off profileDeleted() being false: a
// name that is still DELETED must leave the fence armed. Lifting on "not deleted" would also lift on
// ABSENT, which includes a profile whose delete is still purging.
func TestLoginLeavesFenceArmedForADeletedProfile(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	if _, _, _, ok := resolveKeyHeadForLogin(base, name, pass); ok {
		t.Fatal("a deleted profile resolved a head at login")
	}
	if !sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("login LIFTED the fence for a profile that is still deleted -- an in-flight seal can resurrect it")
	}
	// Asked of the publish gate directly, not through pushProfile: a bare push is refused by its own
	// tombstone guard BEFORE it reaches a publish, so a green pushProfile here would prove only that some
	// other guard fired. This is the one the lift would have disarmed.
	if !sealFencePublishBlocked("ref/" + profileRefV2(name, pass)) {
		t.Fatal("the publish gate would let a seal write this deleted profile's head")
	}
	if got := getRef(base, profileRefV2(name, pass)); got != "" {
		t.Fatalf("the deleted profile's head is no longer a tombstone: %q", got)
	}
}

// The lift is bare-scope only, so it runs ONCE per login rather than once per scope -- the same shape as the
// #734 heal, and for the same reason: sealFenceRefKeys derives a ref pair per scope suffix, which is seven
// Argon2 passes, on the path the user sits and waits on. roamd restores the bare scope first, so the bare
// restore has already lifted by the time any scope is restored.
func TestScopedLoginDoesNotLiftTheFence(t *testing.T) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1")

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	// Re-created off-device WITH a sealed #de scope, so the scope head is live and the '#' gate is the only
	// thing that can stop the lift.
	asOtherDevice(t, func() {
		createVault(base, name, pass)
		pushProfile(base, name+"#de", pass, seedDir(t, 2))
	})
	sealDone()
	if getRef(base, profileRefV2(name+"#de", pass)) == "" {
		t.Fatal("setup: the off-device #de seal left no head, so the scope gate is never exercised")
	}
	beforeSeq, before := fenceSnapshot(t)
	if _, _, _, ok := resolveKeyHeadForLogin(base, name+"#de", pass); !ok {
		t.Fatal("setup: the #de head did not resolve, so the scope gate is never exercised")
	}
	afterSeq, after := fenceSnapshot(t)
	if afterSeq != beforeSeq || len(before) != len(after) {
		t.Fatalf("a SCOPED restore moved the fence -- %s. The lift must run ONCE per login, from the bare "+
			"restore: a scoped lift derives sealFenceRefKeys from name+scope, so it clears that scope's own "+
			"pair and leaves the rest of the delete's fence standing.",
			fenceDrift(beforeSeq, afterSeq, before, after))
	}
	if !sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("a SCOPED restore lifted the bare fence")
	}
}
