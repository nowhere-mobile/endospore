package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWalkChunksSkipsFileWrittenDuringSeal reproduces the on-device (2026-07-14) seal-during-download
// corruption: a profile sealed WHILE Organic Maps is appending to a *.mwm.ready.downloading temp captured a
// torn snapshot -- the deferred manifest Size (taken from the walk-time stat) disagreed with the sealed chunk
// bytes (read a moment later), so mediad refused the file forever ("size mismatch: fetched X, manifest says
// Y") and the map never materialized. The seal now detects the mid-write (a post-read fstat differing from the
// walk stat) and does NOT seal the tear; it defers capture to the next, stable seal. Reproduced
// deterministically by growing the file from inside the chunk-emit callback, which runs during cdcSplit's read
// loop (a read past the original EOF picks up the append on Linux, and the append bumps mtime).
func TestWalkChunksSkipsFileWrittenDuringSeal(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	dir := t.TempDir()
	rel := "app.organicmaps/files/260527/US_region.mwm.ready.downloading"
	iwrite(t, dir, rel, bytes.Repeat([]byte("MAPDATA0"), 8192)) // 64 KiB: >= MEDIA_MIN and >= the walk threshold
	p := filepath.Join(dir, filepath.FromSlash(rel))

	sc := newFileScanCache(make([]byte, 32))
	grew := false
	emit := func([]byte) int {
		if !grew { // simulate the app appending mid-download, DURING the seal's own read of this file
			grew = true
			if f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
				_, _ = f.Write(bytes.Repeat([]byte("MOREDATA"), 8192)) // +64 KiB after the walk's stat
				f.Close()
			}
		}
		return 0
	}
	_, seen, def, _, _, _, _, _ := walkChunks(dir, sc, 4096, true, ondemandMedia(), nil, nil, nil, nil, 0, emit, func(string) int { return 0 }, func(int64) {}, nil)

	// The torn, actively-written file must NOT be sealed as a deferred entry -- doing so would record a Size
	// that disagrees with the sealed chunk bytes and mediad would refuse it forever.
	for _, d := range def {
		if strings.Contains(d.rel, "US_region.mwm") {
			t.Fatalf("a file written during the seal must not be sealed as deferred; got %+v (size %d)", d, d.size)
		}
	}
	// It was positively visited then dropped, so seen must be cleared for it -- otherwise the caller's
	// present-not-deleted rule would treat it as reclassified and DROP any prior stable deferred record.
	if seen[rel] {
		t.Fatalf("seen[%q] must be cleared for a torn file (else a prior deferred record is wrongly dropped)", rel)
	}
}

// TestWalkChunksDeferredSizeIsChunkedBytes locks the invariant behind the fix: a deferred file's recorded Size
// is the EXACT count of bytes fed to the chunker (not a separately-taken stat), so mediad's fetch integrity
// check (manifest Size == sum of chunk plaintext bytes) can never trip.
func TestWalkChunksDeferredSizeIsChunkedBytes(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	dir := t.TempDir()
	body := bytes.Repeat([]byte("MAPDATA0"), 8192) // 64 KiB, stable (not written during the seal)
	iwrite(t, dir, "app.organicmaps/files/260527/US_region.mwm", body)

	sc := newFileScanCache(make([]byte, 32))
	_, _, def, _, _, _, _, _ := walkChunks(dir, sc, 4096, true, ondemandMedia(), nil, nil, nil, nil, 0, func([]byte) int { return 0 }, func(string) int { return 0 }, func(int64) {}, nil)

	if len(def) != 1 {
		t.Fatalf("want 1 deferred file, got %d", len(def))
	}
	// The recorded Size is the count of bytes actually read+chunked. For a stable file that equals the file
	// size; mediad reconstructs exactly that many bytes, so its Size == sum(chunk bytes) check always holds.
	if def[0].size != int64(len(body)) {
		t.Fatalf("deferred Size %d != file size %d (Size must be the bytes chunked, so mediad never refuses it)", def[0].size, len(body))
	}
}

// The tear check must not depend on the CLOCK. Detection used to rest entirely on the mtime differing
// whenever the reader picked up the appended bytes -- because then nb equals the final size and the size
// clause cannot fire. mtime has finite granularity, so a write landing in the same tick as the walk stat
// shared a timestamp and the tear went unseen: this test's own subject failed about 2.5% of the time under
// -count=200 for exactly that reason. Comparing the post-read size against the WALK-TIME size catches
// growth with no clock involved, so this pins the property directly by freezing mtime.
func TestTearIsDetectedEvenWhenMTimeIsUnchanged(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	dir := t.TempDir()
	rel := "app.organicmaps/files/260527/US_region.mwm.ready.downloading"
	iwrite(t, dir, rel, bytes.Repeat([]byte("MAPDATA0"), 8192))
	p := filepath.Join(dir, filepath.FromSlash(rel))

	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	frozen := st.ModTime()

	sc := newFileScanCache(make([]byte, 32))
	grew := false
	emit := func([]byte) int {
		if !grew {
			grew = true
			if f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
				_, _ = f.Write(bytes.Repeat([]byte("MOREDATA"), 8192))
				f.Close()
			}
			// Put the timestamp back exactly where the walk saw it: the worst case the granularity bug
			// produced by accident, made deterministic.
			_ = os.Chtimes(p, frozen, frozen)
		}
		return 0
	}
	_, seen, def, _, _, _, _, _ := walkChunks(dir, sc, 4096, true, ondemandMedia(), nil, nil, nil, nil, 0, emit, func(string) int { return 0 }, func(int64) {}, nil)

	for _, d := range def {
		if strings.Contains(d.rel, "US_region.mwm") {
			t.Fatalf("an unchanged mtime hid the tear -- the size comparison must catch it: %+v", d)
		}
	}
	if seen[rel] {
		t.Fatalf("seen[%q] must be cleared for a torn file", rel)
	}
}
