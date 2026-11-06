package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// #84 deletion. An app UNLINKing a deferred file through the overlay (e.g. Organic Maps deleting an old
// <region>.mwm before writing the updated one) tombstones it. The seal must then DROP that one entry from
// Deferred -- the ONLY positive-deletion signal allowed to override the "not-seen-so-carry-forward" data-safety
// rule -- while every OTHER deferred entry still carries. Tombstone lives in the cache dir (skipped by the walk),
// read by the seal at <src>/mediaCacheRel/.deleted.
func TestSealDropsTombstonedDeferred(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, _ := overlayRaceSetup(t, "od-tomb")
	tombDir := filepath.Join(srcB, mediaCacheRel)
	if err := os.MkdirAll(tombDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tombDir, ".deleted"), []byte("app.maps/files/maps/one.mwm\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	prev := mediaUndersFn
	mediaUndersFn = func(s string) (map[string]string, error) {
		if s == srcB {
			return map[string]string{overlayDir: under}, nil
		}
		return nil, nil
	}
	t.Cleanup(func() { mediaUndersFn = prev })

	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if _, ok := m2.Deferred["app.maps/files/maps/one.mwm"]; ok {
		t.Fatalf("tombstoned one.mwm must be DROPPED from Deferred; got %v", keysOf(m2.Deferred))
	}
	if _, ok := m2.Deferred["app.maps/files/maps/two.mwm"]; !ok {
		t.Fatalf("two.mwm (not tombstoned) MUST carry forward -- a tombstone drops one entry, not the set; got %v", keysOf(m2.Deferred))
	}
}

// The FUSE side: os.Remove of a deferred stub through a live overlay succeeds (the app's delete works),
// persists the tombstone, and stops listing + serving that file while its deferred siblings stay served.
func TestOverlayUnlinkTombstonesDeferred(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	_, _, _, _, srcB, overlayDir, _, _ := overlayRaceSetup(t, "od-unlink")

	if err := os.Remove(filepath.Join(overlayDir, "one.mwm")); err != nil {
		t.Fatalf("unlink of a deferred stub must succeed (was EROFS before #84 deletion): %v", err)
	}
	b, err := os.ReadFile(filepath.Join(srcB, mediaCacheDirName, ".deleted"))
	if err != nil || !bytes.Contains(b, []byte("app.maps/files/maps/one.mwm")) {
		t.Fatalf(".deleted tombstone missing/wrong: %q err=%v", b, err)
	}
	if _, err := os.Stat(filepath.Join(overlayDir, "one.mwm")); !os.IsNotExist(err) {
		t.Fatalf("the deleted stub must be gone (ENOENT); stat err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(overlayDir, "two.mwm")); err != nil {
		t.Fatalf("a sibling deferred file must still be served after deleting one: %v", err)
	}
	des, _ := os.ReadDir(overlayDir)
	for _, de := range des {
		if de.Name() == "one.mwm" {
			t.Fatal("the deleted stub must not appear in readdir")
		}
	}
}

// markDeleted persists the tombstone + removes the local cache; loadTombstones reloads it (a mediad re-exec
// after a periodic seal keeps the file deleted); isDeleted reflects both.
func TestMarkDeletedPersistsAndEvictsCache(t *testing.T) {
	dir := t.TempDir()
	df := deferredFile{Chunks: []string{"aa", "bb"}, Size: 10}
	srv := &mediaServer{cacheDir: dir, deferred: map[string]deferredFile{"a/b/c.mwm": df}}
	// Seed a fake cache (whole-file + range sidecar) so markDeleted's eviction is observable.
	key := cacheKey(df)
	for _, suf := range []string{"", ".part", ".have"} {
		if err := os.WriteFile(filepath.Join(dir, key+suf), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	srv.markDeleted("a/b/c.mwm")
	if !srv.isDeleted("a/b/c.mwm") {
		t.Fatal("isDeleted should be true after markDeleted")
	}
	for _, suf := range []string{"", ".part", ".have"} {
		if _, err := os.Stat(filepath.Join(dir, key+suf)); !os.IsNotExist(err) {
			t.Fatalf("cache %q should be evicted on delete; err=%v", key+suf, err)
		}
	}
	if got := loadTombstones(dir); !got["a/b/c.mwm"] {
		t.Fatalf("loadTombstones must reload the tombstone; got %v", got)
	}
	if got := mediaTombstones(""); got != nil {
		t.Fatalf("mediaTombstones on a path with no cache -> nil; got %v", got)
	}
}
