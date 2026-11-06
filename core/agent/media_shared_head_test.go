package main

// NWP-20260907-23 (#91 slice 5b): WHAT A SHARED #media SEAL ACTUALLY DOES TO THE OTHER HANDSET'S MEDIA.
//
// Slice 5a (DIA-20260705-91, 2026-07-05) built a union-merge core for the shared #media head and left the
// wiring to 5b. Wiring it revealed that the union it performs ALREADY HAPPENS, one screen earlier in the
// same function: the #84 present-not-deleted CARRY (main.go, "if (ondemandMedia() || NOWHERE_CARRY_DEFERRED
// ...) && len(oldM.Deferred) > 0") folds every deferred entry of the STORED head into this seal unless one
// of six conditions says it was genuinely deleted. roamd exports NOWHERE_ONDEMAND_MEDIA=1
// (nowhere_roamd.sh's `export NOWHERE_ONDEMAND_MEDIA="${NOWHERE_ONDEMAND_MEDIA:-1}"`), so that carry runs on every #media seal on every handset in the field.
//
// These tests drive the REAL seal path with two handsets. The first two pin facts that pull in OPPOSITE
// directions, which is why a merge looks attractive and is not:
//
//   1. the other handset's media SURVIVES a seal from a handset that has never seen it, and
//   2. a tombstoned DELETION still propagates -- which a wholesale union of the stored head would undo.
//
// The last two locate the defect that IS real. They are a controlled pair, differing in exactly one thing:
//
//   3. two handsets whose ESSENTIAL sets match converge, and
//   4. give each one small file the other lacks and they never converge again -- the frankel/lynx livelock.
//
// Written after wiring the merge and measuring what it changed. See worklog NWP-20260907-23.

import (
	"os"
	"path/filepath"
	"testing"
)

// mediaSealEnv puts a handset in the configuration every fielded device seals #media in: on-demand media on,
// with a threshold low enough that a test-sized file is classified deferred rather than essential.
func mediaSealEnv(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "64")
}

// bulk returns a body big enough to be deferred under the threshold above.
func bulk(seed byte, n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = seed
	}
	return string(b)
}

// THE POINT OF THE WHOLE SLICE, ASKED OF THE REAL SEAL PATH.
//
// A photo taken on handset A must still be in the account head after handset B -- which has never
// materialised it, and whose walk therefore never sees it -- seals #media.
func TestSharedMedia_TheOtherHandsetsBulkSurvivesASealItWasNeverPartOf(t *testing.T) {
	mediaSealEnv(t)
	a, b := twoWriters(t, "sharedmedia", "correct horse battery staple")

	a.put("DCIM/from-a.jpg", bulk('a', 4096))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's #media seal: %s", msg)
	}
	if m := headManifestOf(t, a.base, a.name+"#media", a.pass); len(m.Deferred) == 0 {
		t.Fatalf("A's file was not deferred at all (%d deferred, %d essential chunks) -- the test is not "+
			"exercising the deferred index it claims to", len(m.Deferred), len(m.Chunks))
	}

	// B is signed into the same account. It never materialised A's photo, so its tree does not hold it and
	// its walk will not see it -- the ordinary state of on-demand media on a second handset.
	b.put("DCIM/from-b.jpg", bulk('b', 4096))
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's #media seal: %s", msg)
	}

	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Deferred["DCIM/from-a.jpg"]; !ok {
		t.Fatalf("B's seal DROPPED A's media. head now holds %d deferred entries: %v", len(m.Deferred), keysOf(m.Deferred))
	}
	if _, ok := m.Deferred["DCIM/from-b.jpg"]; !ok {
		t.Fatalf("B's own media is missing from the head it just wrote: %v", keysOf(m.Deferred))
	}
}

// THE OTHER HALF, AND THE REASON A UNION-MERGE OF THE STORED HEAD IS NOT SAFE TO ADD.
//
// A deferred entry survives ABSENCE by design -- an unmaterialised file and a deleted one look identical on
// disk, so the #84 carry keeps both ("present-not-deleted"). The ONE thing that distinguishes them is a
// mediad TOMBSTONE: an app unlinking through the media overlay appends the rel to the cache's `.deleted`
// file, and the carry drops exactly those. That is the whole deletion path for on-demand media.
//
// A union-merge of the stored head would fold every tombstoned entry straight back in -- so a photo the user
// deleted returns on the next seal and is billed forever. Same for the other four positive drops (a
// switched-off app's media, and the #400 / staging / odhold self-heals). This pins the drop, so any future
// attempt at 5b has to break this test to ship.
func TestSharedMedia_ATombstonedDeletionStillPropagates(t *testing.T) {
	mediaSealEnv(t)
	a, _ := twoWriters(t, "mediadel", "correct horse battery staple")

	a.put("DCIM/keep.jpg", bulk('k', 4096))
	a.put("DCIM/delete-me.jpg", bulk('d', 4096))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("first #media seal: %s", msg)
	}
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Deferred["DCIM/delete-me.jpg"]; !ok {
		t.Fatalf("setup: the file to delete was never deferred (%v)", keysOf(m.Deferred))
	}

	// The user deletes it. mediad unlinks the file AND records the tombstone -- absence alone is not a
	// deletion here, which is the point: an `os.Remove` on its own is indistinguishable from a file this
	// handset simply never materialised, and the carry rightly keeps that.
	if err := os.Remove(a.work + "/DCIM/delete-me.jpg"); err != nil {
		t.Fatal(err)
	}
	// ⚠ THE PATH MATTERS AND THIS TEST HAD IT WRONG (corrected NWP-20260908-03). It planted the tombstone at
	// the CE geometry -- <src>/com.nowhere.chooser/files/.nowhere-media/.deleted -- which mediaTombstones could
	// compute from src, so the mechanism was exercised but not the one #media has. On device the EXTERNAL
	// mediad caches OUTSIDE the sealed tree, under the chooser’s CE dir in `.nowhere-media-ext`, and roamd
	// names it explicitly. Use that, or this asserts a guarantee the #media scope does not actually have.
	extDeleted := filepath.Join(t.TempDir(), ".deleted")
	if err := os.WriteFile(extDeleted, []byte("DCIM/delete-me.jpg\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", extDeleted)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("second #media seal: %s", msg)
	}

	m = headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Deferred["DCIM/delete-me.jpg"]; ok {
		t.Fatalf("a TOMBSTONED file is still in the account head. A union-merge that folds the stored head "+
			"back in wholesale does exactly this -- deletions stop propagating and deleted media is billed "+
			"forever. head holds: %v", keysOf(m.Deferred))
	}
	if _, ok := m.Deferred["DCIM/keep.jpg"]; !ok {
		t.Fatalf("the file that was NOT deleted went missing too: %v", keysOf(m.Deferred))
	}
}

// ---------------------------------------------------------------------------------------------------
// the livelock itself, reproduced off-device -- and isolated to one variable
// ---------------------------------------------------------------------------------------------------

// alternate seals #media from each handset in turn and reports the head after each, which is how the
// account's current state is defined for a shared scope.
func alternate(t *testing.T, a, b *handset, rounds int) (heads [][2]string) {
	t.Helper()
	for i := 1; i <= rounds; i++ {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("A round %d: %s", i, msg)
		}
		ha := a.head("#media")
		if msg := b.seal("#media"); msg != "" {
			t.Fatalf("B round %d: %s", i, msg)
		}
		hb := b.head("#media")
		t.Logf("round %d: after A %s | after B %s", i, short(ha), short(hb))
		heads = append(heads, [2]string{ha, hb})
	}
	return heads
}

// THE CONTROL. Two handsets whose ESSENTIAL sets hold the same files converge: after the first round the
// head stops moving, however many idle cycles run. Without this the reproduction below would prove nothing
// -- a test that always sees churn cannot tell churn from its absence.
func TestSharedMedia_TwoHandsetsWithTheSameEssentialSetConverge(t *testing.T) {
	mediaSealEnv(t)
	a, b := twoWriters(t, "converge", "correct horse battery staple")

	for _, h := range []*handset{a, b} {
		h.put("Documents/shared.txt", "restored at login -- both handsets hold it")
	}
	// Their BULK differs, which is the case slice 5 was written for: each has materialised its own photo.
	a.put("DCIM/from-a.jpg", bulk('a', 4096))
	b.put("DCIM/from-b.jpg", bulk('b', 4096))

	h := alternate(t, a, b, 3)
	if h[1] != h[2] {
		t.Fatalf("two handsets with matching essential sets still churn: round 2 %s/%s, round 3 %s/%s",
			short(h[1][0]), short(h[1][1]), short(h[2][0]), short(h[2][1]))
	}
	if h[2][0] != h[2][1] {
		t.Fatalf("A and B settled on DIFFERENT heads (%s vs %s) with matching essential sets",
			short(h[2][0]), short(h[2][1]))
	}
}

// THE REPRODUCTION, AND THE CAUSE, ISOLATED TO ONE VARIABLE.
//
// Change ONE thing against the control above -- give each handset a SMALL file the other does not hold --
// and the two stop converging: each settles on its own head and republishes it every cycle, forever. That
// is the frankel/lynx livelock (NWP-20260907-20: 6 detections on one handset, 3 on the other, all naming
// the same two refs), off-device and in milliseconds.
//
// WHY THE SIZE MATTERS, AND WHY SLICE 5's MERGE CANNOT FIX IT. A file at or above the seal threshold is
// DEFERRED, and the deferred index is per-file, so the #84 carry already unions it across handsets (proven
// above). A file below the threshold is ESSENTIAL, and the essential set is a whole-tree TAR in
// Chunks/Sizes with no per-file labels -- so a handset cannot adopt the other's essential files without
// holding their bytes, and every seal republishes its own tar. Union-merging the deferred index changes
// nothing here, which is why wiring slice 5a's merge did not fix this and was dropped.
//
// THE FIX IS AN INDEX, NOT A MERGE. chunkManifest.Ess already maps a rel to its span in the essential tar,
// and the seal already carries spans by hash without fetching bytes (main.go, "carriedEss") -- but that
// carry is keyed by PACKAGE (carryPkgs) and gated on NOWHERE_CARRY_ESSENTIAL, so it serves #apps only.
// Extending it to #media, keyed by rel, is the real slice.
func TestSharedMedia_AnAsymmetricEssentialSetLivelocks(t *testing.T) {
	mediaSealEnv(t)
	a, b := twoWriters(t, "livelock", "correct horse battery staple")

	for _, h := range []*handset{a, b} {
		h.put("Documents/shared.txt", "restored at login -- both handsets hold it")
	}
	a.put("DCIM/from-a.jpg", bulk('a', 4096))
	b.put("DCIM/from-b.jpg", bulk('b', 4096))
	// THE ONE DIFFERENCE FROM THE CONTROL: a small file on each side that the other has not materialised.
	// On a real handset these are thumbnails, .nomedia markers, small downloads and app media -- routine.
	a.put("Documents/only-on-a.txt", "small enough to ride the essential tar")
	b.put("Documents/only-on-b.txt", "small enough to ride the essential tar")

	h := alternate(t, a, b, 3)
	last := h[len(h)-1]
	if last[0] != last[1] {
		knownDefect(t, "backlog: `#media`'s two-handset overwrite loop is FIXED by the essential carry",
			"two idle handsets never converge: A's seal leaves the head at %s and B's leaves it at %s, "+
				"round after round, with no user changes on either. Each republishes its own whole-tree "+
				"essential tar because neither can adopt the other's without holding the bytes. The bulk is "+
				"not involved -- it already unions. Fix: a per-rel essential index for #media (see this "+
				"test's comment).", short(last[0]), short(last[1]))
	}
}
