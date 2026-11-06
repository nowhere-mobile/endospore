package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// #84 P3d seal safety, part 1: an UNCHANGED deferred file is carried forward BY HASH -- the seal must not
// read it. Proven by mutating the file's bytes while keeping size+mtime identical: a re-read would produce
// different chunks; the carry keeps the ORIGINAL ones. (On-device this is what makes the ~1min periodic sync
// safe under a live media overlay -- getattr comes from the manifest, so the stat always matches, and a read
// through the mount would fetch the whole file from the store just to re-seal bytes the store already holds.)
func TestSealCarriesDeferredForwardWithoutReading(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "carry", "forward horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	mapBytes := bytes.Repeat([]byte("ORIGINAL-MAP-BYTES--"), 5000)
	rel := "app.maps/files/maps/region.mwm"
	p := filepath.Join(src, rel)
	if err := os.WriteFile(p, mapBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	m1 := headManifest(t, base, dk, name, pass)
	d1, ok := m1.Deferred[rel]
	if !ok || len(d1.Chunks) == 0 {
		t.Fatalf("first push: %q not deferred (%v)", rel, keysOf(m1.Deferred))
	}
	if len(d1.Sz) != len(d1.Chunks) {
		t.Fatalf("first push: Sz not populated (%d vs %d chunks)", len(d1.Sz), len(d1.Chunks))
	}

	// Simulate the session boundary the carry depends on: ON-DEVICE a seal is always preceded by a LOGIN
	// restore, and cdcRestore seeds the blob cache with the head's chunks -- INCLUDING the Deferred ones
	// (P3d) -- which is what lets deferredChunksKnown() pass. The plain-HTTP test store's postBlob doesn't
	// maintain the blob cache (only the s3/cap path does), so without this restore the carry gate would be
	// cold and the test would exercise the (safe) re-chunk fallback instead of the carry.
	blobCacheMu.Lock()
	blobCache = map[string]bool{}
	blobCacheMu.Unlock()
	restoreManifest(t, base, name, pass)
	for _, h := range d1.Chunks {
		if !blobCacheKnown(h) {
			t.Fatal("login restore did not seed the deferred chunks into the blob cache (cdcRestore P3d seeding)")
		}
	}

	// Mutate CONTENT, keep size + mtime (what a read-back would see through a live overlay never happens --
	// the overlay is read-only -- so a stat-match MUST mean "carry, don't read").
	fi, _ := os.Stat(p)
	mut := bytes.Repeat([]byte("MUTATED--MAP-BYTES--"), 5000)
	if len(mut) != len(mapBytes) {
		t.Fatal("test bug: mutation changed the size")
	}
	if err := os.WriteFile(p, mut, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, fi.ModTime(), fi.ModTime()); err != nil {
		t.Fatal(err)
	}

	pushProfile(base, name, pass, src)
	m2 := headManifest(t, base, dk, name, pass)
	d2, ok := m2.Deferred[rel]
	if !ok {
		t.Fatal("second push dropped the deferred entry")
	}
	if len(d2.Chunks) != len(d1.Chunks) {
		t.Fatalf("carry-forward changed the chunk count: %d -> %d", len(d1.Chunks), len(d2.Chunks))
	}
	for i := range d1.Chunks {
		if d2.Chunks[i] != d1.Chunks[i] {
			t.Fatalf("chunk %d changed (%s -> %s): the seal READ the file instead of carrying it forward",
				i, short(d1.Chunks[i]), short(d2.Chunks[i]))
		}
	}
}

// #84 P3d seal safety, part 2 (the design doc's "present-not-deleted"): a deferred file ABSENT from disk is
// NOT a deletion -- it just isn't materialized locally (mediad stopped at logoff, or the cache evicted). The
// seal must carry its entry forward, and the bytes must still reconstruct from the store.
func TestSealCarriesAbsentDeferredForward(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "absent", "carry horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(src, "app.maps/note.txt"), []byte("essential, changes below"), 0o644)
	mapBytes := bytes.Repeat([]byte("ABSENT-CARRY-BYTES--"), 5000)
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), mapBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	d1 := headManifest(t, base, dk, name, pass).Deferred[rel]
	if len(d1.Chunks) == 0 {
		t.Fatal("first push: map not deferred")
	}

	// The logoff seal's reality: mediad torn down first, deferred file never fetched -> absent on disk.
	if err := os.Remove(filepath.Join(src, rel)); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.maps/note.txt"), []byte("essential, CHANGED -- forces a real second seal"), 0o644)

	pushProfile(base, name, pass, src)
	m2 := headManifest(t, base, dk, name, pass)
	d2, ok := m2.Deferred[rel]
	if !ok {
		t.Fatal("absent deferred file was DROPPED from the manifest -- that's data loss at the next GC")
	}
	if d2.Size != d1.Size || len(d2.Chunks) != len(d1.Chunks) {
		t.Fatalf("absent carry mutated the entry: size %d->%d chunks %d->%d", d1.Size, d2.Size, len(d1.Chunks), len(d2.Chunks))
	}
	// and the bytes still reconstruct from the store
	var got []byte
	for _, h := range d2.Chunks {
		raw, err := unpackChunk(unseal(dk, getChunk(base, h)), m2.Version)
		if err != nil {
			t.Fatalf("unpack carried chunk: %v", err)
		}
		got = append(got, raw...)
	}
	if !bytes.Equal(got, mapBytes) {
		t.Fatalf("carried reconstruction mismatch: %d vs %d bytes", len(got), len(mapBytes))
	}
}

// #84 P3d + #92: the media daemon's local cache is DERIVED state -- sealing it would re-upload GBs of
// already-stored media AND follow its .under binds into real app dirs. It now lives NESTED under the chooser
// package dir (mediaCacheRel, #92 -- to dodge the app-data reconcile), so the skip is by BASENAME: both seal
// paths must skip a ".nowhere-media" dir wherever it appears, not just at the user root.
func TestSealSkipsMediaCacheDir(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "cacheskip", "skip horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	// Put the cache at its REAL nested home (com.nowhere.chooser/files/.nowhere-media), inside a package dir
	// whose OTHER files (keep.list) DO seal -- proving the skip is by basename, not "the whole chooser dir".
	cache := filepath.Join(src, filepath.FromSlash(mediaCacheRel))
	os.MkdirAll(filepath.Join(cache, ".under"), 0o755)
	junk := bytes.Repeat([]byte("CACHE-JUNK-"), 3000)
	os.WriteFile(filepath.Join(cache, "deadbeef"), junk, 0o600)
	chooserFiles := filepath.Join(src, "com.nowhere.chooser", "files")
	os.WriteFile(filepath.Join(chooserFiles, "keep.list"), []byte("roamed chooser state"), 0o644)
	os.WriteFile(filepath.Join(src, "keep.txt"), []byte("real data"), 0o644)

	pushProfile(base, name, pass, src)
	_, dst := restoreManifest(t, base, name, pass)
	if _, err := os.Stat(filepath.Join(dst, "keep.txt")); err != nil {
		t.Fatal("real file missing after restore")
	}
	if _, err := os.Stat(filepath.Join(dst, "com.nowhere.chooser", "files", "keep.list")); err != nil {
		t.Fatal("the chooser's own roamed state must still seal (only .nowhere-media is skipped)")
	}
	if _, err := os.Stat(filepath.Join(dst, filepath.FromSlash(mediaCacheRel))); err == nil {
		t.Fatal("the media cache dir was SEALED into the profile (incremental path)")
	}

	// the legacy whole-tar path (NOWHERE_SEAL_FULL=1 kill switch) must agree
	t.Setenv("NOWHERE_SEAL_FULL", "1")
	os.WriteFile(filepath.Join(src, "keep.txt"), []byte("real data v2"), 0o644)
	pushProfile(base, name, pass, src)
	_, dst2 := restoreManifest(t, base, name, pass)
	if _, err := os.Stat(filepath.Join(dst2, filepath.FromSlash(mediaCacheRel))); err == nil {
		t.Fatal("the media cache dir was SEALED into the profile (legacy tar path)")
	}
	if _, err := os.Stat(filepath.Join(dst2, "com.nowhere.chooser", "files", "keep.list")); err != nil {
		t.Fatal("legacy path: chooser state must still seal")
	}
}

// #84 P3d: deferred chunks are part of the paid footprint -- unleased, the store GC would reap the very media
// the daemon serves on-access. Each deferred chunk must be leased at its sealed (Sz) size.
func TestFootprintCountsDeferredChunks(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "footprint", "lease horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(src, rel1Dir()), bytes.Repeat([]byte("FOOTPRINT-BYTES-----"), 5000), 0o644)
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	d, ok := m.Deferred["app.maps/files/maps/region.mwm"]
	if !ok || len(d.Chunks) == 0 || len(d.Sz) != len(d.Chunks) {
		t.Fatalf("deferred entry malformed: %+v", d)
	}
	refs, _ := profileFootprint(base, name, pass, nil)
	for i, h := range d.Chunks {
		got, ok := refs["blob/"+h]
		if !ok {
			t.Fatalf("deferred chunk %s NOT in the footprint -> it would be GC'd out from under the maps", short(h))
		}
		if got != d.Sz[i] {
			t.Fatalf("deferred chunk %s leased at %d, want its sealed size %d", short(h), got, d.Sz[i])
		}
	}
}

func rel1Dir() string { return filepath.Join("app.maps", "files", "maps", "region.mwm") }

// headManifest loads the profile's live CDC manifest through the vault head (the P2/P3 tests' common recipe).
func headManifest(t *testing.T, base string, dk []byte, name, pass string) chunkManifest {
	t.Helper()
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	return loadCDCManifest(base, dk, v.Manifest)
}
