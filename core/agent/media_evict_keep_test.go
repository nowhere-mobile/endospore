package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20261110-04: evictCache(keep) counts the entry its caller has just landed but never deletes it.

// evictKeepNoFloor is 1<<62 bytes: free space is always under it, so only keep can end the loop.
const evictKeepNoFloor = "4611686018427387904"

// evictKeepPlant writes a dotless 100-byte cache entry, aged by age.
func evictKeepPlant(t *testing.T, dir, name string, age time.Duration) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, bytes.Repeat([]byte{'x'}, 100), 0o600); err != nil {
		t.Fatal(err)
	}
	mt := time.Now().Add(-age)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	return p
}

func evictKeepPlantFour(t *testing.T, dir string) (older []string, newest string) {
	t.Helper()
	older = []string{
		evictKeepPlant(t, dir, "aaaa1111", 4*time.Hour),
		evictKeepPlant(t, dir, "bbbb2222", 3*time.Hour),
		evictKeepPlant(t, dir, "cccc3333", 2*time.Hour),
	}
	return older, evictKeepPlant(t, dir, "dddd4444", time.Hour)
}

func evictKeepCheck(t *testing.T, older []string, keep string) {
	t.Helper()
	for _, p := range older {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("older entry %s must be evicted, stat err=%v", filepath.Base(p), err)
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("keep %s must survive: %v", filepath.Base(keep), err)
	}
}

// K1: a cap smaller than keep is never met while keep counts; every older entry goes, keep stays.
func TestEvictKeepSurvivesACapSmallerThanIt(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", "0")
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "50")
	dir := t.TempDir()
	older, keep := evictKeepPlantFour(t, dir)
	(&mediaServer{cacheDir: dir}).evictCache(keep)
	evictKeepCheck(t, older, keep)
}

// K2: a floor no deletion can reach (the device scenario, made deterministic).
func TestEvictKeepSurvivesAnUnreachableFloor(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", evictKeepNoFloor)
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "")
	dir := t.TempDir()
	older, keep := evictKeepPlantFour(t, dir)
	(&mediaServer{cacheDir: dir}).evictCache(keep)
	evictKeepCheck(t, older, keep)
}

// K5: keep is compared by its full path: the same base name in another directory is a different file.
func TestEvictKeepComparesTheFullPath(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", evictKeepNoFloor)
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "")
	dir := t.TempDir()
	p := evictKeepPlant(t, dir, "eeee5555", time.Hour)
	(&mediaServer{cacheDir: dir}).evictCache(filepath.Join(t.TempDir(), "eeee5555"))
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("an entry whose base name matches keep in ANOTHER dir must still be evicted, stat err=%v", err)
	}
}

// K3: fetchFile on a pre-Pz (whole-file) entry returns a path that exists even when eviction can never be satisfied.
func TestEvictKeepFetchFileReturnsALandedPath(t *testing.T) {
	preGateSeal(t)
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "evictkeep-c", "evictkeep c horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := prBytes(5 << 20)
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), data, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	d, ok := m.Deferred[rel]
	if !ok {
		t.Fatal("test needs a deferred entry")
	}
	d.Pz = nil
	m.Deferred[rel] = d
	if d.rangeable() {
		t.Fatal("entry without Pz must not be rangeable")
	}
	cache := t.TempDir()
	older := evictKeepPlant(t, cache, "ffff6666", time.Hour)
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", evictKeepNoFloor)
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "")

	srv := newMediaServer(base, dk, m, cache)
	p, err := srv.fetchFile(rel)
	if err != nil {
		t.Fatal(err)
	}
	if p != filepath.Join(cache, cacheKey(d)) {
		t.Fatalf("fetchFile returned %q", p)
	}
	got, err := os.ReadFile(p)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("the returned path must hold the file: %d bytes err=%v", len(got), err)
	}
	if _, err := os.Stat(older); !os.IsNotExist(err) {
		t.Fatalf("the older planted entry must be evicted (eviction ran), stat err=%v", err)
	}
}

// K4: one ensureRange call over every chunk promotes the entry and returns the complete name, which exists.
func TestEvictKeepEnsureRangePromotionReturnsALandedPath(t *testing.T) {
	preGateSeal(t)
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "evictkeep-d", "evictkeep d horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := prBytes(9 << 20)
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), data, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	d, ok := m.Deferred[rel]
	if !ok || !d.rangeable() {
		t.Fatal("test needs a rangeable deferred entry")
	}
	cache := t.TempDir()
	older := evictKeepPlant(t, cache, "gggg7777", time.Hour)
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", evictKeepNoFloor)
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "")

	srv := newMediaServer(base, dk, m, cache)
	cp := filepath.Join(cache, cacheKey(d))
	p, err := srv.ensureRange(rel, 0, d.Size)
	if err != nil {
		t.Fatal(err)
	}
	if p != cp {
		t.Fatalf("ensureRange over the whole file must return the complete name, got %q", p)
	}
	got, err := os.ReadFile(p)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("the returned path must hold the file: %d bytes err=%v", len(got), err)
	}
	if _, err := os.Stat(cp + ".part"); !os.IsNotExist(err) {
		t.Fatalf("the .part must be gone after promotion, stat err=%v", err)
	}
	if _, err := os.Stat(older); !os.IsNotExist(err) {
		t.Fatalf("the older planted entry must be evicted (eviction ran), stat err=%v", err)
	}
}
