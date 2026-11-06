package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// NWP-20261115-03: copyFile (mediafs.go) seeds every mediad write-back into the overlay's .under. A copy cut short
// (ENOSPC part way) must leave dst exactly as it was: a cut real file in .under is what the next seal walks and
// records over the stored whole one.

// wbcNoSeed fails the test when dir holds a .nwseed-* temp.
func wbcNoSeed(t *testing.T, dir string) {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("list %s: %v", dir, err)
	}
	for _, e := range es {
		if strings.HasPrefix(e.Name(), ".nwseed-") {
			t.Fatalf("%s holds %s: a failed or finished copy left its temp for the seal to walk", dir, e.Name())
		}
	}
}

// wbcCutSeam replaces copyFileData with a copy that writes limit bytes and then fails with ENOSPC, as a full
// /data does. It counts its calls in *calls (when non-nil) and returns a func that restores the real copy; the
// test's Cleanup restores it too.
func wbcCutSeam(t *testing.T, limit int64, calls *int) (restore func()) {
	t.Helper()
	prev := copyFileData
	copyFileData = func(w io.Writer, r io.Reader) (int64, error) {
		if calls != nil {
			*calls++
		}
		n, err := io.CopyN(w, r, limit)
		if err != nil {
			return n, err
		}
		return n, syscall.ENOSPC
	}
	restore = func() { copyFileData = prev }
	t.Cleanup(restore)
	return restore
}

// wbcMaterializeFixture repeats overlayRaceSetup's steps up to, not including, fs.Mount: a pushed profile with two
// deferred maps, restored into srcB, the .under dir holding index.json, and a mediaServer over m1. No FUSE.
func wbcMaterializeFixture(t *testing.T, tag string) (base, name, pass string, dk []byte, srcB, overlayDir, under string, m1 chunkManifest, srv *mediaServer) {
	t.Helper()
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	// With the reserve at 0, no free-space check can skip these copies on a small TMPDIR.
	t.Setenv("NOWHERE_HEAL_RESERVE", "0")
	base = newHTTPStore(t)
	name, pass = tag, "cut copy seed staple"
	createVault(base, name, pass)
	srcA := t.TempDir()
	if err := os.MkdirAll(filepath.Join(srcA, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/index.json"), []byte("REAL-INDEX"), 0o644)
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/one.mwm"), prBytes(6<<20), 0o644)
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/two.mwm"), append(prBytes(5<<20), 0xEE), 0o644)
	pushProfile(base, name, pass, srcA)
	dk = resolveDK(base, name, pass, nil)
	m1 = headManifest(t, base, dk, name, pass)
	if len(m1.Deferred) != 2 {
		t.Fatalf("setup: want 2 deferred, got %d", len(m1.Deferred))
	}
	_, srcB = restoreManifest(t, base, name, pass)
	overlayDir = filepath.Join(srcB, "app.maps/files/maps")
	under = filepath.Join(srcB, mediaCacheDirName, ".under", "app.maps_files_maps")
	if err := os.MkdirAll(under, 0o700); err != nil {
		t.Fatal(err)
	}
	os.Rename(filepath.Join(overlayDir, "index.json"), filepath.Join(under, "index.json"))
	srv = newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	return
}

// The copy's first read fails (src is a directory, EISDIR): copyFile errors and creates nothing. The pre-change
// copyFile created dst empty and left it.
func TestCopyFileFailureLeavesNoFile(t *testing.T) {
	src := t.TempDir()
	d := t.TempDir()
	dst := filepath.Join(d, "one.mwm")
	if err := copyFile(src, dst, 0o640); err == nil {
		t.Fatal("copyFile from a directory must fail")
	}
	if _, err := os.Lstat(dst); !os.IsNotExist(err) {
		t.Fatalf("a failed copy left dst (err=%v): the next seal walks it and records it over the stored file", err)
	}
	wbcNoSeed(t, d)
}

// A copy cut at 1 MiB of 3 MiB (ENOSPC) leaves dst exactly as it was: absent stays absent, and other bytes stay.
func TestCopyFileCutCopyLeavesDstAlone(t *testing.T) {
	wbcCutSeam(t, 1<<20, nil)
	srcDir := t.TempDir()
	src := filepath.Join(srcDir, "src.mwm")
	if err := os.WriteFile(src, prBytes(3<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Run("no-dst", func(t *testing.T) {
		d := t.TempDir()
		dst := filepath.Join(d, "one.mwm")
		if err := copyFile(src, dst, 0o640); err == nil {
			t.Fatal("a cut copy must fail")
		}
		if _, err := os.Lstat(dst); !os.IsNotExist(err) {
			t.Fatalf("a cut copy landed at dst (err=%v): the seal records it over the stored file", err)
		}
		wbcNoSeed(t, d)
	})
	t.Run("dst-other-bytes", func(t *testing.T) {
		d := t.TempDir()
		dst := filepath.Join(d, "one.mwm")
		other := []byte("OTHER BYTES")
		if err := os.WriteFile(dst, other, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := copyFile(src, dst, 0o640); err == nil {
			t.Fatal("a cut copy must fail")
		}
		if b, err := os.ReadFile(dst); err != nil || !bytes.Equal(b, other) {
			t.Fatalf("a cut copy changed dst (err=%v, len=%d): it must keep its bytes", err, len(b))
		}
		wbcNoSeed(t, d)
	})
}

// A whole copy lands with src's bytes and the mode passed, and leaves no temp.
func TestCopyFileLands(t *testing.T) {
	srcDir := t.TempDir()
	src := filepath.Join(srcDir, "src.mwm")
	want := prBytes(3 << 20)
	if err := os.WriteFile(src, want, 0o600); err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	dst := filepath.Join(d, "one.mwm")
	if err := copyFile(src, dst, 0o640); err != nil {
		t.Fatalf("copyFile: %v", err)
	}
	b, err := os.ReadFile(dst)
	if err != nil || !bytes.Equal(b, want) {
		t.Fatalf("dst does not hold src's bytes (err=%v, len=%d)", err, len(b))
	}
	fi, err := os.Stat(dst)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("dst mode %o, want 640: the temp's 0600 was published", fi.Mode().Perm())
	}
	wbcNoSeed(t, d)
}

// The #108 pin pass (and the #129 Tier-2 prefetch, same materialize) hits ENOSPC part way through each map's copy:
// .under must not hold a cut map, the stubs stay live, and the next seal keeps both stored whole maps.
func TestMaterializeCutCopyKeepsTheStoredFile(t *testing.T) {
	base, name, pass, dk, srcB, overlayDir, under, m1, srv := wbcMaterializeFixture(t, "wbc-materialize-cut")
	calls := 0
	restore := wbcCutSeam(t, 1<<20, &calls)
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)
	if calls != 2 {
		t.Fatalf("the copy ran %d time(s), want 2 (one per map): materialize never reached the copy, so this test proves nothing", calls)
	}
	for _, n := range []string{"one.mwm", "two.mwm"} {
		if _, err := os.Lstat(filepath.Join(under, n)); !os.IsNotExist(err) {
			t.Fatalf("%s is in .under after a cut copy (err=%v): the next seal records it over the stored file", n, err)
		}
		if rel := "app.maps/files/maps/" + n; srv.isDeleted(rel) {
			t.Fatalf("%s was tombstoned after a cut copy: its stub must stay live", rel)
		}
	}
	wbcNoSeed(t, under)

	restore()
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	for _, n := range []string{"one.mwm", "two.mwm"} {
		rel := "app.maps/files/maps/" + n
		got, ok := m2.Deferred[rel]
		if !ok {
			t.Fatalf("%s is no longer deferred after the seal: a cut copy was sealed over the stored file; deferred=%v", rel, keysOf(m2.Deferred))
		}
		want := m1.Deferred[rel]
		if got.Size != want.Size || !reflect.DeepEqual(got.Chunks, want.Chunks) {
			t.Fatalf("%s sealed as %d bytes / %d chunks, stored %d / %d: a cut copy was sealed over the stored file", rel, got.Size, len(got.Chunks), want.Size, len(want.Chunks))
		}
	}
}
