package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261127-06. The seal and a re-exec'd mediad read tombstones ONLY from <cacheDir>/.deleted, so an append
// that did not land must not pass for a deletion: markDeleted reports it, keeps the cache, and keeps the RAM
// tombstone for the write-back callers; Unlink takes the tombstone back and fails.

// A .deleted that cannot be opened (a DIRECTORY: EISDIR, for root too) -> an error with no path in its text, the
// cache NOT evicted, the RAM tombstone set (the write-back contract), and a repeat call a no-op.
func TestMarkDeletedReportsAFailedAppend(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, ".deleted"), 0o700); err != nil {
		t.Fatal(err)
	}
	df := deferredFile{Chunks: []string{"tw1", "tw2"}, Size: 10}
	srv := &mediaServer{cacheDir: dir, deferred: map[string]deferredFile{"tw/a.mwm": df}}
	key := cacheKey(df)
	for _, suf := range []string{"", ".part", ".have"} {
		if err := os.WriteFile(filepath.Join(dir, key+suf), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	err := srv.markDeleted("tw/a.mwm")
	if err == nil {
		t.Fatal("markDeleted must report a tombstone append that did not land")
	}
	if strings.Contains(err.Error(), dir) {
		t.Fatalf("the error must not carry the cache path: %q", err)
	}
	for _, suf := range []string{"", ".part", ".have"} {
		if _, serr := os.Stat(filepath.Join(dir, key+suf)); serr != nil {
			t.Fatalf("cache file %q evicted although the tombstone was not persisted: %v", key+suf, serr)
		}
	}
	if !srv.isDeleted("tw/a.mwm") {
		t.Fatal("the RAM tombstone must stay set after a failed append (the write-back callers rely on it)")
	}
	if err := srv.markDeleted("tw/a.mwm"); err != nil {
		t.Fatalf("a rel already tombstoned in RAM must return nil: %v", err)
	}
	srv.unmarkDeleted("tw/a.mwm")
	if srv.isDeleted("tw/a.mwm") {
		t.Fatal("unmarkDeleted must take the RAM tombstone back")
	}
}

// A last line cut short (no '\n') must not swallow the next tombstone: both rels reload, and the bytes are exactly
// two lines (no blank line from a needless repair on the second append).
func TestMarkDeletedRepairsATornLastLine(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".deleted")
	if err := os.WriteFile(p, []byte("tw/x.mwm"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := &mediaServer{cacheDir: dir}
	if err := srv.markDeleted("tw/y.mwm"); err != nil {
		t.Fatal(err)
	}
	got := loadTombstones(dir)
	if len(got) != 2 || !got["tw/x.mwm"] || !got["tw/y.mwm"] {
		t.Fatalf("a torn last line lost a tombstone: got %v", tombKeys(got))
	}
	if err := srv.markDeleted("tw/z.mwm"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "tw/x.mwm\ntw/y.mwm\ntw/z.mwm\n" {
		t.Fatalf(".deleted bytes = %q", b)
	}
}

// The FUSE side: an unlink of a live stub whose tombstone cannot be written FAILS, and the stub stays listed,
// served at its manifest size, and carried by the next seal.
func TestOverlayUnlinkKeepsTheStubWhenItsTombstoneFails(t *testing.T) {
	preGateSeal(t) // a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-tombwrite")
	tomb := filepath.Join(srcB, mediaCacheDirName, ".deleted")
	if err := os.Mkdir(tomb, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", tomb)
	prev := mediaUndersFn
	mediaUndersFn = func(s string) (map[string]string, error) {
		if s == srcB {
			return map[string]string{overlayDir: under}, nil
		}
		return nil, nil
	}
	t.Cleanup(func() { mediaUndersFn = prev })

	if err := os.Remove(filepath.Join(overlayDir, "one.mwm")); err == nil {
		t.Fatal("an unlink whose tombstone was not persisted must fail, not report success")
	}
	st, err := os.Stat(filepath.Join(overlayDir, "one.mwm"))
	if err != nil {
		t.Fatalf("the stub must stay served after a failed unlink: %v", err)
	}
	if want := m1.Deferred["app.maps/files/maps/one.mwm"].Size; st.Size() != want {
		t.Fatalf("stub size = %d, want the manifest's %d", st.Size(), want)
	}
	listed := false
	des, _ := os.ReadDir(overlayDir)
	for _, de := range des {
		if de.Name() == "one.mwm" {
			listed = true
		}
	}
	if !listed {
		t.Fatal("the stub must stay listed after a failed unlink")
	}

	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	for _, rel := range []string{"app.maps/files/maps/one.mwm", "app.maps/files/maps/two.mwm"} {
		if _, ok := m2.Deferred[rel]; !ok {
			t.Fatalf("%q must carry forward in Deferred; got %v", rel, keysOf(m2.Deferred))
		}
	}
}

func tombKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
