package main

// NWP-20260908-03: THE #media SCOPE'S DELETION TOMBSTONES WERE READ FROM A PATH THE DEVICE NEVER WRITES.
//
// mediaTombstones computed `<src>/com.nowhere.chooser/files/.nowhere-media/.deleted`. That is correct for the
// CE scope, where mediad caches inside the tree it serves. The #media push passes src=/data/media/<uid>,
// and the EXTERNAL mediad caches under the CHOOSER's CE dir in `.nowhere-media-ext` -- a different root AND a
// different basename (nowhere_mediad.sh: MEDIACACHE="$USERDIR/com.nowhere.chooser/files/.nowhere-media-ext").
// So the read always missed, tomb was always empty, and the #84 present-not-deleted carry re-emitted every
// deleted external media file forever: still referenced, still leased, still billed.
//
// The tree had already learned this exact lesson. DIA-20260813-06 fixed the same wrong-root assumption for
// the overlay `.under` binds -- "the computed path is only correct when src IS the user dir ... for
// src=/data/media/<uid> the computed path never exists and the walker SKIPPED the whole overlaid subtree" --
// and resolved them from the mount table instead. This call site was not part of that fix.
//
// A tombstone file is not a mount, so it cannot be resolved that way; roamd names it explicitly instead,
// which is what these tests pin.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeDeleted(t *testing.T, dir string, rels ...string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, ".deleted")
	body := ""
	for _, r := range rels {
		body += r + "\n"
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// THE BUG, IN THE GEOMETRY THE DEVICE ACTUALLY HAS. The tombstone lives outside the sealed tree, so nothing
// computed from src can find it.
func TestMediaTombstones_TheExternalCacheIsOutsideTheSealedTree(t *testing.T) {
	root := t.TempDir()
	mediaTree := filepath.Join(root, "data", "media", "11") // what the #media push is handed
	extCache := filepath.Join(root, "data", "user", "11",   // where the external mediad actually caches
		"com.nowhere.chooser", "files", ".nowhere-media-ext")
	if err := os.MkdirAll(mediaTree, 0o700); err != nil {
		t.Fatal(err)
	}
	deleted := writeDeleted(t, extCache, "DCIM/gone.jpg")

	// Without the path, the computed location misses and the deletion is invisible -- the shipped behaviour.
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	if tomb := mediaTombstones(mediaTree); tomb["DCIM/gone.jpg"] {
		t.Fatal("the computed path found the external tombstone -- then this test is not modelling the " +
			"device geometry and proves nothing")
	}

	// With roamd naming it, the deletion is seen.
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", deleted)
	tomb := mediaTombstones(mediaTree)
	if !tomb["DCIM/gone.jpg"] {
		t.Fatalf("the #media scope still cannot see its own deletions (%v). Every deleted external media "+
			"file is carried forward by the #84 present-not-deleted rule: referenced, leased and billed "+
			"forever, with no way to remove it from any device.", tomb)
	}
}

// THE CE SCOPE MUST BE BYTE-IDENTICAL. Its cache IS inside the tree, roamd passes no path for it, and this
// is the larger of the two scopes -- a regression here would drop real deletions.
func TestMediaTombstones_TheCEScopeIsUnchanged(t *testing.T) {
	src := t.TempDir()
	writeDeleted(t, filepath.Join(src, filepath.FromSlash(mediaCacheRel)), "app.pkg/files/map.mwm")

	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "") // roamd passes nothing for the CE push
	tomb := mediaTombstones(src)
	if !tomb["app.pkg/files/map.mwm"] {
		t.Fatalf("the CE scope lost its tombstones (%v) -- this is the path that worked before", tomb)
	}
	if len(tomb) != 1 {
		t.Errorf("unexpected extra entries: %v", tomb)
	}
}

// BOTH, UNIONED. A scope with a cache inside the tree AND a named file gets both; neither read may mask the
// other, because a wrong precedence here silently loses one channel's deletions.
func TestMediaTombstones_BothSourcesAreUnioned(t *testing.T) {
	src := t.TempDir()
	writeDeleted(t, filepath.Join(src, filepath.FromSlash(mediaCacheRel)), "inside.jpg")
	ext := writeDeleted(t, filepath.Join(t.TempDir(), "ext"), "outside.jpg")

	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", ext)
	tomb := mediaTombstones(src)
	for _, want := range []string{"inside.jpg", "outside.jpg"} {
		if !tomb[want] {
			t.Errorf("%s missing from the union: %v", want, tomb)
		}
	}
}

// A profile with no media daemon at all must still get nil, not an empty map -- the carry's own gate reads
// `tomb[rel]` and callers distinguish "no cache" from "nothing deleted" nowhere else.
func TestMediaTombstones_NoCacheIsStillNil(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", filepath.Join(t.TempDir(), "does-not-exist"))
	if tomb := mediaTombstones(t.TempDir()); tomb != nil {
		t.Fatalf("expected nil for a profile with no tombstones anywhere, got %v", tomb)
	}
}

// AND ROAMD MUST ACTUALLY NAME IT. The agent side can be perfect and reach nothing: that is precisely how
// this bug survived, and how NOWHERE_SEQ_GUARD shipped inert on 2026-09-07.
func TestMediaTombstones_RoamdNamesTheExternalCacheOnTheMediaPush(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Skipf("cannot read roamd (%v)", err)
	}
	src := string(b)
	if !strings.Contains(src, "NOWHERE_MEDIA_TOMBSTONES=") {
		t.Fatal("roamd never sets NOWHERE_MEDIA_TOMBSTONES -- the agent-side fix is unreachable")
	}
	if !strings.Contains(src, ".nowhere-media-ext/.deleted") {
		t.Error("roamd does not name the EXTERNAL mediad cache. `.nowhere-media` (the CE dir) is already " +
			"reachable from src; the whole point is the ext cache, which is not.")
	}
}
