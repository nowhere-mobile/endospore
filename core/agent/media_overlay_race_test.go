package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/hanwen/go-fuse/v2/fs"
)

// Regression suite for the 2026-07-03 Deferred-index drops (profile c v209, profile d v4): a seal that
// runs while a media overlay is mounted -- healthy, broken, or racing -- must NEVER drop deferred entries
// the walk didn't positively visit. The original absent-carry probed the path with Lstat, and through a
// live overlay every stub "exists" (getattr answers from the very manifest being rebuilt), so a walk that
// missed the files skipped the carry and the whole deferred set evaporated. The carry now keys on the
// walker's seen-set instead. Real FUSE mounts; self-skips where the environment has none.
//
// NOTE: the test mount carries no "nowheremedia" fstype tag (plain fs.Mount), so the REAL
// mediaOverlayUnders never sees it -- exactly the racing-seal state (the walker's /proc/mounts snapshot
// predates the mount, unders empty). Scenarios that need the MAPPED state inject unders explicitly.

// overlayRaceSetup pushes a profile with two deferred maps + an essential sibling, restores it ("login"),
// and mounts a live overlay over the map dir exactly as mediad does.
func overlayRaceSetup(t *testing.T, tag string) (base, name, pass string, dk []byte, srcB, overlayDir, under string, m1 chunkManifest) {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	base = newHTTPStore(t)
	name, pass = tag, "race horse battery staple"
	createVault(base, name, pass)
	srcA := t.TempDir()
	if err := os.MkdirAll(filepath.Join(srcA, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/index.json"), []byte("REAL-INDEX"), 0o644)
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/one.mwm"), prBytes(6<<20), 0o644)
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/two.mwm"), append(prBytes(5<<20), 0xEE), 0o644)
	pushProfile(base, name, pass, srcA)
	dk = resolveDK(base, name, pass, nil)
	m1 = headManifest(t, base, dk, name, pass)
	if len(m1.Deferred) != 2 {
		t.Fatalf("setup: want 2 deferred, got %d", len(m1.Deferred))
	}
	_, srcB = restoreManifest(t, base, name, pass)
	overlayDir = filepath.Join(srcB, "app.maps/files/maps")
	under = filepath.Join(srcB, mediaCacheDirName, ".under", "app.maps_files_maps")
	if err := os.MkdirAll(under, 0o700); err != nil {
		t.Fatal(err)
	}
	os.Rename(filepath.Join(overlayDir, "index.json"), filepath.Join(under, "index.json"))
	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	root, err := newMediaRoot(srv, "app.maps/files/maps", []string{"one.mwm", "two.mwm"}, under, uint32(os.Getuid()), uint32(os.Getgid()))
	if err != nil {
		t.Fatal(err)
	}
	server, err := fs.Mount(overlayDir, root, &fs.Options{})
	if err != nil {
		t.Skipf("no usable FUSE in this environment: %v", err)
	}
	t.Cleanup(func() { server.Unmount() })
	return
}

// The incident matrix. `undersMapped` injects the mountpoint->.under map (the walker saw the mount);
// otherwise unders is empty (the racing walk, profile d's logoff). `brokenUnder` renames the bind out from
// under the live mount (profile c / task #92). `coldBlobs` empties the known-present set (fresh worker).
func TestSealOverlayDropMatrix(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	for _, tc := range []struct {
		name                   string
		brokenUnder, coldBlobs bool
		undersMapped           bool
	}{
		{"race-undersEmpty", false, false, false},
		{"race-brokenUnder", true, false, false},
		{"race-coldBlobs", false, true, false},
		{"race-broken+cold", true, true, false},
		{"mapped-brokenUnder", true, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od"+tc.name)
			if tc.brokenUnder {
				// reconcile-style: the cache dir is renamed out from under the live mount (task #92)
				if err := os.Rename(under, under+"==deleted=="); err != nil {
					t.Fatal(err)
				}
			}
			if tc.coldBlobs {
				blobCacheMu.Lock()
				blobCache = map[string]bool{}
				blobCacheMu.Unlock()
			}
			prev := mediaUndersFn
			if tc.undersMapped {
				mediaUndersFn = func(s string) (map[string]string, error) {
					if s == srcB {
						return map[string]string{overlayDir: under}, nil
					}
					return nil, nil
				}
			} else {
				mediaUndersFn = func(string) (map[string]string, error) { return nil, nil }
			}
			t.Cleanup(func() { mediaUndersFn = prev })
			pushProfile(base, name, pass, srcB)
			m2 := headManifest(t, base, dk, name, pass)
			if len(m2.Deferred) != 2 {
				t.Fatalf("DEFERRED DROPPED: %d/2 survived (chunks=%d)", len(m2.Deferred), len(m2.Chunks))
			}
			for rel, d1 := range m1.Deferred {
				d2, ok := m2.Deferred[rel]
				if !ok || len(d2.Chunks) != len(d1.Chunks) || d2.Chunks[0] != d1.Chunks[0] {
					t.Fatalf("entry %s mutated/lost", rel)
				}
			}
		})
	}
}

// #84 data-safety (nfctest, 2026-07-05): the LOGOFF fix tears the media overlays DOWN before the final seal
// (roamd `sweepmedia`), so the walk reads the REAL app dirs (mediaUndersFn empty) instead of each overlay's
// .under bind. Reading .under is fine for a periodic seal -- a broken bind just SKIPS the dir, re-sealed next
// cycle -- but at LOGOFF there is no next seal, so a skipped dir silently DROPS a newly-downloaded map that
// isn't in the store head yet. This proves the state the teardown produces: with overlays down, a NEW on-disk
// map seals as deferred AND the previously-deferred (not-on-disk) maps carry forward. Nothing lost.
func TestLogoffSealCapturesNewMediaWithOverlaysDown(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	base := newHTTPStore(t)
	name, pass := "logoffnew", "seal horse battery staple"
	createVault(base, name, pass)
	// The prior head's only map is old.mwm -> a deferred entry.
	srcA := t.TempDir()
	if err := os.MkdirAll(filepath.Join(srcA, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/old.mwm"), prBytes(6<<20), 0o644)
	pushProfile(base, name, pass, srcA)
	dk := resolveDK(base, name, pass, nil)
	m1 := headManifest(t, base, dk, name, pass)
	if len(m1.Deferred) != 1 {
		t.Fatalf("setup: want 1 deferred, got %d", len(m1.Deferred))
	}

	// "Login": restore the essential set. old.mwm is deferred -> NOT on disk (mediad would serve it).
	_, srcB := restoreManifest(t, base, name, pass)
	mapsDir := filepath.Join(srcB, "app.maps/files/maps")
	if err := os.MkdirAll(mapsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(mapsDir, "old.mwm")); err == nil {
		t.Fatal("old.mwm should be deferred (not restored to disk)")
	}
	// The user downloads a NEW map this session -> it lands on real disk (loopback Create through the overlay).
	os.WriteFile(filepath.Join(mapsDir, "new.mwm"), append(prBytes(5<<20), 0xAB), 0o644)

	// The LOGOFF teardown unmounted the overlays -> mediaUndersFn is empty; the walk reads the real dir.
	prev := mediaUndersFn
	mediaUndersFn = func(string) (map[string]string, error) { return nil, nil }
	t.Cleanup(func() { mediaUndersFn = prev })

	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if _, ok := m2.Deferred["app.maps/files/maps/new.mwm"]; !ok {
		t.Fatalf("NEW map dropped by the logoff seal (data loss!); deferred=%v", keysOf(m2.Deferred))
	}
	if _, ok := m2.Deferred["app.maps/files/maps/old.mwm"]; !ok {
		t.Fatalf("OLD deferred map lost (carry-forward broke); deferred=%v", keysOf(m2.Deferred))
	}
}

// Healthy overlay + healthy bind, unders mapped (the everyday no-teardown state): the essential sibling
// must keep sealing (from .under) while the deferred entries carry.
func TestSealThroughLiveOverlayKeepsEverything(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, _ := overlayRaceSetup(t, "od-healthy")
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
	if len(m2.Deferred) != 2 {
		t.Fatalf("deferred dropped under a healthy overlay: %d/2", len(m2.Deferred))
	}
	_, srcC := restoreManifest(t, base, name, pass)
	if got, err := os.ReadFile(filepath.Join(srcC, "app.maps/files/maps/index.json")); err != nil || !bytes.Equal(got, []byte("REAL-INDEX")) {
		t.Fatalf("essential sibling lost: %q err=%v", got, err)
	}
}
