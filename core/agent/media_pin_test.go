package main

import (
	"os"
	"path/filepath"
	"testing"
)

// #108 per-app pin (P1, seal side). A PINNED app's bulk media is restored at LOGIN (essential), not
// deferred/streamed. Seed two apps, each with a >threshold media file, plus a pin file listing one of them: the
// pinned app's file must be ABSENT from Deferred (it seals into the login-critical set and restores to disk),
// while the unpinned app's file is deferred as usual (served on-access, not on disk at login).
func TestPinnedAppMediaRestoredAtLogin(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	base := newHTTPStore(t)
	name, pass := "pinny", "pin horse battery staple"
	createVault(base, name, pass)

	srcA := t.TempDir()
	mk := func(rel string, b []byte) {
		p := filepath.Join(srcA, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("app.pinned/files/big.dat", prBytes(6<<20))
	mk("app.unpinned/files/big.dat", append(prBytes(6<<20), 0xAB))
	mk(pinFileRel, []byte("app.pinned\n")) // the user pinned app.pinned to stay offline

	pushProfile(base, name, pass, srcA)
	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)

	if _, ok := m.Deferred["app.pinned/files/big.dat"]; ok {
		t.Fatalf("PINNED app media must NOT be deferred (restore at login); deferred=%v", keysOf(m.Deferred))
	}
	if _, ok := m.Deferred["app.unpinned/files/big.dat"]; !ok {
		t.Fatalf("UNPINNED app media must stay deferred; deferred=%v", keysOf(m.Deferred))
	}

	// "Login": the pinned file must land on disk (essential); the unpinned (deferred) must NOT (mediad serves it).
	_, srcB := restoreManifest(t, base, name, pass)
	if _, err := os.Stat(filepath.Join(srcB, "app.pinned/files/big.dat")); err != nil {
		t.Fatalf("pinned app media must be restored to disk at login: %v", err)
	}
	if _, err := os.Stat(filepath.Join(srcB, "app.unpinned/files/big.dat")); !os.IsNotExist(err) {
		t.Fatalf("unpinned deferred media must NOT be on disk at login (served on-access); err=%v", err)
	}
}

// #108 immediate materialize: pinning fetches an app's DEFERRED media into the real dir (.under) + tombstones
// the stubs, so the next seal (P1 pin) keeps them essential -> local now + restored at login. Reuses the real
// overlay harness; drives materializePins directly, then seals with the pin file present.
func TestMaterializePinnedMakesLocalAndEssential(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-pin")
	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))

	// Materialize the pinned app's deferred media into the .under real dir.
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)

	for _, n := range []string{"one.mwm", "two.mwm"} {
		rel := "app.maps/files/maps/" + n
		fi, err := os.Stat(filepath.Join(under, n))
		if err != nil {
			t.Fatalf("materialized %s must be a real file in .under: %v", n, err)
		}
		if fi.Size() != m1.Deferred[rel].Size {
			t.Fatalf("%s materialized size %d != manifest %d", n, fi.Size(), m1.Deferred[rel].Size)
		}
		if !srv.isDeleted(rel) {
			t.Fatalf("%s must be tombstoned after materialize (stub superseded by the real file)", rel)
		}
	}

	// Seal with the pin recorded: the (now on-disk) maps must be ESSENTIAL, not deferred -> restored at login.
	pinP := filepath.Join(srcB, filepath.FromSlash(pinFileRel))
	if err := os.MkdirAll(filepath.Dir(pinP), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(pinP, []byte("app.maps\n"), 0o644)
	prev := mediaUndersFn
	mediaUndersFn = func(s string) (map[string]string, error) {
		if s == srcB {
			return map[string]string{overlayDir: under}, nil
		}
		return nil, nil
	}
	t.Cleanup(func() { mediaUndersFn = prev })
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	for _, n := range []string{"one.mwm", "two.mwm"} {
		if _, ok := m2.Deferred["app.maps/files/maps/"+n]; ok {
			t.Fatalf("pinned+materialized %s must no longer be deferred (essential now); deferred=%v", n, keysOf(m2.Deferred))
		}
	}
	// And it restores to disk at login (essential set).
	_, srcC := restoreManifest(t, base, name, pass)
	if _, err := os.Stat(filepath.Join(srcC, "app.maps/files/maps/one.mwm")); err != nil {
		t.Fatalf("pinned map must restore to disk at login: %v", err)
	}
}

// #129 P3: Tier-2 background prefetch materializes the Tier-2 deferred set into .under + tombstones the stubs
// (same promotion path as a #108 pin), so the next seal keeps them essential. Reuses the overlay harness;
// opts the deferred maps into Tier-2 in the loaded manifest, then drives prefetchTier2 directly.
func TestPrefetchTier2MaterializesLocal(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-prefetch")
	for rel, d := range m1.Deferred { // opt the maps into Tier-2 (prefetch)
		d.Tier = int(tierPrefetch)
		m1.Deferred[rel] = d
	}
	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.prefetchTier2(0, map[string]string{"app.maps/files/maps": under}, nil, nil, nil) // 0 = unlimited budget
	for _, n := range []string{"one.mwm", "two.mwm"} {
		rel := "app.maps/files/maps/" + n
		fi, err := os.Stat(filepath.Join(under, n))
		if err != nil {
			t.Fatalf("prefetched %s must be a real file in .under: %v", n, err)
		}
		if fi.Size() != m1.Deferred[rel].Size {
			t.Fatalf("%s prefetched size %d != manifest %d", n, fi.Size(), m1.Deferred[rel].Size)
		}
		if !srv.isDeleted(rel) {
			t.Fatalf("%s must be tombstoned after prefetch (stub superseded by the real file)", rel)
		}
	}
}

// prefetchTier2 selects ONLY Tier-2 files: an on-demand (Tier-0) deferred file is left untouched (served
// on-access), so a plain deferred profile never background-prefetches.
func TestPrefetchTier2SkipsOnDemand(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-prefetch-skip")
	// leave the maps at their default tier (on-demand / 0)
	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.prefetchTier2(0, map[string]string{"app.maps/files/maps": under}, nil, nil, nil)
	for _, n := range []string{"one.mwm", "two.mwm"} {
		if srv.isDeleted("app.maps/files/maps/" + n) {
			t.Fatalf("on-demand (Tier-0) %s must NOT be prefetched/tombstoned", n)
		}
	}
}

// #129 P4: a false stillOK() PAUSES the Tier-2 pass at the first file boundary (the Wi-Fi/idle/charging gate
// closed) -> nothing materialized, so a DISARM mid-run stops prefetch promptly.
func TestPrefetchTier2PausesWhenGateClosed(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-prefetch-pause")
	for rel, d := range m1.Deferred { // Tier-2, but the gate is closed
		d.Tier = int(tierPrefetch)
		m1.Deferred[rel] = d
	}
	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.prefetchTier2(0, map[string]string{"app.maps/files/maps": under}, nil, nil, func() bool { return false })
	for _, n := range []string{"one.mwm", "two.mwm"} {
		if srv.isDeleted("app.maps/files/maps/" + n) {
			t.Fatalf("gate closed: %s must NOT be materialized/tombstoned", n)
		}
	}
}

func TestPinHelpers(t *testing.T) {
	if got := pinnedApp("app.organicmaps/files/x.mwm"); got != "app.organicmaps" {
		t.Fatalf("pinnedApp app-private = %q, want app.organicmaps", got)
	}
	if got := pinnedApp("media/0/DCIM/x.jpg"); got != "media" {
		t.Fatalf("pinnedApp shared = %q, want media", got)
	}
	dir := t.TempDir()
	p := filepath.Join(dir, filepath.FromSlash(pinFileRel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(p, []byte("app.a\n\n  app.b  \n"), 0o644) // blank + whitespace lines ignored
	pins := loadPins(dir)
	if !pins["app.a"] || !pins["app.b"] || len(pins) != 2 {
		t.Fatalf("loadPins = %v, want {app.a, app.b}", pins)
	}
	if loadPins(t.TempDir()) != nil {
		t.Fatalf("loadPins with no pin file must be nil")
	}
}
