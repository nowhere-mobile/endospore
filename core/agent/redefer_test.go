package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260829-29. Materialization used to be a ONE-WAY DOOR into the login tar.
//
// mediad's #108 pin and #129 prefetch write a deferred file's real bytes into the passthrough dir and
// tombstone the stub. By the next seal it is an ordinary local file, so the walk asks classifyDeferred -- and
// for any path mediaDirs does not list (every scoped-storage app's media, Android/media/<pkg>/...) the answer
// is NO at any size. The file then fell through as tierEssential and rode the login-blocking tar forever, with
// nothing in the tree able to send it back.
//
// That ratchet is why the obvious fix to NWP-20260828-17 -- stamp the configured tier on the carry path -- was
// refused by three independent reviews: it routes the whole imported corpus into the tar one seal later, which
// is the trap that row already forbids.
//
// The scenario here is the real one, built with the #204 defer list: seal 1 defers a WhatsApp media path the
// agent's own predicate would never defer (exactly what the web importer produces), the file stays on disk as
// if mediad had materialized it, and seal 2 runs with no defer list. Before the fix seal 2 folds it into the
// essential set; after, it returns to Deferred at the configured tier.
func TestSealRedefersMaterializedImporterBandMedia(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	// The floor is lowered only to keep the fixture small. It is NOT the discriminator under test -- the rel
	// below fails classifyDeferred on its PATH, at any size, which is the whole point of the case.
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "redefer", "returning horse battery staple"
	createVault(base, name, pass)

	// ⚠ Android/DATA, not Android/media, and the distinction is the whole test. NWP-20260829-30 widened the
	// predicate to cover Android/media/<pkg>/ -- the user's scoped-storage media -- so a rel under THERE now
	// passes classifyDeferred and would reach the tier via the ordinary path, leaving this test green while
	// proving nothing about the door. Android/data is app-private and deliberately NOT widened, so it remains
	// what the door exists for: a record the importer deferred that the agent's predicate rejects.
	rel := "Android/data/com.whatsapp/files-external/blob.bin"
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(src, filepath.FromSlash(rel))), 0o755); err != nil {
		t.Fatal(err)
	}
	blob := bytes.Repeat([]byte("JPEGDATA-0123456789-"), 5000) // ~98 KiB, over the test floor
	if err := os.WriteFile(filepath.Join(src, filepath.FromSlash(rel)), blob, 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(src, "com.nowhere.chooser/files")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg, "nowhere-media-tiers"), []byte("com.whatsapp prefetch\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// SEAL 1 -- force the file deferred, standing in for the importer's record.
	list := filepath.Join(t.TempDir(), "defer.list")
	if err := os.WriteFile(list, []byte(rel+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", list)
	pushProfile(base, name, pass, src)

	if _, ok := redeferManifest(t, base, name, pass).Deferred[rel]; !ok {
		t.Fatalf("fixture is wrong: seal 1 did not defer %q, so there is no ratchet to test", rel)
	}

	// SEAL 2 -- no defer list. The file is still on disk, i.e. materialized.
	t.Setenv("NOWHERE_DEFER_LIST", "")
	pushProfile(base, name, pass, src)

	m := redeferManifest(t, base, name, pass)
	d, ok := m.Deferred[rel]
	if !ok {
		t.Fatalf("THE RATCHET: %q left Deferred and is now essential -- it will be restored inline at every "+
			"login from here on, and nothing can send it back", rel)
	}
	if d.Tier != int(tierPrefetch) {
		t.Errorf("returned to Deferred but at Tier=%d, want %d (the profile configured com.whatsapp prefetch)", d.Tier, int(tierPrefetch))
	}
}

func redeferManifest(t *testing.T, base, name, pass string) chunkManifest {
	t.Helper()
	dk := resolveDK(base, name, pass, nil)
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	return loadCDCManifest(base, dk, v.Manifest)
}

// The five refusals redeferTier owes. Each is a safety property, not a preference: getting any of them wrong
// silently changes what a login restores.
func TestRedeferTierRefusals(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	const big = int64(1 << 20)
	rel := "Android/data/com.whatsapp/files-external/blob.bin"
	prev := map[string]deferredFile{rel: {Size: big}}
	tiers := map[string]mediaTier{"com.whatsapp": tierPrefetch}

	if _, ok := redeferTier(rel, big, prev, tiers, nil); !ok {
		t.Fatal("baseline: an already-deferred, non-deny-listed, over-floor, unpinned, prefetch-configured file must be allowed back")
	}

	// (1) never deferred before -> allowing it would be a NEW demotion: a file that has always been restored
	// at login would silently stop being restored. That is the blast radius this design exists to avoid.
	if _, ok := redeferTier(rel, big, map[string]deferredFile{}, tiers, nil); ok {
		t.Error("a file absent from prevDef must NOT be re-deferred -- that is a demotion, not a return")
	}

	// (2) deny-listed. "Already deferred" is not evidence a file is bulk media: the importer applies no deny
	// list at all, so a .db can sit in its band. It must fold essential and stay there.
	db := "Android/data/com.whatsapp/databases/msgstore.db"
	if _, ok := redeferTier(db, big, map[string]deferredFile{db: {Size: big}}, tiers, nil); ok {
		t.Error("a deny-listed file must NOT be re-deferred, whatever the importer did with it")
	}

	// (3) below the floor.
	if _, ok := redeferTier(rel, 100, prev, tiers, nil); ok {
		t.Error("a file under mediaMinBytes must NOT be re-deferred")
	}

	// (4) a #108 pin means the user asked for it at login. Still wins.
	if _, ok := redeferTier(rel, big, prev, tiers, map[string]bool{"com.whatsapp": true}); ok {
		t.Error("a PINNED app's file must NOT be re-deferred -- the pin is a request for the login restore")
	}

	// (5) an essential-tier config is the user asking for the tar.
	if _, ok := redeferTier(rel, big, prev, map[string]mediaTier{"com.whatsapp": tierEssential}, nil); ok {
		t.Error("an essential-tier config must NOT be overridden by the return door")
	}
}

// wantPrefetch is what makes the user's setting mean something on an imported profile: the stored Tier is
// stuck at 0 (the seal can never re-tier that path), so selecting on Tier alone can never pick the file up.
func TestWantPrefetchPicksUpImporterBandFile(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	rel := "Android/data/com.whatsapp/files-external/blob.bin"
	d := deferredFile{Size: 1 << 20} // Tier 0 -- exactly what an imported record carries
	srv := &mediaServer{deferred: map[string]deferredFile{rel: d}}
	tiers := map[string]mediaTier{"com.whatsapp": tierPrefetch}

	if !srv.wantPrefetch(rel, d, tiers, nil) {
		t.Error("a Tier-0 imported record whose app is configured prefetch must be selected -- selecting on the stored Tier alone never picks it up")
	}
	// No config -> curatedTier decides, and com.whatsapp is not curated, so it stays on-demand.
	if srv.wantPrefetch(rel, d, nil, nil) {
		t.Error("with no tier config this file must NOT be prefetched")
	}
	// A pin routes through materializePins instead; wantPrefetch must not double-fetch it.
	if srv.wantPrefetch(rel, d, tiers, map[string]bool{"com.whatsapp": true}) {
		t.Error("a pinned app must not also be selected by Tier-2 prefetch")
	}
	// The stored Tier still wins on its own, unchanged from before.
	if !srv.wantPrefetch("app.maps/files/region.mwm", deferredFile{Size: 1 << 20, Tier: int(tierPrefetch)}, nil, nil) {
		t.Error("a stored Tier=2 record must still be selected")
	}
}

// classifyDeferred's contract, across the extraction (NWP-20260829-29) and the widening (NWP-20260829-30).
func TestClassifyDeferredContract(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "4096")
	const big = int64(1 << 20)
	cases := []struct {
		rel  string
		size int64
		want bool
	}{
		{"DCIM/Camera/a.mp4", big, true},
		{"Pictures/Viber/p.jpg", big, true},
		{"app.maps/files/region.mwm", big, true},
		{"DCIM/Camera/a.mp4", 100, false},                                              // under the floor
		{"Android/data/com.whatsapp/files-external/blob.bin", big, false},              // app-private, deliberately NOT widened
		{"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/x.jpg", big, true}, // -30: the user's scoped-storage media
		{"deep/nest/Android/media/com.foo/x.jpg", big, false},                          // -30 anchors at the SCOPE ROOT, not anywhere
		{"DCIM/Camera/thumbs.db", big, false},                                          // deny ext
	}
	for _, c := range cases {
		if got := classifyDeferred(c.rel, c.size); got != c.want {
			t.Errorf("classifyDeferred(%q, %d) = %v, want %v", c.rel, c.size, got, c.want)
		}
	}
}
