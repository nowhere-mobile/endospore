package main

// NWP-20261110-05: the mid-session media sync follows no link.
//
// writeMaterialized lands another handset's file as root. A symlink an app planted at a level below the scope
// root must be refused, not followed: the file would otherwise be created and renamed into whatever directory
// the link names. Found by reading the code, not seen on a device. Fixtures live under t.TempDir(); the owner
// seams are stubbed by stubExtOwners (media_app_ext_owner_test.go), so no root is needed.

import (
	"archive/tar"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func noLinkHdr() *tar.Header {
	return &tar.Header{Mode: 0o640, ModTime: time.Unix(1788000000, 0)}
}

// noLinkRequireEmpty fails if anything at all (a file, a .nwsync-* temp, a created dir) sits in dir.
func noLinkRequireEmpty(t *testing.T, dir string) {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		t.Errorf("the write reached through the link: %q now sits outside the scope root", e.Name())
	}
}

func noLinkMust(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestMediaSyncNoLink_L1_AppExtLinkRefused(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	recs := stubExtOwners(t, root)
	files := filepath.Join(root, "Android", "data", "com.example", "files")
	noLinkMust(t, os.MkdirAll(files, 0o770))
	noLinkMust(t, os.Symlink(outside, filepath.Join(files, "x")))
	err := writeMaterialized(filepath.Join(files, "x", "bindings.conf"), root, noLinkHdr(), []byte("bytes"))
	if err == nil {
		t.Fatal("a write through a link in an app's external data was accepted")
	}
	noLinkRequireEmpty(t, outside)
	if len(*recs) != 0 {
		t.Errorf("chowns recorded on a refused write: %v", *recs)
	}
}

func TestMediaSyncNoLink_L2_LinkOneLevelDeeper(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	stubExtOwners(t, root)
	a := filepath.Join(root, "Android", "data", "com.example", "files", "a")
	noLinkMust(t, os.MkdirAll(a, 0o770))
	noLinkMust(t, os.Symlink(outside, filepath.Join(a, "b")))
	err := writeMaterialized(filepath.Join(a, "b", "c", "f.bin"), root, noLinkHdr(), []byte("bytes"))
	if err == nil {
		t.Fatal("a write through a nested link was accepted")
	}
	noLinkRequireEmpty(t, outside)
}

func TestMediaSyncNoLink_L3_SharedMediaLinkRefused(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	stubExtOwners(t, root)
	noLinkMust(t, os.Symlink(outside, filepath.Join(root, "DCIM")))
	err := writeMaterialized(filepath.Join(root, "DCIM", "Camera", "p.jpg"), root, noLinkHdr(), []byte("bytes"))
	if err == nil {
		t.Fatal("a write through a linked DCIM was accepted")
	}
	noLinkRequireEmpty(t, outside)
}

func TestMediaSyncNoLink_L3b_LastLevelLinkRefused(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	stubExtOwners(t, root)
	noLinkMust(t, os.MkdirAll(filepath.Join(root, "DCIM"), 0o770))
	noLinkMust(t, os.Symlink(outside, filepath.Join(root, "DCIM", "Camera")))
	err := writeMaterialized(filepath.Join(root, "DCIM", "Camera", "p.jpg"), root, noLinkHdr(), []byte("bytes"))
	if err == nil {
		t.Fatal("a write through a linked last directory level was accepted")
	}
	noLinkRequireEmpty(t, outside)
}

func TestMediaSyncNoLink_L4_FileWhereADirShouldBe(t *testing.T) {
	root := t.TempDir()
	stubExtOwners(t, root)
	noLinkMust(t, os.MkdirAll(filepath.Join(root, "DCIM"), 0o770))
	blocker := filepath.Join(root, "DCIM", "Camera")
	noLinkMust(t, os.WriteFile(blocker, []byte("mine"), 0o660))
	err := writeMaterialized(filepath.Join(blocker, "p.jpg"), root, noLinkHdr(), []byte("bytes"))
	if !errors.Is(err, errNotDirOnPath) {
		t.Fatalf("err = %v, want errNotDirOnPath", err)
	}
	if b, rerr := os.ReadFile(blocker); rerr != nil || string(b) != "mine" {
		t.Errorf("the file in the way = %q, %v; want it untouched", b, rerr)
	}
}

func TestMediaSyncNoLink_L5_RealDirsStillLand(t *testing.T) {
	root := t.TempDir()
	recs := stubExtOwners(t, root)
	app := filepath.Join(root, "Android", "data", "com.example", "files", "x", "bindings.conf")
	noLinkMust(t, os.MkdirAll(filepath.Dir(filepath.Dir(app)), 0o770)) // files/ is real; x/ is created
	noLinkMust(t, writeMaterialized(app, root, noLinkHdr(), []byte("app bytes")))
	shared := filepath.Join(root, "DCIM", "Camera", "p.jpg")
	noLinkMust(t, writeMaterialized(shared, root, noLinkHdr(), []byte("photo")))
	for p, want := range map[string]string{app: "app bytes", shared: "photo"} {
		b, err := os.ReadFile(p)
		if err != nil || string(b) != want {
			t.Fatalf("%s = %q, %v; want %q", filepath.Base(p), b, err, want)
		}
		st, _ := os.Lstat(p)
		if st.Mode().Perm() != 0o640 {
			t.Errorf("%s mode = %v, want 0640", filepath.Base(p), st.Mode().Perm())
		}
	}
	var appRecs []chownRec
	sharedChowns := 0
	for _, r := range *recs {
		if strings.Contains(r.path, "com.example") {
			appRecs = append(appRecs, r)
		} else if r.uid == extRootUID && r.gid == extRootGID {
			sharedChowns++
		} else {
			t.Errorf("shared media chowned to %d:%d, want the scope root's", r.uid, r.gid)
		}
	}
	requireAppOwned(t, appRecs, root, app, filepath.Dir(app))
	if sharedChowns != 1 {
		t.Errorf("shared media chowns = %d, want 1", sharedChowns)
	}
}

func TestMediaSyncNoLink_L6_MkdirOwnedBelowRefusesALink(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	recs := stubExtOwners(t, root)
	pkgDir := filepath.Join(root, "Android", "data", "com.example")
	noLinkMust(t, os.MkdirAll(filepath.Join(pkgDir, "files"), 0o770))
	noLinkMust(t, os.Symlink(outside, filepath.Join(pkgDir, "files", "x")))
	err := mkdirOwnedBelow(pkgDir, filepath.Join(pkgDir, "files", "x", "y"), extAppUID, extAppGID)
	if err == nil {
		t.Fatal("mkdirOwnedBelow accepted a link as an existing level")
	}
	noLinkRequireEmpty(t, outside)
	if len(*recs) != 0 {
		t.Errorf("chowns recorded: %v", *recs)
	}
}

func TestMediaSyncNoLink_HelperContract(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	noLinkMust(t, os.MkdirAll(filepath.Join(root, "a", "b"), 0o770))
	noLinkMust(t, os.WriteFile(filepath.Join(root, "f"), nil, 0o660))
	noLinkMust(t, os.Symlink(outside, filepath.Join(root, "a", "lnk")))
	cases := []struct {
		name string
		dir  string
		want error
	}{
		{"root itself", root, nil},
		{"real chain", filepath.Join(root, "a", "b"), nil},
		{"missing tail", filepath.Join(root, "a", "b", "c", "d"), nil},
		{"link is the last level", filepath.Join(root, "a", "lnk"), errLinkOnPath},
		{"link mid-path", filepath.Join(root, "a", "lnk", "z"), errLinkOnPath},
		{"file mid-path", filepath.Join(root, "f", "z"), errNotDirOnPath},
		{"outside the root", outside, errDirOutsideRoot},
	}
	for _, c := range cases {
		err := noLinkBelow(root, c.dir)
		if c.want == nil && err != nil || c.want != nil && !errors.Is(err, c.want) {
			t.Errorf("%s: err = %v, want %v", c.name, err, c.want)
		}
	}
}

func TestMediaSyncNoLink_RefusalNamesNoPath(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	pkg := filepath.Join(root, "Android", "data", "com.example")
	noLinkMust(t, os.MkdirAll(pkg, 0o770))
	noLinkMust(t, os.Symlink(outside, filepath.Join(pkg, "x")))
	for _, dir := range []string{filepath.Join(pkg, "x"), filepath.Join(pkg, "x", "y")} {
		err := noLinkBelow(root, dir)
		if err == nil {
			t.Fatalf("no refusal for %s", filepath.Base(dir))
		}
		s := errCode(err)
		for _, bad := range []string{"/", root, outside, "com.example"} {
			if strings.Contains(s, bad) {
				t.Errorf("errCode(%v) = %q holds %q", err, s, bad)
			}
		}
	}
}
