package main

// NWP-20260908-22: the DEFERRED half of the mid-session sync -- the tier a camera photo lands in.
//
// Slice 1 covers files under the deferral floor, which for user media is 1 MiB: a screenshot, not a photo.
// These pin the other half, and the two hazards that come with fetching bytes the on-demand tier had
// deliberately not fetched: a deletion must not be undone, and the budget must actually bound.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// deferredMediaEnv drops the user-media deferral floor so a small fixture file is DEFERRED, which is the
// whole point -- without this the file rides the essential tar and slice 1's path is what gets tested.
func deferredMediaEnv(t *testing.T) {
	t.Helper()
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "64")
}

// asserts the fixture actually produced a DEFERRED entry, so a passing test cannot be a test of slice 1.
func requireDeferred(t *testing.T, h *handset, rel string) {
	t.Helper()
	m := headManifestOf(t, h.base, h.name+"#media", h.pass)
	if _, ok := m.Deferred[rel]; !ok {
		t.Fatalf("%s is not DEFERRED in the head (deferred=%d, ess=%d) -- this fixture would be testing the "+
			"essential path instead", rel, len(m.Deferred), len(m.Ess))
	}
}

// THE FEATURE, one tier over: A takes a PHOTO; B seals; B has the photo.
func TestMediaSync_ADeferredPhotoFromAnotherHandsetLands(t *testing.T) {
	deferredMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	syncOut := filepath.Join(state, "mediasync.list")
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", syncOut)

	a, b := twoWriters(t, "defsync", "correct horse battery staple")
	ref := profileRefV2("defsync#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, a.head("#media")) })

	const photo = "DCIM/Camera/IMG_from_a.jpg"
	body := strings.Repeat("photo bytes, comfortably over the lowered floor. ", 40)
	a.put(photo, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}
	requireDeferred(t, a, photo)

	target := filepath.Join(b.work, filepath.FromSlash(photo))
	if _, err := os.Lstat(target); err == nil {
		t.Fatal("the photo is already on B before any sync -- this fixture proves nothing")
	}
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("A's DEFERRED photo did not land on B (%v). The carry keeps it in the account head either "+
			"way, so nothing is lost -- but a camera photo is above the deferral floor, which is exactly the "+
			"tier slice 1 does not cover.", err)
	}
	if string(got) != body {
		t.Errorf("the photo landed with the wrong bytes (%d of %d)", len(got), len(body))
	}
	list, err := os.ReadFile(syncOut)
	if err != nil || !strings.Contains(string(list), target) {
		t.Errorf("the sync list does not name the deferred file that landed (err=%v, list=%q) -- the bytes "+
			"would be on disk and the gallery would never show them", err, string(list))
	}
}

// A DELETED PHOTO MUST NOT BE FETCHED BACK. The roster is the only thing separating "another handset
// published this" from "I had it and it is gone", and at this tier getting it wrong also costs a download.
func TestMediaSync_ADeletedDeferredPhotoIsNotFetchedBack(t *testing.T) {
	deferredMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", filepath.Join(state, "mediasync.list"))

	a, b := twoWriters(t, "defdel", "correct horse battery staple")
	ref := profileRefV2("defdel#media", "correct horse battery staple")

	const photo = "DCIM/Camera/IMG_delete_me.jpg"
	body := strings.Repeat("a photo the user deletes on B. ", 40)
	a.put(photo, body)
	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	requireDeferred(t, a, photo)
	atLogin := a.head("#media")

	// B logged in HOLDING it -- that is what makes the later absence a deletion.
	b.put(photo, body)
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, atLogin) })
	b.rm(photo)

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if _, err := os.Lstat(filepath.Join(b.work, filepath.FromSlash(photo))); err == nil {
		t.Fatal("the deferred sync FETCHED BACK a photo the user deleted -- so deleting a photo would be " +
			"impossible, and would cost a download every cycle while failing")
	}
}

// THE BUDGET MUST ACTUALLY BOUND. This is the whole reason fetching deferred bytes is defensible: without it
// one cycle could pull the entire deferred set, which is precisely what the on-demand tier exists to avoid.
func TestMediaSync_TheDeferredBudgetBounds(t *testing.T) {
	deferredMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", filepath.Join(state, "mediasync.list"))
	t.Setenv("NOWHERE_MEDIA_SYNC_BUDGET", "1") // one byte: nothing can fit

	a, b := twoWriters(t, "defbudget", "correct horse battery staple")
	ref := profileRefV2("defbudget#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, a.head("#media")) })

	const photo = "DCIM/Camera/IMG_big.jpg"
	a.put(photo, strings.Repeat("far more than one byte. ", 40))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}
	requireDeferred(t, a, photo)

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if _, err := os.Lstat(filepath.Join(b.work, filepath.FromSlash(photo))); err == nil {
		t.Fatal("a 1-byte budget still fetched a whole photo. The budget is the only thing bounding a trade " +
			"this slice makes deliberately -- fetching bytes the on-demand tier had decided not to fetch.")
	}
}

// THE REASSEMBLY-SIZE GUARD, TESTED DIRECTLY -- because no end-to-end fixture can reach it.
//
// It only fires when the manifest and the chunks disagree, which a healthy store never produces, so deleting
// it survives every test above. I found that by running the mutation and then asking whether the mutant was
// REACHABLE, which is the question I failed to ask in slice 1.
//
// It is worth keeping: a short reassembly written to disk is a CORRUPT photo, and the next walk would seal it
// OVER the good copy in the account head -- turning a transient fetch fault into permanent, account-wide loss.
// Refusing leaves the head intact and lets the next cycle retry.
func TestMediaSync_AShortReassemblyIsRefusedRatherThanWritten(t *testing.T) {
	deferredMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "defshort", "correct horse battery staple")

	const photo = "DCIM/Camera/IMG_short.jpg"
	a.put(photo, strings.Repeat("real bytes. ", 40))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	d, ok := m.Deferred[photo]
	if !ok {
		t.Fatalf("fixture did not defer %s; nothing below is exercised", photo)
	}
	key := resolveDK(a.base, a.name+"#media", a.pass, nil)

	// The honest fetch first, so a failure below cannot be blamed on the fixture.
	if b, err := fetchDeferredBytes(a.base, key, m.Version, d); err != nil || int64(len(b)) != d.Size {
		t.Fatalf("the unmodified fetch must succeed before the corrupted one means anything: err=%v len=%d want=%d",
			err, len(b), d.Size)
	}

	// Now claim the file is bigger than its chunks can supply -- the shape a torn seal or a lost chunk leaves.
	d.Size = d.Size + 4096
	if _, err := fetchDeferredBytes(a.base, key, m.Version, d); err == nil {
		t.Fatal("a reassembly SHORTER than the manifest claims was accepted. Written to disk that is a corrupt " +
			"photo, and the next walk seals it over the good copy in the account head -- a transient fetch " +
			"fault becoming permanent loss for every device on the account.")
	}
}

// syncOversizeFixture sets two handsets up on one profile, B logged in holding the shared file, with B's
// per-cycle budget set; it returns A and B.
func syncOversizeFixture(t *testing.T, name, budget string) (a, b *handset) {
	t.Helper()
	deferredMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", filepath.Join(state, "mediasync.list"))
	t.Setenv("NOWHERE_MEDIA_SYNC_BUDGET", budget)

	a, b = twoWriters(t, name, "correct horse battery staple")
	ref := profileRefV2(name+"#media", "correct horse battery staple")
	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, a.head("#media")) })
	return a, b
}

// publishDeferred puts a deferred file of n bytes on A and seals it.
func publishDeferred(t *testing.T, a *handset, rel string, n int) string {
	t.Helper()
	body := strings.Repeat("x", n-1) + rel[len(rel)-5:len(rel)-4]
	a.put(rel, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's seal of %s: %s", rel, msg)
	}
	requireDeferred(t, a, rel)
	return body
}

func landed(b *handset, rel string) bool {
	_, err := os.Lstat(filepath.Join(b.work, filepath.FromSlash(rel)))
	return err == nil
}

// A FILE LARGER THAN THE WHOLE BUDGET CAN NEVER FIT A CYCLE and must not end every cycle at 0 B: the
// arrivals sorted after it still land.
func TestMediaSync_AnOversizeArrivalDoesNotBlockTheRest(t *testing.T) {
	a, b := syncOversizeFixture(t, "defoversize", "1000")
	const big, small = "DCIM/Camera/IMG_a_big.jpg", "DCIM/Camera/IMG_b_small.jpg"
	publishDeferred(t, a, big, 1500)
	want := publishDeferred(t, a, small, 300)

	var msg string
	out := captureStdout(t, func() { msg = b.seal("#media") })
	if msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	got, err := os.ReadFile(filepath.Join(b.work, filepath.FromSlash(small)))
	if err != nil || string(got) != want {
		t.Fatalf("the small arrival sorted after an oversize one did not land with A's bytes (err=%v, %d of %d B)",
			err, len(got), len(want))
	}
	if landed(b, big) {
		t.Error("a 1500 B file landed under a 1000 B per-cycle budget")
	}
	if !strings.Contains(out, "1 deferred file(s) larger than the per-cycle budget (1000 B) wait for the next login") {
		t.Errorf("the oversize count line is missing from B's output:\n%s", out)
	}
	if strings.Contains(out, big) {
		t.Errorf("the count line must not name a file:\n%s", out)
	}
}

// THE ORDER CONTRACT: a file that fits the budget but not what is LEFT of it still ends the cycle, so a later
// cycle picks up exactly where this one stopped.
func TestMediaSync_AnArrivalThatFitsTheBudgetButNotTheRemainderStillStopsTheCycle(t *testing.T) {
	a, b := syncOversizeFixture(t, "defremainder", "1000")
	publishDeferred(t, a, "DCIM/Camera/IMG_a.jpg", 600)
	publishDeferred(t, a, "DCIM/Camera/IMG_b.jpg", 600)
	publishDeferred(t, a, "DCIM/Camera/IMG_c.jpg", 100)

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if !landed(b, "DCIM/Camera/IMG_a.jpg") {
		t.Error("the first arrival, which fits, did not land")
	}
	if landed(b, "DCIM/Camera/IMG_b.jpg") || landed(b, "DCIM/Camera/IMG_c.jpg") {
		t.Error("the cycle went past the arrival that did not fit the remainder: later arrivals landed ahead " +
			"of an earlier one, so progress is no longer monotonic")
	}
}

// A file of exactly the budget still fits.
func TestMediaSync_AnArrivalOfExactlyTheBudgetLands(t *testing.T) {
	a, b := syncOversizeFixture(t, "defexact", "500")
	publishDeferred(t, a, "DCIM/Camera/IMG_exact.jpg", 500)
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if !landed(b, "DCIM/Camera/IMG_exact.jpg") {
		t.Error("a file of exactly the per-cycle budget did not land")
	}
}
