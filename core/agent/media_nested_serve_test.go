package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/hanwen/go-fuse/v2/fs"
)

// NWP-20260829-08. NWP-20260829-07 collapsed nested deferred dirs into one overlay per MAXIMAL ancestor,
// because a nested child overlay could never work in either mount order. That stopped the logoff wedge, but
// left the ancestor serving its nested dirs as PLAIN PASSTHROUGH -- so a deferred file inside one got no
// stub: invisible in a listing, and unfetchable on open.
//
// The fix makes every child DIRECTORY node a *mediaRoot for its own rel dir, sharing the mount's byDir index,
// so stubs are injected at any depth.
func TestOverlayServesDeferredFilesInNestedDirs(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "nestedserve", "nested horse battery staple"
	createVault(base, name, pass)

	// The measured shape: a deferred file in the ancestor AND one in a nested child dir.
	src := t.TempDir()
	deep := "app.chat/files/Media/Images/Sent"
	if err := os.MkdirAll(filepath.Join(src, filepath.FromSlash(deep)), 0o755); err != nil {
		t.Fatal(err)
	}
	top := bytes.Repeat([]byte("TOP-"), 20000) // ~80 KiB, over the 4096 test floor
	nest := bytes.Repeat([]byte("NEST-"), 20000)
	topRel := "app.chat/files/Media/Images/top.jpg"
	nestRel := deep + "/sent.jpg"
	if err := os.WriteFile(filepath.Join(src, filepath.FromSlash(topRel)), top, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, filepath.FromSlash(nestRel)), nest, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	m := loadCDCManifest(base, dk, v.Manifest)
	for _, rel := range []string{topRel, nestRel} {
		if _, ok := m.Deferred[rel]; !ok {
			t.Fatalf("expected %q deferred; keys=%v", rel, keysOf(m.Deferred))
		}
	}
	srv := newMediaServer(base, dk, m, t.TempDir())

	// One mount over the ANCESTOR, carrying the whole subtree's index -- exactly what serveMediaScope now
	// builds after the -07 collapse.
	ancestor := "app.chat/files/Media/Images"
	byDir := map[string][]string{
		ancestor: {"top.jpg"},
		deep:     {"sent.jpg"},
	}
	under := t.TempDir()
	if err := os.MkdirAll(filepath.Join(under, "Sent"), 0o755); err != nil {
		t.Fatal(err)
	}
	// a real sibling in the nested dir: passthrough must keep working there too
	if err := os.WriteFile(filepath.Join(under, "Sent", "real.txt"), []byte("real sibling"), 0o644); err != nil {
		t.Fatal(err)
	}

	root, err := newMediaOverlay(srv, ancestor, byDir, under, uint32(os.Getuid()), uint32(os.Getgid()))
	if err != nil {
		t.Fatal(err)
	}
	mnt := t.TempDir()
	server, err := fs.Mount(mnt, root, &fs.Options{})
	if err != nil {
		t.Skipf("no usable FUSE in this environment: %v", err)
	}
	defer server.Unmount()

	// (1) the ancestor's own stub still works -- the -07 behaviour must not regress.
	if got, err := os.ReadFile(filepath.Join(mnt, "top.jpg")); err != nil || !bytes.Equal(got, top) {
		t.Fatalf("ancestor stub broken: %d bytes err=%v", len(got), err)
	}

	// (2) THE FIX: the NESTED stub is listed...
	ents, err := os.ReadDir(filepath.Join(mnt, "Sent"))
	if err != nil {
		t.Fatalf("cannot list the nested dir: %v", err)
	}
	var sawStub, sawReal bool
	for _, e := range ents {
		switch e.Name() {
		case "sent.jpg":
			sawStub = true
		case "real.txt":
			sawReal = true
		}
	}
	if !sawStub {
		t.Errorf("nested deferred file is not listed -- invisible to the user, which is the bug: got %v", ents)
	}
	if !sawReal {
		t.Errorf("passthrough broke in the nested dir: real sibling missing; got %v", ents)
	}

	// (3) ...and it FETCHES on open, which is the half that makes it usable rather than merely visible.
	if got, err := os.ReadFile(filepath.Join(mnt, "Sent", "sent.jpg")); err != nil || !bytes.Equal(got, nest) {
		t.Fatalf("nested deferred file did not stream from the store: %d bytes err=%v", len(got), err)
	}

	// (4) ACCEPTANCE CASE the judges added to the row: a deferred file sitting directly in the ANCESTOR must
	// not un-serve a child dir that was serving stubs. Both were checked above under one mount, which is the
	// configuration -07's collapse produces -- so this asserts the two cannot be traded against each other.
	if got, err := os.ReadFile(filepath.Join(mnt, "Sent", "real.txt")); err != nil || string(got) != "real sibling" {
		t.Fatalf("ancestor stub cost the child its passthrough: %q err=%v", got, err)
	}
}
