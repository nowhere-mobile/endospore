package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// #84 P3: the media server fetches a deferred file's chunks from the store on access, reassembles the whole
// file into a content-addressed CE cache byte-for-byte, and is idempotent (a second open is a pure cache hit).
// P2 proved the seal SPLITS media out of the login set; this proves mediad can SERVE it back on demand -- the
// on-access half of "login never blocks on GBs of media."
func TestMediaServerFetchesDeferredFile(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")           // 4 KiB floor so the test blobs qualify as deferred
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096") // and count as "large" (file-aligned) files

	base := newHTTPStore(t)
	name, pass := "mediad", "on demand horse battery staple"
	createVault(base, name, pass)

	// A profile with one essential file + three deferred "maps": two in one dir, one in another (exercises
	// dir grouping), and the third at a non-default mode (0600) so we prove mode is carried through.
	src := t.TempDir()
	for _, d := range []string{"app.maps/files/maps", "app.maps/files/data", "app.maps/shared_prefs"} {
		if err := os.MkdirAll(filepath.Join(src, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(src, "app.maps/shared_prefs/s.xml"), []byte("essential"), 0o644); err != nil {
		t.Fatal(err)
	}
	regionA := bytes.Repeat([]byte("REGION-A-0123456789-"), 6000) // ~117 KiB
	regionB := bytes.Repeat([]byte("REGION-B-abcdefghij-"), 7000)
	model := bytes.Repeat([]byte("MODELDATA-"), 9000)
	relA, relB, relM := "app.maps/files/maps/a.mwm", "app.maps/files/maps/b.mwm", "app.maps/files/data/model.bin"
	if err := os.WriteFile(filepath.Join(src, relA), regionA, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, relB), regionB, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, relM), model, 0o600); err != nil {
		t.Fatal(err)
	}

	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	m := loadCDCManifest(base, dk, v.Manifest)
	if len(m.Deferred) != 3 {
		t.Fatalf("expected 3 deferred files, got %d: %v", len(m.Deferred), keysOf(m.Deferred))
	}

	cache := t.TempDir()
	s := newMediaServer(base, dk, m, cache)

	// (1) attr reflects the manifest and does NOT fetch (cache stays empty).
	if d, ok := s.attr(relM); !ok || d.Size != int64(len(model)) || d.Mode&0o777 != 0o600 {
		t.Fatalf("attr(relM) wrong: %+v ok=%v (want size=%d mode=0600)", d, ok, len(model))
	}
	if entries, _ := os.ReadDir(cache); len(entries) != 0 {
		t.Fatalf("attr must not fetch: cache should be empty, has %d entries", len(entries))
	}

	// (2) fetch reconstructs each deferred file byte-for-byte.
	for rel, want := range map[string][]byte{relA: regionA, relB: regionB, relM: model} {
		cp, err := s.fetchFile(rel)
		if err != nil {
			t.Fatalf("fetchFile(%q): %v", rel, err)
		}
		got, err := os.ReadFile(cp)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%q reconstruction mismatch: got %d bytes, want %d", rel, len(got), len(want))
		}
	}

	// (3) idempotent: a second fetch is a stable cache hit (same path, no error, no new cache file).
	cpFirst, _ := s.fetchFile(relA)
	before, _ := os.ReadDir(cache)
	cpAgain, err := s.fetchFile(relA)
	if err != nil || cpAgain != cpFirst {
		t.Fatalf("second fetch not a stable cache hit: %q vs %q err=%v", cpAgain, cpFirst, err)
	}
	if after, _ := os.ReadDir(cache); len(after) != len(before) {
		t.Fatalf("second fetch changed the cache file count: %d -> %d", len(before), len(after))
	}

	// (4) an essential (non-deferred) path is never served by mediad.
	if _, err := s.fetchFile("app.maps/shared_prefs/s.xml"); err == nil {
		t.Fatal("fetchFile of an essential file must error, not serve")
	}

	// (5) dir grouping: two maps under files/maps, one under files/data.
	dirs := s.deferredDirs()
	if got := dirs["app.maps/files/maps"]; len(got) != 2 || got[0] != "a.mwm" || got[1] != "b.mwm" {
		t.Fatalf("files/maps grouping wrong: %v", got)
	}
	if got := dirs["app.maps/files/data"]; len(got) != 1 || got[0] != "model.bin" {
		t.Fatalf("files/data grouping wrong: %v", got)
	}
}
