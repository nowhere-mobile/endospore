package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260829-30. The predicate now recognises the user's scoped-storage media tree
// (Android/media/<pkg>/...) and gives the user's own buckets a lower floor than app-private data.
//
// ⚠ THE REPORTED CASE. NWP-20260828-17's symptom was "I set an app to Auto and nothing happened". The first
// diagnosis blamed the 8 MiB size floor and was WRONG: WhatsApp media lives under Android/media/<pkg>/, which
// matched no entry in the old whitelist AT ANY SIZE, so the path rejected it before the floor was consulted.
// A 50 MB video was exactly as stuck as a 2 MB photo. These cases pin both halves.
func TestWidenedPredicateCoversScopedStorageUserMedia(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "8388608")      // app floor, default
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "1048576") // user floor, default
	waMedia := "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/IMG.jpg"

	// The reported case: a 2 MiB photo. Under the old predicate this was false at ANY size.
	if !classifyDeferred(waMedia, 2<<20) {
		t.Error("a 2 MiB photo in the user's scoped-storage media must be deferrable -- this is the reported case")
	}
	// And the case that disproves the size diagnosis: large, and still stuck before this change.
	if !classifyDeferred(waMedia, 50<<20) {
		t.Error("a 50 MiB video in the same tree must be deferrable")
	}

	// ⚠ CONSTRAINT 5, and the concrete proof that widening a tree cannot reach a state-critical file. Note the
	// extension is .crypt15, NOT .db -- so mediaDenyExts does not catch it and the /databases/ DIR deny is the
	// only thing standing between this file and the on-demand path. If the deny lists ever stop running first,
	// this is the case that breaks.
	waDB := "Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt15"
	if classifyDeferred(waDB, 100<<20) {
		t.Error("a file under /databases/ must never be deferrable, however large and whatever tree it sits in")
	}

	// Android/data and Android/obb are app-private and deliberately NOT widened.
	if classifyDeferred("Android/data/com.foo/blob.bin", 4<<20) {
		t.Error("Android/data is app-private -- widening must not have reached it")
	}
	// ...but its genuinely bulk subtree is still covered by the APP floor, as it always was.
	if !classifyDeferred("Android/data/com.foo/files/region.mwm", 9<<20) {
		t.Error("Android/data/<pkg>/files/ stays covered by mediaAppDirs at the app floor")
	}
	if classifyDeferred("Android/data/com.foo/files/region.mwm", 4<<20) {
		t.Error("...and at the APP floor, not the user floor -- 4 MiB must stay essential there")
	}

	// The prefix is anchored at the scope root: a nested lookalike must not match.
	if classifyDeferred("deep/nest/Android/media/com.foo/x.jpg", 4<<20) {
		t.Error("Android/media must be matched as a ROOT prefix, not merely contained")
	}
}

// The floors must be genuinely separate, and the app floor must win where the two could overlap.
func TestMediaFloorsAreSeparateAndAppFloorWins(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "8388608")
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "1048576")

	// A 2 MiB camera photo: over the user floor, under the app floor. Deferrable.
	if !classifyDeferred("DCIM/Camera/IMG.jpg", 2<<20) {
		t.Error("a 2 MiB camera photo must clear the USER floor -- most of a camera roll lives in this band")
	}
	// The same size in app-private storage: under the app floor. Not deferrable.
	if classifyDeferred("com.foo/files/state.bin", 2<<20) {
		t.Error("2 MiB of app-private data must NOT be deferrable -- the app floor is deliberately conservative")
	}

	// ⚠ ORDER: an app-private tree containing a folder NAMED like a user bucket keeps the app floor. If
	// mediaFloorFor ever tests the user lists first, this silently drops the floor on app-private data.
	if classifyDeferred("com.foo/files/Pictures/thumb.bin", 2<<20) {
		t.Error("an app-private /files/ tree must keep the APP floor even when it contains a Pictures/ folder")
	}
}

// ⚠ A floor below the walk gate can move no bytes, because classifyDeferred is only ever reached from inside
// `size >= sealFileThreshold()`. Exactly that silence cost NWP-20260828-17 a wrong root cause. The default
// must therefore never be inert.
func TestUserFloorDefaultIsNotInert(t *testing.T) {
	os.Unsetenv("NOWHERE_MEDIA_MIN_USER")
	os.Unsetenv("NOWHERE_SEAL_FILE_THRESHOLD")
	os.Unsetenv("NOWHERE_MEDIA_MIN")
	got, gate := mediaUserMinBytes(), sealFileThreshold()
	if got < gate {
		t.Errorf("the default user floor %d is below the walk gate %d, so it can move no bytes at all", got, gate)
	}
	// ⚠ PIN THE DEFAULT VALUE, not just the bound. A mutation that collapsed mediaUserMinBytes back onto
	// mediaMinBytes passed every other test in this file, because they all set NOWHERE_MEDIA_MIN_USER
	// explicitly and never reach the default. The 1 MiB default IS the product decision -- it is the
	// importer's own boundary, and it is what puts a 2-6 MB photo in reach at all.
	if got != gate {
		t.Errorf("the default user floor is %d, want sealFileThreshold() = %d -- the two must track", got, gate)
	}
	if app := mediaMinBytes(); got >= app {
		t.Errorf("the user floor %d must be strictly BELOW the app floor %d, else the split buys nothing", got, app)
	}
}

// The end-to-end assertion, and the one that would have caught the refuted design: a user-media file that
// mediad materializes must be RE-DEFERRED by the next seal, never folded into the login-blocking tar.
//
// Step 3 is the ratchet assertion. Before NWP-20260829-29 + -30, writing the real bytes back is exactly what
// materialize does, and the following seal promoted the file to essential permanently.
func TestPrefetchedUserMediaIsReDeferredNotPromoted(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "4096")
	// ⚠ Deliberately huge, so this test proves the USER floor is doing the work and not the app floor.
	t.Setenv("NOWHERE_MEDIA_MIN", "67108864")

	base := newHTTPStore(t)
	name, pass := "widen", "widening horse battery staple"
	createVault(base, name, pass)

	rel := "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/IMG.jpg"
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(src, filepath.FromSlash(rel))), 0o755); err != nil {
		t.Fatal(err)
	}
	blob := bytes.Repeat([]byte("PHOTO-0123456789-"), 500) // ~8 KiB: over the user floor, far under the app floor
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

	// (1) THE WALK PATH: the widened predicate must defer it at the configured tier.
	pushProfile(base, name, pass, src)
	d, ok := redeferManifest(t, base, name, pass).Deferred[rel]
	if !ok {
		t.Fatalf("walk did not defer %q -- the widened predicate is not reaching the user-media tree", rel)
	}
	if d.Tier != int(tierPrefetch) {
		t.Fatalf("deferred at Tier=%d, want %d (the profile configured com.whatsapp prefetch)", d.Tier, int(tierPrefetch))
	}

	// (2) THE CARRY PATH: with the file absent from disk, the record must survive at the same tier.
	srcB := t.TempDir()
	if err := os.MkdirAll(filepath.Join(srcB, "com.nowhere.chooser/files"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(srcB, "com.nowhere.chooser/files/nowhere-media-tiers"), []byte("com.whatsapp prefetch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, srcB)
	if d, ok := redeferManifest(t, base, name, pass).Deferred[rel]; !ok || d.Tier != int(tierPrefetch) {
		t.Fatalf("carry lost the record or its tier: ok=%v tier=%d", ok, d.Tier)
	}

	// (3) THE RATCHET: write the real bytes back -- precisely what materialize does -- and re-seal. The file
	// must STILL be deferred, not promoted into the login tar.
	if err := os.MkdirAll(filepath.Dir(filepath.Join(srcB, filepath.FromSlash(rel))), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(srcB, filepath.FromSlash(rel)), blob, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, srcB)
	if d, ok := redeferManifest(t, base, name, pass).Deferred[rel]; !ok {
		t.Fatal("THE RATCHET: a materialized user-media file was promoted into the login tar and can never return")
	} else if d.Tier != int(tierPrefetch) {
		t.Errorf("re-deferred but at Tier=%d, want %d", d.Tier, int(tierPrefetch))
	}
}

// NWP-20260829-31. The gap -30 left: an imported record carries Tier 0, and the only live-config route was
// redeferTier, whose floor is the 8 MiB APP floor -- so a 2 MiB photo in a prefetch-configured app was not
// selected, and the user's Auto switch still did nothing until a logoff seal plus a further login.
func TestWantPrefetchSelectsUserMediaFromLiveConfig(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "8388608")      // app floor, default
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "1048576") // user floor, default
	rel := "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/IMG.jpg"
	d := deferredFile{Size: 2 << 20} // 2 MiB, Tier 0 -- exactly an imported record
	srv := &mediaServer{deferred: map[string]deferredFile{rel: d}}

	if !srv.wantPrefetch(rel, d, map[string]mediaTier{"com.whatsapp": tierPrefetch}, nil) {
		t.Error("a 2 MiB user-media file in a prefetch-configured app must be selected from the LIVE config, " +
			"without waiting for a seal to stamp Tier=2")
	}
	// The safety properties must survive the new clause.
	if srv.wantPrefetch(rel, d, nil, nil) {
		t.Error("with no tier config it must not be prefetched")
	}
	if srv.wantPrefetch(rel, d, map[string]mediaTier{"com.whatsapp": tierPrefetch}, map[string]bool{"com.whatsapp": true}) {
		t.Error("a pinned app must not also be selected by Tier-2 prefetch")
	}
	db := "Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt15"
	dd := deferredFile{Size: 100 << 20}
	srv2 := &mediaServer{deferred: map[string]deferredFile{db: dd}}
	if srv2.wantPrefetch(db, dd, map[string]mediaTier{"com.whatsapp": tierPrefetch}, nil) {
		t.Error("a deny-listed file must never be selected, however the tier is configured")
	}
}
