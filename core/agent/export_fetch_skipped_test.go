package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261110-19: exportFetchMedia is the reference path a media export is checked against. untarFrom soft-skips
// every entry it cannot write and returns the count (DIA-20260806-10); a caller that drops it reports a restore
// that skipped a file as whole. These tests make the destination unable to take notes.txt (a directory already
// sits there) and require an error naming a count, never a path.

func exportSkipEnv(t *testing.T) string {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	return newHTTPStore(t)
}

// exportSkipCDCFixture seals a CDC media head (one deferred file, one essential file) and exports it.
func exportSkipCDCFixture(t *testing.T, name, pass string) (base string, big, small []byte) {
	t.Helper()
	base = exportSkipEnv(t)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "Pictures"), 0o755); err != nil {
		t.Fatal(err)
	}
	big = prBytes(9 << 20)
	if err := os.WriteFile(filepath.Join(src, "Pictures", "trip.jpg"), big, 0o644); err != nil {
		t.Fatal(err)
	}
	small = []byte("holiday notes: remember the lighthouse\n")
	if err := os.WriteFile(filepath.Join(src, "notes.txt"), small, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#media", pass, src)
	if _, m, st := mediaHeadManifest(base, name, pass, nil); st != mediaHeadOpen || len(m.Deferred) != 1 {
		t.Fatalf("fixture: media head state %v with %d deferred (want open, 1)", st, len(m.Deferred))
	}
	if _, _, _, err := exportMedia(base, name, pass, nil); err != nil {
		t.Fatalf("exportMedia: %v", err)
	}
	return base, big, small
}

func exportSkipWantCount(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("exportFetchMedia returned nil although notes.txt could not be written: a partial export read as whole")
	}
	if !strings.Contains(err.Error(), "skipped 1 entr") {
		t.Fatalf("error %q does not name the skipped count", err)
	}
	if strings.Contains(err.Error(), "notes.txt") {
		t.Fatalf("error %q names a path; it must carry a count only", err)
	}
}

// S1: a CDC head whose essential file cannot be written.
func TestExportFetchSkippedCDC(t *testing.T) {
	const name, pass = "exportskip-a", "export skip horse battery"
	base, big, _ := exportSkipCDCFixture(t, name, pass)
	out := t.TempDir()
	if err := os.MkdirAll(filepath.Join(out, "notes.txt"), 0o755); err != nil {
		t.Fatal(err)
	}
	exportSkipWantCount(t, exportFetchMedia(base, name, pass, out))
	got, rerr := os.ReadFile(filepath.Join(out, "Pictures", "trip.jpg"))
	if rerr == nil && bytes.Equal(got, big) {
		t.Fatal("the deferred files were downloaded although the essential region was partial")
	}
}

// S2: the same fixture into an empty destination still succeeds, byte-identical.
func TestExportFetchSkippedControl(t *testing.T) {
	const name, pass = "exportskip-b", "export skip horse battery"
	base, big, small := exportSkipCDCFixture(t, name, pass)
	out := t.TempDir()
	if err := exportFetchMedia(base, name, pass, out); err != nil {
		t.Fatalf("exportFetchMedia into an empty dir: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(out, "Pictures", "trip.jpg")); err != nil || !bytes.Equal(got, big) {
		t.Fatalf("deferred file not byte-identical: %d bytes err=%v", len(got), err)
	}
	if got, err := os.ReadFile(filepath.Join(out, "notes.txt")); err != nil || !bytes.Equal(got, small) {
		t.Fatalf("essential file mismatch: %q err=%v", got, err)
	}
}

// S3: a pre-CDC single-tar media head. No existing test builds one, so it is built here: the sealed tar posted
// as the blob the legacy export pointer names.
func TestExportFetchSkippedLegacy(t *testing.T) {
	const name, pass = "exportskip-c", "export skip horse battery"
	base := exportSkipEnv(t)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "a"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "notes.txt"), []byte("legacy notes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "a", "b.txt"), []byte("legacy b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := postBlob(base, seal(deriveKey(name+"#media", pass), tarDir(src)))
	putRef(base, "export/"+name+"#media", h)

	t.Run("whole", func(t *testing.T) {
		out := t.TempDir()
		if err := exportFetchMedia(base, name, pass, out); err != nil {
			t.Fatalf("exportFetchMedia into an empty dir: %v", err)
		}
		for rel, want := range map[string]string{"notes.txt": "legacy notes\n", "a/b.txt": "legacy b\n"} {
			if got, err := os.ReadFile(filepath.Join(out, filepath.FromSlash(rel))); err != nil || string(got) != want {
				t.Fatalf("%s: %q err=%v", rel, got, err)
			}
		}
	})
	t.Run("partial", func(t *testing.T) {
		out := t.TempDir()
		if err := os.MkdirAll(filepath.Join(out, "notes.txt"), 0o755); err != nil {
			t.Fatal(err)
		}
		exportSkipWantCount(t, exportFetchMedia(base, name, pass, out))
	})
}
