package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// #84 P3b: the go-fuse overlay serves a deferred file from the store on open AND passes real sibling files
// through -- mounting over a deferred dir must not hide the essential files the login restored beside it. This
// does a REAL loopback mount, so it self-skips where the build/CI env has no usable FUSE (no /dev/fuse or no
// fusermount). The on-device proof (an app opening a map through the enforcing context= mount) is #84 P3e.
func TestMediaFuseServesAndPassesThrough(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "mediafs", "overlay horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	region := bytes.Repeat([]byte("REGION-mwm-0123456789-"), 6000) // ~132 KiB
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), region, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	m := loadCDCManifest(base, dk, v.Manifest)
	if _, ok := m.Deferred[rel]; !ok {
		t.Fatalf("expected %q deferred; keys=%v", rel, keysOf(m.Deferred))
	}
	srv := newMediaServer(base, dk, m, t.TempDir())

	// The "underlying" dir the overlay passes through: a small essential sibling the login restored beside the
	// (deferred, not-restored) map. Mounting over the dir must still show BOTH.
	under := t.TempDir()
	essential := []byte("small essential index")
	if err := os.WriteFile(filepath.Join(under, "index.json"), essential, 0o644); err != nil {
		t.Fatal(err)
	}

	root, err := newMediaRoot(srv, "app.maps/files/maps", []string{"region.mwm"}, under, uint32(os.Getuid()), uint32(os.Getgid()))
	if err != nil {
		t.Fatal(err)
	}
	mnt := t.TempDir()
	server, err := fs.Mount(mnt, root, &fs.Options{}) // no context=/DirectMount: plain unprivileged FUSE for the test
	if err != nil {
		t.Skipf("no usable FUSE in this environment: %v", err)
	}
	defer server.Unmount()

	// (1) passthrough: the real sibling is visible and reads correctly through the overlay.
	if got, err := os.ReadFile(filepath.Join(mnt, "index.json")); err != nil || !bytes.Equal(got, essential) {
		t.Fatalf("passthrough sibling wrong: %q err=%v", got, err)
	}
	// (2) deferred: the map is injected, sized from the manifest, and streams from the store on open.
	fi, err := os.Stat(filepath.Join(mnt, "region.mwm"))
	if err != nil || fi.Size() != int64(len(region)) {
		t.Fatalf("deferred stat wrong: size=%v err=%v (want %d)", fi, err, len(region))
	}
	// The stub's presented mtime must be a sane wall-clock time. The manifest stores UnixNano; presenting the
	// nanos AS seconds put st_mtime around year 56e9 -- bionic localtime() returns NULL on that and toybox
	// strftime dereferences it, so stat/ls -l/any scanning app SEGFAULTED on unfetched stubs (FP3 2026-07-03).
	if y := fi.ModTime().Year(); y < 2020 || y > 2100 {
		t.Fatalf("deferred stub mtime insane: %v (nano-as-seconds regression)", fi.ModTime())
	}
	if got, err := os.ReadFile(filepath.Join(mnt, "region.mwm")); err != nil || !bytes.Equal(got, region) {
		t.Fatalf("deferred read mismatch: got %d bytes err=%v (want %d)", len(got), err, len(region))
	}
	// (3) readdir shows both the passthrough sibling and the injected deferred map.
	des, err := os.ReadDir(mnt)
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, de := range des {
		names[de.Name()] = true
	}
	if !names["index.json"] || !names["region.mwm"] {
		t.Fatalf("readdir missing entries: %v", names)
	}
}

// #92 scar-heal: a deferred dir missing from the restored tree (its dir entry was lost by a damage-era seal
// while the deferred entries survived) must be recreated -- nested components and all -- so the overlay can
// mount instead of stranding the files forever. Owner/labels are copied from the nearest existing ancestor
// on-device (root-only, not assertable here); existence and nesting are.
func TestEnsureDeferredDirRecreates(t *testing.T) {
	userDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(userDir, "app.maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := ensureDeferredDir(userDir, filepath.FromSlash("app.maps/files/maps")); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(userDir, "app.maps", "files", "maps"))
	if err != nil || !fi.IsDir() {
		t.Fatalf("deferred dir not recreated: %v", err)
	}
	// idempotent on an existing dir
	if err := ensureDeferredDir(userDir, filepath.FromSlash("app.maps/files/maps")); err != nil {
		t.Fatalf("must be idempotent: %v", err)
	}
}

// setFileAttr must convert the manifest's UnixNano MTime into fuse.Attr's SECONDS(+nsec) -- pure-function
// twin of the mount test's mtime check, so the regression is caught even where the environment has no FUSE
// (the mount test self-skips there).
func TestSetFileAttrMTimeIsSeconds(t *testing.T) {
	when := time.Date(2026, 7, 3, 4, 5, 6, 700000000, time.UTC)
	var a fuse.Attr
	setFileAttr(&a, deferredFile{Size: 42, Mode: 0o600, MTime: when.UnixNano()}, 1, 2)
	if a.Mtime != uint64(when.Unix()) || a.Mtimensec != uint32(when.Nanosecond()) {
		t.Fatalf("mtime not sec+nsec: got %d.%09d want %d.%09d", a.Mtime, a.Mtimensec, when.Unix(), when.Nanosecond())
	}
	if a.Atime != a.Mtime || a.Ctime != a.Mtime {
		t.Fatalf("atime/ctime not mirrored from mtime: a=%d c=%d m=%d", a.Atime, a.Ctime, a.Mtime)
	}
	if a.Size != 42 || a.Mode != fuse.S_IFREG|0o600 || a.Owner.Uid != 1 || a.Owner.Gid != 2 {
		t.Fatalf("size/mode/owner wrong: %+v", a)
	}
	if a.Nlink != 1 {
		t.Fatalf("Nlink=%d; st_nlink 0 reads as deleted to some scanners", a.Nlink)
	}
}
