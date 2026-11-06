package main

import (
	"os"
	"path/filepath"
	"testing"
)

// mkfile writes n bytes at path, creating parents.
func mkfile(t *testing.T, path string, n int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, n), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDirBytesSumsRegularFilesOnly(t *testing.T) {
	d := t.TempDir()
	mkfile(t, filepath.Join(d, "a.bin"), 1000)
	mkfile(t, filepath.Join(d, "sub", "b.bin"), 2000)
	if err := os.MkdirAll(filepath.Join(d, "emptydir"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A symlink must contribute nothing: it is not IsRegular, and following it would let a link into
	// /data/media double-count the media tree against an app.
	if err := os.Symlink(filepath.Join(d, "a.bin"), filepath.Join(d, "link.bin")); err != nil {
		t.Fatal(err)
	}
	st := newWalkState(d)
	if got, want := dirBytes(d, st), int64(3000); got != want {
		t.Errorf("dirBytes = %d, want %d", got, want)
	}
	if st.blind != 0 {
		t.Errorf("a fully readable tree must not be blind, got %d", st.blind)
	}
}

// A missing tree reads as 0 and is NOT blind: absent is a normal state (a volume an app has no data on),
// while unreadable means real bytes we cannot see. Conflating them would make the "incomplete" warning fire
// constantly and stop meaning anything.
func TestDirBytesMissingTreeIsNotBlind(t *testing.T) {
	d := t.TempDir()
	st := newWalkState(d)
	if got := dirBytes(filepath.Join(d, "does-not-exist"), st); got != 0 {
		t.Errorf("missing dir: got %d, want 0", got)
	}
	if st.blind != 0 {
		t.Errorf("missing dir must not count as blind, got %d", st.blind)
	}
}

// An unreadable subtree must be COUNTED, not silently swallowed. This is the whole reason Blind exists:
// nowhere.te records a permission gap of exactly this shape that made the seal's walk short for a day
// without a single error. A screen that under-reports invites the user to delete the wrong thing.
func TestDirBytesCountsUnreadableSubtreeAsBlind(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	d := t.TempDir()
	mkfile(t, filepath.Join(d, "visible.bin"), 500)
	secret := filepath.Join(d, "secret")
	mkfile(t, filepath.Join(secret, "hidden.bin"), 9999)
	if err := os.Chmod(secret, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(secret, 0o755) }) // so t.TempDir cleanup can remove it

	st := newWalkState(d)
	got := dirBytes(d, st)
	if got != 500 {
		t.Errorf("readable bytes = %d, want 500", got)
	}
	if st.blind == 0 {
		t.Error("an unreadable subtree must increment blind, else the screen under-reports in silence")
	}
}

// Hard links must be counted once. Two names for the same inode are one lot of bytes on disk, so counting
// both would tell the user that deleting the app frees more than it does.
func TestDirBytesCountsHardLinkOnce(t *testing.T) {
	d := t.TempDir()
	a := filepath.Join(d, "a.bin")
	mkfile(t, a, 4096)
	if err := os.Link(a, filepath.Join(d, "b.bin")); err != nil {
		t.Skipf("hard links unsupported here: %v", err)
	}
	st := newWalkState(d)
	if got, want := dirBytes(d, st), int64(4096); got != want {
		t.Errorf("hard-linked file counted twice: got %d, want %d", got, want)
	}
}

func TestParseKeepModes(t *testing.T) {
	// Exercises the REAL parser. readKeepModes is a thin os.ReadFile wrapper around it; the absolute
	// /data path is not reachable from a test, which is exactly why the parsing was split out.
	got := parseKeepModes([]byte(
		"com.example.installed\ncom.example.od\tondemand\n\ncom.example.group\tondemand\tgroup:sandboxed-play\n"))
	if got["com.example.installed"] != "installed" {
		t.Errorf("bare line should mean installed, got %q", got["com.example.installed"])
	}
	if got["com.example.od"] != "ondemand" {
		t.Errorf("tab-ondemand should mean ondemand, got %q", got["com.example.od"])
	}
	// A 3-token group row must read as ondemand: the mode is field 1 specifically, so a reader that split
	// once and kept "the rest" would produce "ondemand\tgroup:sandboxed-play" and match no mode at all.
	if got["com.example.group"] != "ondemand" {
		t.Errorf("group row should mean ondemand, got %q", got["com.example.group"])
	}
}

func TestCollectStorageBreakdownEmptyUid(t *testing.T) {
	// No session -> no uid -> an empty, non-nil Apps slice so the JSON is "[]" and the screen renders an
	// empty list rather than a null the UI has to special-case.
	b := collectStorageBreakdown("", nil)
	if b.Apps == nil {
		t.Error("Apps must be non-nil so it marshals as [] not null")
	}
	if b.TotalBytes != 0 {
		t.Errorf("TotalBytes = %d, want 0", b.TotalBytes)
	}
}

// addPkgDirs is where held data gets attributed back to the app that owns it, so it is worth pinning
// directly: package-named subdirs become rows, dotfiles do not, and the chooser is dropped only where it
// is a real package dir (the CE/DE roots) -- never in the hold, whose entries are all other apps.
func TestAddPkgDirsAttribution(t *testing.T) {
	base := t.TempDir()
	mkfile(t, filepath.Join(base, "com.example.a", "f"), 100)
	mkfile(t, filepath.Join(base, chooserPkg, "f"), 700)
	mkfile(t, filepath.Join(base, ".hidden", "f"), 900)

	perPkg := map[string]int64{}
	addPkgDirs(perPkg, base, newWalkState(base), true)
	if perPkg["com.example.a"] != 100 {
		t.Errorf("app row = %d, want 100", perPkg["com.example.a"])
	}
	if _, ok := perPkg[chooserPkg]; ok {
		t.Error("the chooser's own dir must not be offered as a saving at a volume root")
	}
	if _, ok := perPkg[".hidden"]; ok {
		t.Error("dot-dirs are not packages")
	}

	// Same base treated as a hold: the chooser is not skipped there, because in the hold a directory named
	// after a package IS that package's parked data.
	perHold := map[string]int64{}
	addPkgDirs(perHold, base, newWalkState(base), false)
	if perHold[chooserPkg] != 700 {
		t.Errorf("hold entry = %d, want 700 (held data must be attributed, not skipped)", perHold[chooserPkg])
	}
}
