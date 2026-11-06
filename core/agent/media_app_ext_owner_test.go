package main

// NWP-20261011-47: a mid-session materialise into an app's OWN external data takes the APP's owner.
//
// writeMaterialized gives a landed file the scope root's owner, which is right for DCIM and Pictures and wrong
// for Android/{data,obb}/<pkg>: that tree is appUid:ext_data_rw / appUid:ext_obb_rw (roamd's reown_ext_appdata
// puts it back after a LOGIN restore), and the storage pass-through DAC-checks the owner, so a media_rw file
// under a root-owned directory locks the app out of its own files until the next login.
//
// ⚠ THE OWNER LOOKUP IS STUBBED, AND HAS TO BE. In a temp dir the scope root and Android/data/<pkg> have the
// same uid:gid, and without root a test cannot chown them apart -- so an assertion on real ownership would pass
// on the old code too. materializeOwnerOf answers 1023:1023 for the root and 10123:1078 for the package dir,
// and materializeChown records instead of chowning.

import (
	"archive/tar"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	extRootUID, extRootGID = 1023, 1023  // media_rw, what the scope root carries
	extAppUID, extAppGID   = 10123, 1078 // an app uid : ext_data_rw
)

type chownRec struct {
	path     string
	uid, gid int
}

// stubExtOwners points the two seams at root: root/Android/data/com.example is the installed app's package dir,
// root/Android/data/com.absent is not on this handset, and nothing else has an owner to report.
func stubExtOwners(t *testing.T, root string) *[]chownRec {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "Android", "data", "com.example"), 0o770); err != nil {
		t.Fatal(err)
	}
	pkgDir := filepath.Join(root, "Android", "data", "com.example")
	recs := &[]chownRec{}
	oldChown, oldOwner := materializeChown, materializeOwnerOf
	t.Cleanup(func() { materializeChown, materializeOwnerOf = oldChown, oldOwner })
	materializeChown = func(path string, uid, gid int) error {
		*recs = append(*recs, chownRec{path, uid, gid})
		return nil
	}
	materializeOwnerOf = func(path string) (int, int, bool) {
		switch filepath.Clean(path) {
		case filepath.Clean(root):
			return extRootUID, extRootGID, true
		case pkgDir:
			return extAppUID, extAppGID, true
		}
		return 0, 0, false
	}
	return recs
}

// requireAppOwned asserts the landed file and each named created dir were chowned to the app, that nothing
// was chowned to anything else, and that the pre-existing package dir was left alone.
func requireAppOwned(t *testing.T, recs []chownRec, root, target string, createdDirs ...string) {
	t.Helper()
	pkgDir := filepath.Join(root, "Android", "data", "com.example")
	sawFile := false
	sawDir := map[string]bool{}
	for _, r := range recs {
		if r.uid != extAppUID || r.gid != extAppGID {
			t.Errorf("chown %s -> %d:%d, want the package dir's %d:%d. Taking the scope root's owner is what "+
				"lands another handset's file media_rw-owned in the app's own Android/data, where the "+
				"pass-through DAC-checks the owner and the app cannot read it until the next login.",
				r.path, r.uid, r.gid, extAppUID, extAppGID)
		}
		if r.path == pkgDir {
			t.Errorf("the pre-existing package dir was chowned: it already carries the owner the login gave it")
		}
		// The file is chowned as its .nwsync-* temp, before the rename onto target.
		if filepath.Dir(r.path) == filepath.Dir(target) && strings.HasPrefix(filepath.Base(r.path), ".nwsync-") {
			sawFile = true
		}
		sawDir[r.path] = true
	}
	if !sawFile {
		t.Errorf("no chown was recorded for the landed file %s (recorded: %v)", target, recs)
	}
	for _, d := range createdDirs {
		if !sawDir[d] {
			t.Errorf("the created directory %s was never chowned to the app; a root-owned dir locks the app out of "+
				"everything beneath it (recorded: %v)", d, recs)
		}
	}
}

func TestMaterialize_AppExtFileTakesThePackageDirOwner(t *testing.T) {
	root := t.TempDir()
	recs := stubExtOwners(t, root)

	target := filepath.Join(root, filepath.FromSlash("Android/data/com.example/files/a/b.bin"))
	hdr := &tar.Header{Mode: 0o660, ModTime: time.Unix(1788000000, 0)}
	if err := writeMaterialized(target, root, hdr, []byte("bytes")); err != nil {
		t.Fatalf("writeMaterialized: %v", err)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "bytes" {
		t.Fatalf("the file did not land (%v, %q)", err, string(got))
	}
	pkgDir := filepath.Join(root, "Android", "data", "com.example")
	requireAppOwned(t, *recs, root, target, filepath.Join(pkgDir, "files"), filepath.Join(pkgDir, "files", "a"))
	if len(*recs) != 3 {
		t.Errorf("recorded %d chown(s), want 3 (files, files/a, the file): %v", len(*recs), *recs)
	}
}

func TestMaterialize_AppExtFileWaitsWhenTheAppIsNotInstalledHere(t *testing.T) {
	root := t.TempDir()
	recs := stubExtOwners(t, root)

	target := filepath.Join(root, filepath.FromSlash("Android/data/com.absent/files/c.bin"))
	err := writeMaterialized(target, root, &tar.Header{Mode: 0o660}, []byte("bytes"))
	if !errors.Is(err, errAppExtNotHere) {
		t.Fatalf("writeMaterialized = %v, want errAppExtNotHere: with no package dir here there is no owner to "+
			"give the file, and landing it media_rw-owned is the lock-out this guards against", err)
	}
	if _, serr := os.Lstat(filepath.Join(root, "Android", "data", "com.absent")); serr == nil {
		t.Error("a package dir was created for an app that is not installed here")
	}
	if len(*recs) != 0 {
		t.Errorf("chowned %v for a rel that was not written", *recs)
	}
}

// The control: shared media keeps the scope root's owner.
func TestMaterialize_SharedMediaStillTakesTheRootOwner(t *testing.T) {
	root := t.TempDir()
	recs := stubExtOwners(t, root)

	target := filepath.Join(root, filepath.FromSlash("DCIM/Camera/x.jpg"))
	if err := writeMaterialized(target, root, &tar.Header{Mode: 0o660}, []byte("bytes")); err != nil {
		t.Fatalf("writeMaterialized: %v", err)
	}
	if len(*recs) != 1 {
		t.Fatalf("recorded %v, want the one chown of the landed file", *recs)
	}
	if r := (*recs)[0]; r.uid != extRootUID || r.gid != extRootGID ||
		!strings.HasPrefix(filepath.Base(r.path), ".nwsync-") {
		t.Errorf("the DCIM file was chowned %s -> %d:%d, want the scope root's %d:%d", r.path, r.uid, r.gid,
			extRootUID, extRootGID)
	}
}

func TestAppExtOwnerDir(t *testing.T) {
	for rel, want := range map[string]string{
		"Android/data/com.example/files/x": "/r/Android/data/com.example",
		"Android/obb/com.example/main.obb": "/r/Android/obb/com.example",
		"Android/media/com.whatsapp/x.jpg": "", // the user's media, on the root's owner
		"Android/data/loose.txt":           "", // no package segment
		"DCIM/Camera/x.jpg":                "",
	} {
		got, ok := appExtOwnerDir("/r", rel)
		if got != want || ok != (want != "") {
			t.Errorf("appExtOwnerDir(%q) = %q, %v; want %q", rel, got, ok, want)
		}
	}
}

// Both mid-session writers, end to end through a sealed head: the installed app's file lands app-owned, the
// absent app's file is left for the next login, and the one summary line names a count and no package.
func TestMaterialize_BothCallersOwnAppExtFilesAndWaitForAbsentApps(t *testing.T) {
	const (
		present = "Android/data/com.example/files/sync/landed.bin"
		absent  = "Android/data/com.absent/files/sync/waits.bin"
	)
	cases := []struct {
		name string
		env  func(t *testing.T)
		run  func(base string, key []byte, m chunkManifest, rels []string, dest string) ([]string, int64)
		body string
	}{
		{"essential", essentialMediaEnv, materializeCarried, "small app state"},
		{"deferred", func(t *testing.T) {
			deferredMediaEnv(t)
			t.Setenv("NOWHERE_MEDIA_MIN", "64") // the app-private floor, so files/ defers too
		}, func(base string, key []byte, m chunkManifest, rels []string, dest string) ([]string, int64) {
			return materializeDeferredArrivals(base, key, m, rels, dest, 1<<30)
		}, strings.Repeat("app-private bulk, over the lowered floor. ", 40)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			c.env(t)
			t.Setenv("NOWHERE_STATE", t.TempDir())
			a, _ := twoWriters(t, "appext"+c.name, "correct horse battery staple")
			a.put(present, c.body)
			a.put(absent, c.body)
			if msg := a.seal("#media"); msg != "" {
				t.Fatalf("setup seal: %s", msg)
			}
			m := headManifestOf(t, a.base, a.name+"#media", a.pass)
			for _, rel := range []string{present, absent} {
				_, ess := m.Ess[rel]
				_, def := m.Deferred[rel]
				if (c.name == "essential" && !ess) || (c.name == "deferred" && !def) {
					t.Fatalf("the fixture did not put %s in the %s tier (ess=%v deferred=%v), so this would test "+
						"the other writer", rel, c.name, ess, def)
				}
			}
			key := resolveDK(a.base, a.name+"#media", a.pass, nil)

			dest := t.TempDir()
			recs := stubExtOwners(t, dest)
			var wrote []string
			out := captureStdout(t, func() { wrote, _ = c.run(a.base, key, m, []string{absent, present}, dest) })

			target := filepath.Join(dest, filepath.FromSlash(present))
			if got, err := os.ReadFile(target); err != nil || string(got) != c.body {
				t.Fatalf("the installed app's file did not land (%v)", err)
			}
			if len(wrote) != 1 || wrote[0] != target {
				t.Errorf("reported landing %v, want only %s", wrote, target)
			}
			pkgDir := filepath.Join(dest, "Android", "data", "com.example")
			requireAppOwned(t, *recs, dest, target, filepath.Join(pkgDir, "files"),
				filepath.Join(pkgDir, "files", "sync"))
			if _, err := os.Lstat(filepath.Join(dest, "Android", "data", "com.absent")); err == nil {
				t.Error("the absent app's file (or its package dir) was written; it must wait for the next login")
			}
			if n := strings.Count(out, "app-specific file(s) wait for the next login"); n != 1 ||
				!strings.Contains(out, "media-sync: 1 app-specific file(s)") {
				t.Errorf("want ONE summary line counting 1 waiting file, got:\n%s", out)
			}
			if strings.Contains(out, "com.absent") || strings.Contains(out, "com.example") {
				t.Errorf("the log names a package -- which apps a profile holds is not this log's to list:\n%s", out)
			}
		})
	}
}
