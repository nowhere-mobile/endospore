package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261129-46. appendTombstone writes each tombstone as rel+"\n" exactly, so a reader must keep each line as
// written. Both readers trimmed it, and a rel that begins or ends in whitespace read back as another rel: the
// deleted file stayed in the head, and a file named by the trimmed key lost its record. Same defect class as
// NWP-20261016-43 (MediaScanReceiver.readList trimmed synced file names).

var (
	verbatimRels    = []string{"Movies/clip ", " DCIM/lead.jpg", "Music/nbsp\u00a0"}
	verbatimTrimmed = []string{"Movies/clip", "DCIM/lead.jpg", "Music/nbsp"}
)

// requireVerbatimKeys asserts the set holds the three edge rels exactly and none of their trimmed names.
func requireVerbatimKeys(t *testing.T, label string, got map[string]bool) {
	t.Helper()
	for _, rel := range verbatimRels {
		if !got[rel] {
			t.Errorf("%s: tombstone %q was not read back as written: got %q", label, rel, tombKeys(got))
		}
	}
	for _, rel := range verbatimTrimmed {
		if got[rel] {
			t.Errorf("%s: a tombstone was read back as %q, another file's name: got %q", label, rel, tombKeys(got))
		}
	}
}

// Both places the seal reads: the CE file inside the tree, and the file roamd names for #media, outside it.
func TestMediaTombstonesReadLinesVerbatim(t *testing.T) {
	src := t.TempDir()
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	writeDeleted(t, filepath.Join(src, filepath.FromSlash(mediaCacheRel)), verbatimRels...)
	requireVerbatimKeys(t, "the CE geometry", mediaTombstones(src))

	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", writeDeleted(t, t.TempDir(), verbatimRels...))
	requireVerbatimKeys(t, "NOWHERE_MEDIA_TOMBSTONES", mediaTombstones(t.TempDir()))
}

// mediad's own reader, which a restart in the session (a cold-lock resume) depends on, and the round trip through
// the writer.
func TestLoadTombstonesReadLinesVerbatim(t *testing.T) {
	dir := t.TempDir()
	writeDeleted(t, dir, verbatimRels...)
	requireVerbatimKeys(t, "loadTombstones", loadTombstones(dir))

	rt := t.TempDir()
	srv := &mediaServer{cacheDir: rt}
	if err := srv.markDeleted("Movies/clip "); err != nil {
		t.Fatal(err)
	}
	got := loadTombstones(rt)
	if !got["Movies/clip "] {
		t.Errorf("markDeleted(%q) did not survive a reload: got %q", "Movies/clip ", tombKeys(got))
	}
	if got["Movies/clip"] {
		t.Errorf("markDeleted(%q) reloaded as %q, another file's name: got %q", "Movies/clip ", "Movies/clip", tombKeys(got))
	}
}

// THE TWO FAILURES, END TO END. An unfetched stub is not in the walk, so only the tombstone decides its record: the
// trimmed key carried the deleted file and dropped the file that holds the trimmed name.
func TestSealDropsATombstonedDeferredFileWhoseNameEndsInASpace(t *testing.T) {
	deferredMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	const spaced, namesake = "Movies/clip ", "Movies/clip"

	a, _ := twoWriters(t, "tombverbatim", "correct horse battery staple")
	a.put("Documents/keep.txt", "keep")
	a.put(spaced, strings.Repeat("the name ends in a space ", 20))
	a.put(namesake, strings.Repeat("the trimmed name of the other ", 20))
	if why := a.seal("#media"); why != "" {
		t.Fatalf("the first seal did not land: %s", why)
	}
	requireDeferred(t, a, spaced)
	requireDeferred(t, a, namesake)

	// The control: both are absent from the walk and neither is tombstoned, so absence alone must not delete.
	a.rm(spaced)
	a.rm(namesake)
	if why := a.seal("#media"); why != "" {
		t.Fatalf("the control seal did not land: %s", why)
	}
	requireDeferred(t, a, spaced)
	requireDeferred(t, a, namesake)

	deleted := filepath.Join(t.TempDir(), ".deleted")
	if err := os.WriteFile(deleted, []byte(spaced+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", deleted)
	if why := a.seal("#media"); why != "" {
		t.Fatalf("the seal with a tombstone did not land: %s", why)
	}
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Deferred[spaced]; ok {
		t.Errorf("a deletion undone: %q is tombstoned and the head still carries its record", spaced)
	}
	if _, ok := m.Deferred[namesake]; !ok {
		t.Errorf("a file lost: the tombstone of %q dropped the record of %q", spaced, namesake)
	}
}
