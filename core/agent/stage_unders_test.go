package main

import (
	"path/filepath"
	"testing"
)

// NWP-20260829-26. NWP-20260829-25 wrote undersByDir from inside serveMediaScope's staging loop, which sits
// ABOVE the newMediaOverlay and fs.Mount failure exits. Both exits MNT_DETACH `hidden` but neither removes
// the keys, and `hidden` survives as a plain directory (os.MkdirAll created it) -- so for a dir whose mount
// failed, materialize's lookup HITS, copyFile SUCCEEDS into that orphan, and markDeleted() then tombstones
// the rel out of the manifest. The file's only copy is left in a scratch dir nothing restores from, and the
// daemon logs `MATERIALIZED ... (kept offline; restored at login)`. Silent, permanent loss.
//
// The publish point is now after the mount, and the mapping is a pure function so it can be pinned here.
// The failure path itself is NOT unit-testable: serveMediaScope needs root for the MS_BIND and a working
// FUSE for fs.Mount, so a test process fails at the bind long before reaching the branch under repair.
func TestStageUndersMapsNestedDirsUnderTheMountBind(t *testing.T) {
	hidden := filepath.Join("/cache", ".under", "a_b_Images")
	root := "a/b/Images"
	dirs := map[string][]string{
		root:                {"top.jpg"},
		root + "/Sent":      {"sent.jpg"},
		root + "/Sent/Deep": {"deep.jpg"},
		"a/b/Images2":       {"sibling.jpg"}, // shares "a/b/Images" as a STRING prefix, is not under it
		"a/b/Other":         {"other.jpg"},
	}

	sub, unders := stageUnders(dirs, root, hidden)

	// (1) The mount root maps to the bind itself. serveMediaScope no longer sets this key separately, so
	// if this regresses, materialize loses the ancestor's OWN files, not just the nested ones.
	if got := unders[root]; got != hidden {
		t.Errorf("root dir must map to the bind itself: got %q want %q", got, hidden)
	}

	// (2) THE -25 PROPERTY: a nested dir maps to the MATCHING path under the bind, never to the bind. If
	// this collapses to `hidden`, every nested file is written into the ancestor's dir instead of beside
	// its siblings -- the quiet misplacement, recorded by the next seal as the wrong shape.
	wantSent := filepath.Join(hidden, "Sent")
	if got := unders[root+"/Sent"]; got != wantSent {
		t.Errorf("nested dir mismapped: got %q want %q", got, wantSent)
	}
	wantDeep := filepath.Join(hidden, "Sent", "Deep")
	if got := unders[root+"/Sent/Deep"]; got != wantDeep {
		t.Errorf("deeply nested dir mismapped: got %q want %q", got, wantDeep)
	}

	// (3) A sibling sharing a string prefix is NOT under this mount. Dropping the "/" from the prefix test
	// would map a2's files into a's bind -- reachable with real names like "WhatsApp Video" vs
	// "WhatsApp Video Notes", which is exactly the shape on the device.
	if got, ok := unders["a/b/Images2"]; ok {
		t.Errorf("prefix-sharing sibling must NOT be covered, got %q", got)
	}
	if _, ok := sub["a/b/Images2"]; ok {
		t.Error("prefix-sharing sibling leaked into the deferred index handed to the overlay")
	}

	// (4) An unrelated dir stays out.
	if _, ok := unders["a/b/Other"]; ok {
		t.Error("unrelated dir must not be covered")
	}

	// (5) The two maps must describe the SAME set: the overlay serves stubs for `sub`, materialize resolves
	// through `unders`, and a dir in one but not the other is a file that is visible but unplaceable, or
	// placeable but invisible.
	if len(sub) != len(unders) {
		t.Fatalf("sub and unders disagree on coverage: %d vs %d (%v / %v)", len(sub), len(unders), sub, unders)
	}
	for d := range sub {
		if _, ok := unders[d]; !ok {
			t.Errorf("dir %q is served but has no real location", d)
		}
	}
}
