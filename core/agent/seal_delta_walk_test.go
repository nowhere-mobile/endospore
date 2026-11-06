package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// #145 S5 (NWP-20260901-29): the two walk rules, and their failure directions. Over-counting is the safe
// direction; a blind path is flagged and never folded into the byte figure; no baseline means rule B is off.

func writeAged(t *testing.T, path string, size int, mtime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func TestSealDeltaWalkRules(t *testing.T) {
	root := t.TempDir()
	since := time.Now().Add(-10 * time.Minute)
	old := since.Add(-time.Hour)
	fresh := since.Add(time.Minute)

	writeAged(t, filepath.Join(root, "app.a", "old.bin"), 100, old)                                         // old, no record -> not counted
	writeAged(t, filepath.Join(root, "app.a", "new.bin"), 200, fresh)                                       // fresh -> rule B
	writeAged(t, filepath.Join(root, "app.b", "same.map"), 300, old)                                        // deferred record MATCHES -> not counted
	writeAged(t, filepath.Join(root, "app.b", "grown.map"), 400, old)                                       // deferred record size-mismatch -> rule A, despite old mtime
	writeAged(t, filepath.Join(root, ".nowhere-media", "cache.bin"), 500, fresh)                            // cache: skipped
	writeAged(t, filepath.Join(root, "com.nowhere.chooser", "files", ".appcode", "p", "x.apk"), 600, fresh) // staging: skipped

	idx := map[string]sealDeltaIdxEnt{
		sealDeltaIdxKey("vault", "app.b/same.map"):  {size: 300, mtime: old.Unix()},
		sealDeltaIdxKey("vault", "app.b/grown.map"): {size: 999, mtime: old.Unix()},
	}
	out := sealDeltaWalk(map[string]string{"vault": root}, nil, idx, nil, since.Unix())
	if out.ChangedBytes != 200 || out.ChangedFiles != 1 {
		t.Errorf("rule B: %d bytes / %d files, want 200/1", out.ChangedBytes, out.ChangedFiles)
	}
	if out.DeferredBytes != 400 || out.DeferredFiles != 1 {
		t.Errorf("rule A: %d bytes / %d files, want 400/1", out.DeferredBytes, out.DeferredFiles)
	}
	if out.Blind != 0 {
		t.Errorf("blind = %d, want 0", out.Blind)
	}

	// No baseline: rule B is OFF entirely -- only the exact rule may speak. "Your whole profile is unsaved"
	// at first open is the lie the scan-cache shortcut was rejected for.
	out0 := sealDeltaWalk(map[string]string{"vault": root}, nil, idx, nil, 0)
	if out0.ChangedBytes != 0 || out0.ChangedFiles != 0 {
		t.Errorf("since=0 rule B leaked: %d bytes / %d files, want 0/0", out0.ChangedBytes, out0.ChangedFiles)
	}
	if out0.DeferredBytes != 400 {
		t.Errorf("since=0 rule A = %d, want 400 (baseline-free)", out0.DeferredBytes)
	}
}

// An overlaid dir is measured through its .under backing tree -- the real bytes the seal will read -- and
// the overlay itself is never walked (a FUSE overlay reports manifest sizes for never-downloaded files).
func TestSealDeltaWalkUnders(t *testing.T) {
	root := t.TempDir()
	backing := t.TempDir()
	since := time.Now().Add(-10 * time.Minute)
	fresh := since.Add(time.Minute)

	overlaid := filepath.Join(root, "Download")
	if err := os.MkdirAll(overlaid, 0o755); err != nil {
		t.Fatal(err)
	}
	writeAged(t, filepath.Join(overlaid, "overlay-view.bin"), 5000, fresh) // must NOT be read
	writeAged(t, filepath.Join(backing, "real.bin"), 700, fresh)           // must be counted, under Download/

	out := sealDeltaWalk(map[string]string{"media": root},
		map[string]string{overlaid: backing}, nil, nil, since.Unix())
	if out.ChangedBytes != 700 || out.ChangedFiles != 1 {
		t.Errorf("unders: %d bytes / %d files, want 700/1 (backing tree only)", out.ChangedBytes, out.ChangedFiles)
	}
}

// A blind path is COUNTED AND FLAGGED, never folded into the byte figure -- a number over a tree it could
// not read is a claim.
func TestSealDeltaWalkBlind(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("chmod-000 blindness needs a non-root POSIX runner")
	}
	root := t.TempDir()
	since := time.Now().Add(-10 * time.Minute)
	sealed := filepath.Join(root, "app.c", "locked")
	writeAged(t, filepath.Join(sealed, "hidden.bin"), 800, since.Add(time.Minute))
	if err := os.Chmod(sealed, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(sealed, 0o755) })
	out := sealDeltaWalk(map[string]string{"vault": root}, nil, nil, nil, since.Unix())
	if out.Blind == 0 {
		t.Error("unreadable dir not flagged blind")
	}
	if out.ChangedBytes != 0 {
		t.Errorf("blind bytes folded into the figure: %d", out.ChangedBytes)
	}
}

func TestSealDeltaIdxRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "sealdelta.idx")
	in := map[string]map[string]deferredFile{
		"vault": {"app.b/grown.map": {Size: 999, MTime: 1234}},
		"media": {"Download/big.apkm": {Size: 5, MTime: 6}},
	}
	if err := writeSealDeltaIdx(p, in); err != nil {
		t.Fatal(err)
	}
	got := readSealDeltaIdx(p)
	if len(got) != 2 {
		t.Fatalf("entries = %d, want 2 (%v)", len(got), got)
	}
	if e := got[sealDeltaIdxKey("vault", "app.b/grown.map")]; e.size != 999 || e.mtime != 1234 {
		t.Errorf("vault entry = %+v", e)
	}
	if e := got[sealDeltaIdxKey("media", "Download/big.apkm")]; e.size != 5 || e.mtime != 6 {
		t.Errorf("media entry = %+v", e)
	}
}

// NWP-20261027-03: deferredFile.MTime is UnixNano when the seal wrote it and unix SECONDS when the web importer
// did. Rule A compares in the record's own unit, so a seal-written record that matches the file is not counted.

// sealShapedFile writes a file and returns it with its stat, the way the seal records it.
func sealShapedFile(t *testing.T, root string, size int) (string, os.FileInfo) {
	t.Helper()
	p := filepath.Join(root, "app.s", "photo.jpg")
	// a sub-second mtime, as every real file has
	writeAged(t, p, size, time.Unix(1_700_000_000, 123_456_789))
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return p, fi
}

func walkOne(root string, ent sealDeltaIdxEnt) sealDeltaWalkOut {
	idx := map[string]sealDeltaIdxEnt{sealDeltaIdxKey("vault", "app.s/photo.jpg"): ent}
	return sealDeltaWalk(map[string]string{"vault": root}, nil, idx, nil, 0)
}

func TestSealDeltaWalkSealShapedRecordMatchesIsNotCounted(t *testing.T) {
	root := t.TempDir()
	_, fi := sealShapedFile(t, root, 1234)
	out := walkOne(root, sealDeltaIdxEnt{size: fi.Size(), mtime: fi.ModTime().UnixNano()})
	if out.DeferredBytes != 0 || out.DeferredFiles != 0 {
		t.Errorf("seal-shaped matching record counted: %d bytes / %d files, want 0/0", out.DeferredBytes, out.DeferredFiles)
	}
}

func TestSealDeltaWalkSealShapedRecordMismatchIsCounted(t *testing.T) {
	root := t.TempDir()
	p, fi := sealShapedFile(t, root, 1234)
	ent := sealDeltaIdxEnt{size: fi.Size(), mtime: fi.ModTime().UnixNano()}

	// mtime moved by 1 ns
	moved := fi.ModTime().Add(time.Nanosecond)
	if err := os.Chtimes(p, moved, moved); err != nil {
		t.Fatal(err)
	}
	if out := walkOne(root, ent); out.DeferredBytes != 1234 || out.DeferredFiles != 1 {
		t.Errorf("1 ns mtime move: %d bytes / %d files, want 1234/1", out.DeferredBytes, out.DeferredFiles)
	}

	// one byte appended, mtime restored to the recorded one
	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if err := os.Chtimes(p, fi.ModTime(), fi.ModTime()); err != nil {
		t.Fatal(err)
	}
	if out := walkOne(root, ent); out.DeferredBytes != 1235 || out.DeferredFiles != 1 {
		t.Errorf("1 byte append: %d bytes / %d files, want 1235/1", out.DeferredBytes, out.DeferredFiles)
	}
}

func TestSealDeltaWalkImporterSecondsRecord(t *testing.T) {
	root := t.TempDir()
	p := filepath.Join(root, "app.s", "photo.jpg")
	sec := time.Unix(1_700_000_000, 500_000_000) // sub-second, as the importer-era files were
	writeAged(t, p, 50, sec)
	if out := walkOne(root, sealDeltaIdxEnt{size: 50, mtime: sec.Unix()}); out.DeferredFiles != 0 {
		t.Errorf("seconds record on the exact second counted: %d files, want 0", out.DeferredFiles)
	}
	if out := walkOne(root, sealDeltaIdxEnt{size: 50, mtime: sec.Unix() + 1}); out.DeferredFiles != 1 || out.DeferredBytes != 50 {
		t.Errorf("seconds record on a different second: %d bytes / %d files, want 50/1", out.DeferredBytes, out.DeferredFiles)
	}
}

// The nanosecond value must survive the daemon's text index file (writeSealDeltaIdx -> readSealDeltaIdx).
func TestSealDeltaWalkSealShapedRecordThroughIdxFile(t *testing.T) {
	root := t.TempDir()
	_, fi := sealShapedFile(t, root, 777)
	idxPath := filepath.Join(t.TempDir(), "idx")
	scopes := map[string]map[string]deferredFile{
		"vault": {"app.s/photo.jpg": {Size: fi.Size(), MTime: fi.ModTime().UnixNano()}},
	}
	if err := writeSealDeltaIdx(idxPath, scopes); err != nil {
		t.Fatal(err)
	}
	idx := readSealDeltaIdx(idxPath)
	out := sealDeltaWalk(map[string]string{"vault": root}, nil, idx, nil, 0)
	if out.DeferredBytes != 0 || out.DeferredFiles != 0 {
		t.Errorf("round-tripped seal-shaped record counted: %d bytes / %d files, want 0/0", out.DeferredBytes, out.DeferredFiles)
	}
}
