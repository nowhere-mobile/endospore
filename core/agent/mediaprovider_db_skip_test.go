package main

import (
	"archive/tar"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// NWP-20261202-02 (docs/product-decisions.md, 2026-11-10, option A): MediaProvider's external.db and internal.db
// (with -wal, -shm, -journal, both module names) are never sealed, and a restore of an older head that still
// carries them leaves them unwritten without withholding the receipt.

const (
	mpdbPkgAOSP   = "com.android.providers.media.module"
	mpdbPkgGoogle = "com.google.android.providers.media.module"
	mpdbSibling   = mpdbPkgAOSP + "/databases/other.db"
	mpdbApp       = "app.other/files/x"
)

func TestMediaProviderDBRelPredicate(t *testing.T) {
	n := 0
	for _, pkg := range []string{mpdbPkgAOSP, mpdbPkgGoogle} {
		for _, db := range []string{"external.db", "internal.db"} {
			for _, sfx := range []string{"", "-wal", "-shm", "-journal"} {
				rel := pkg + "/databases/" + db + sfx
				n++
				if !isMediaProviderDBRel(rel) {
					t.Errorf("isMediaProviderDBRel(%q) = false, want true", rel)
				}
			}
		}
	}
	if n != 16 {
		t.Fatalf("fixture: %d positives, want 16", n)
	}
	if !isMediaProviderDBRel("/" + mpdbPkgAOSP + "/databases/external.db") {
		t.Errorf("a leading '/' is not trimmed")
	}
	for _, rel := range []string{
		mpdbPkgAOSP + "/databases",
		mpdbPkgAOSP + "/databases/",
		mpdbSibling,
		"com.example.app/databases/external.db",
		"Android/data/" + mpdbPkgAOSP + "/databases/external.db",
		"x/" + mpdbPkgAOSP + "/databases/external.db",
		mpdbPkgAOSP + "/databases/external.db-wal2",
		mpdbPkgAOSP + "/files/external.db",
		mpdbPkgAOSP + "/databases/sub/external.db",
		"external.db",
	} {
		if isMediaProviderDBRel(rel) {
			t.Errorf("isMediaProviderDBRel(%q) = true, want false", rel)
		}
	}
}

// mpdbTree writes a CE-shaped scope root: five MediaProvider database files under both module names, a sibling
// database of the same package and an unrelated app file. Returns the root and the five files' exact bytes.
func mpdbTree(t *testing.T) (src string, mpBytes int64) {
	t.Helper()
	src = t.TempDir()
	for rel, n := range map[string]int{
		mpdbPkgAOSP + "/databases/external.db":           7000,
		mpdbPkgAOSP + "/databases/external.db-wal":       3000,
		mpdbPkgAOSP + "/databases/external.db-shm":       200,
		mpdbPkgGoogle + "/databases/internal.db":         4000,
		mpdbPkgGoogle + "/databases/internal.db-journal": 50,
	} {
		iwrite(t, src, rel, bytes.Repeat([]byte("M"), n))
		mpBytes += int64(n)
	}
	iwrite(t, src, mpdbSibling, bytes.Repeat([]byte("S"), 5000))
	iwrite(t, src, mpdbApp, bytes.Repeat([]byte("A"), 6000))
	return src, mpBytes
}

func TestMediaProviderDBSkippedByWalkChunks(t *testing.T) {
	src, mp := mpdbTree(t)
	next := 0
	emit := func([]byte) int { i := next; next++; return i }
	ranges, seen, deferred, _, _, dropped, _, _ := walkChunks(src, newFileScanCache(make([]byte, 32)), 4096, true, false,
		nil, nil, nil, nil, 0, emit, func(string) int { return 0 }, func(int64) {}, nil)
	for _, r := range ranges {
		if isMediaProviderDBRel(r.rel) {
			t.Errorf("range for %q: a MediaProvider database was sealed", r.rel)
		}
	}
	for rel := range seen {
		if isMediaProviderDBRel(rel) {
			t.Errorf("seen holds %q", rel)
		}
	}
	for _, d := range deferred {
		if isMediaProviderDBRel(d.rel) {
			t.Errorf("deferred holds %q", d.rel)
		}
	}
	if !seen[mpdbSibling] || !seen[mpdbApp] {
		t.Errorf("a sibling file was not sealed: %q=%v %q=%v", mpdbSibling, seen[mpdbSibling], mpdbApp, seen[mpdbApp])
	}
	if dropped != mp {
		t.Errorf("dropped = %d, want exactly %d: the shrink guard must price the skipped databases", dropped, mp)
	}
}

func TestMediaProviderDBSkippedByTarDirTo(t *testing.T) {
	src, mp := mpdbTree(t)
	var buf bytes.Buffer
	dropped, err := tarDirTo(src, &buf)
	if err != nil {
		t.Fatal(err)
	}
	if dropped != mp {
		t.Errorf("tarDirTo dropped = %d, want exactly %d: the shrink guard must price the skipped databases", dropped, mp)
	}
	tr := tar.NewReader(&buf)
	sibling, dbDir := false, false
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		name := strings.TrimSuffix(h.Name, "/")
		if isMediaProviderDBRel(name) {
			t.Errorf("tar holds %q", h.Name)
		}
		if name == mpdbSibling {
			sibling = true
		}
		if name == mpdbPkgAOSP+"/databases" {
			dbDir = true
		}
	}
	if !sibling {
		t.Errorf("the sibling %q is not in the tar", mpdbSibling)
	}
	if !dbDir {
		t.Errorf("the databases directory entry is not in the tar")
	}
}

func TestMediaProviderDBNotWrittenByUntarFrom(t *testing.T) {
	dir := t.TempDir()
	ext := mpdbPkgAOSP + "/databases/external.db"
	live := []byte("LIVE-PROVIDER-INDEX")
	iwrite(t, dir, ext, live)
	old := time.Unix(1_600_000_000, 0)
	if err := os.Chtimes(filepath.Join(dir, ext), old, old); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(filepath.Join(dir, ext))
	if err != nil {
		t.Fatal(err)
	}
	ino := before.Sys().(*syscall.Stat_t).Ino

	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range []struct{ name, body string }{
		{ext, "SEALED-OLD-INDEX-LONGER-THAN-LIVE"},
		{ext + "-wal", "SEALED-WAL"},
		{mpdbApp, "app-data"},
	} {
		if err := tw.WriteHeader(&tar.Header{Name: e.name, Mode: 0o600, Size: int64(len(e.body)), Typeflag: tar.TypeReg, ModTime: time.Unix(1_700_000_000, 0)}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(e.body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}

	var skipped int
	errOut := captureStderr(t, func() { skipped = untarFrom(dir, &buf) })
	if skipped != 0 {
		t.Errorf("untarFrom = %d, want 0: a MediaProvider database left unwritten must not withhold the receipt", skipped)
	}
	after, err := os.Stat(filepath.Join(dir, ext))
	if err != nil {
		t.Fatal(err)
	}
	if got := after.Sys().(*syscall.Stat_t).Ino; got != ino {
		t.Errorf("external.db inode %d -> %d: the restore replaced the live file", ino, got)
	}
	if after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		t.Errorf("external.db size/mtime %d/%v -> %d/%v: the restore wrote it", before.Size(), before.ModTime(), after.Size(), after.ModTime())
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ext)); !bytes.Equal(b, live) {
		t.Errorf("external.db content = %q, want %q", b, live)
	}
	if _, err := os.Lstat(filepath.Join(dir, ext+"-wal")); !os.IsNotExist(err) {
		t.Errorf("external.db-wal exists after the restore (err=%v)", err)
	}
	if b, err := os.ReadFile(filepath.Join(dir, mpdbApp)); err != nil || string(b) != "app-data" {
		t.Errorf("the normal file did not land: %q, %v", b, err)
	}
	line := "[restore] left 2 MediaProvider database file(s) of an older seal unrestored (NWP-20261202-02)"
	if c := strings.Count(errOut, line); c != 1 {
		t.Errorf("stderr holds the line %d times, want 1; stderr:\n%s", c, errOut)
	}
	if strings.Contains(errOut, "external.db") {
		t.Errorf("stderr names a path: %s", errOut)
	}
}

func TestMediaProviderDBNotCountedBySealDeltaWalk(t *testing.T) {
	src, _ := mpdbTree(t)
	out := sealDeltaWalk(map[string]string{"ce": src}, nil, nil, nil, time.Now().Add(-time.Hour).Unix())
	if out.ChangedFiles != 2 || out.ChangedBytes != 11000 {
		t.Errorf("sealDeltaWalk changed %d files / %d bytes, want 2 / 11000 (other.db + x only)", out.ChangedFiles, out.ChangedBytes)
	}
}
