package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// #84 P2: with NOWHERE_ONDEMAND_MEDIA=1 a large media file is chunked into the manifest's Deferred index and
// EXCLUDED from the essential (login) restore -- yet its chunks still live in the store and reconstruct the
// original file byte-for-byte (the media daemon serves it on-access in P3). Off by default the manifest is
// unchanged (TestManifestDeferredOmitempty + the seal round-trip tests cover that).
func TestSealDefersMediaOutOfEssential(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")           // 4 KiB floor so the test map qualifies
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096") // and it's a "large" (file-aligned) file

	base := newHTTPStore(t)
	name, pass := "media", "on demand horse battery"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.foo/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(src, "app.foo/shared_prefs"), 0o755)
	// essential: a small settings file (grouped, restored at login)
	if err := os.WriteFile(filepath.Join(src, "app.foo/shared_prefs/s.xml"), []byte("essential-setting"), 0o644); err != nil {
		t.Fatal(err)
	}
	// deferred: a big "map" under files/ (a media dir, over the floor)
	mapBytes := bytes.Repeat([]byte("MAPDATA-0123456789-"), 5000) // ~95 KiB
	rel := "app.foo/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), mapBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	m := loadCDCManifest(base, dk, v.Manifest)

	// (1) the map is in the Deferred index (size/chunks), not the essential Chunks
	d, ok := m.Deferred[rel]
	if !ok {
		t.Fatalf("map should be in Deferred; Deferred keys = %v", keysOf(m.Deferred))
	}
	if d.Size != int64(len(mapBytes)) || len(d.Chunks) == 0 {
		t.Fatalf("deferred entry wrong: size=%d (want %d) chunks=%d", d.Size, len(mapBytes), len(d.Chunks))
	}

	// (2) essential login restore has the settings file + the parent dir, but NOT the map
	_, dst := restoreManifest(t, base, name, pass)
	if _, err := os.Stat(filepath.Join(dst, "app.foo/shared_prefs/s.xml")); err != nil {
		t.Fatal("essential settings file missing after login restore")
	}
	if fi, err := os.Stat(filepath.Join(dst, "app.foo/files/maps")); err != nil || !fi.IsDir() {
		t.Fatal("the deferred file's parent dir must be restored at login (so the daemon can serve into it)")
	}
	if _, err := os.Stat(filepath.Join(dst, rel)); err == nil {
		t.Fatal("deferred map must NOT be restored at login -- it's served on-access")
	}

	// (3) the deferred chunks reconstruct the original file byte-for-byte
	var got []byte
	for _, h := range d.Chunks {
		raw, err := unpackChunk(unseal(dk, getChunk(base, h)), m.Version)
		if err != nil {
			t.Fatalf("unpack deferred chunk: %v", err)
		}
		got = append(got, raw...)
	}
	if !bytes.Equal(got, mapBytes) {
		t.Fatalf("deferred reconstruction mismatch: got %d bytes, want %d", len(got), len(mapBytes))
	}
}

func keysOf(m map[string]deferredFile) []string {
	k := make([]string, 0, len(m))
	for s := range m {
		k = append(k, s)
	}
	return k
}

// #129 P2: the seal splits deferred media THREE ways by tier. A curated- or override-prefetch app's media is
// deferred with Tier=2; an override-essential app's (and a #108-pinned app's) media rides the login tar (NOT
// deferred); an unconfigured app's media stays on-demand (Tier=0). Deferred files are still excluded from the
// login restore regardless of tier, so login time is unchanged (the prefetch itself is P3).
func TestSealTiersMedia(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "media", "tiered horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	blob := bytes.Repeat([]byte("MAPDATA-0123456789-"), 5000) // ~95 KiB, over the floor
	apps := []string{"app.organicmaps", "app.pref", "app.ess", "app.od", "app.pinned"}
	for _, a := range apps {
		if err := os.MkdirAll(filepath.Join(src, a, "files"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(src, a, "files", "region.mwm"), blob, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// per-profile roaming config: pref->prefetch, ess->essential; pin app.pinned
	cfgDir := filepath.Join(src, "com.nowhere.chooser/files")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(cfgDir, "nowhere-media-tiers"), []byte("app.pref prefetch\napp.ess essential\n"), 0o644)
	os.WriteFile(filepath.Join(cfgDir, "nowhere-pins"), []byte("app.pinned\n"), 0o644)

	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	v, isV := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("expected a vault head")
	}
	m := loadCDCManifest(base, dk, v.Manifest)
	get := func(app string) (deferredFile, bool) {
		d, ok := m.Deferred[app+"/files/region.mwm"]
		return d, ok
	}

	// curated default (organicmaps) + explicit override (pref) -> deferred Tier=2 (prefetch)
	if d, ok := get("app.organicmaps"); !ok || d.Tier != int(tierPrefetch) {
		t.Fatalf("organicmaps should be deferred Tier=2 (curated prefetch); ok=%v tier=%d", ok, d.Tier)
	}
	if d, ok := get("app.pref"); !ok || d.Tier != int(tierPrefetch) {
		t.Fatalf("app.pref should be deferred Tier=2 (override prefetch); ok=%v tier=%d", ok, d.Tier)
	}
	// unconfigured -> deferred Tier=0 (on-demand default)
	if d, ok := get("app.od"); !ok || d.Tier != int(tierOnDemand) {
		t.Fatalf("app.od should be deferred Tier=0 (default on-demand); ok=%v tier=%d", ok, d.Tier)
	}
	// essential-tier + #108 pin -> NOT deferred (ride the login tar)
	if _, ok := get("app.ess"); ok {
		t.Fatal("app.ess (essential tier) must NOT be deferred")
	}
	if _, ok := get("app.pinned"); ok {
		t.Fatal("app.pinned (#108 pin) must NOT be deferred")
	}

	// login restore materializes the essential/pinned maps, not the deferred (prefetch/on-demand) ones
	_, dst := restoreManifest(t, base, name, pass)
	for _, ess := range []string{"app.ess", "app.pinned"} {
		if _, err := os.Stat(filepath.Join(dst, ess, "files", "region.mwm")); err != nil {
			t.Fatalf("%s map must be restored at login (essential): %v", ess, err)
		}
	}
	for _, def := range []string{"app.organicmaps", "app.pref", "app.od"} {
		if _, err := os.Stat(filepath.Join(dst, def, "files", "region.mwm")); err == nil {
			t.Fatalf("%s map must NOT be restored at login (deferred)", def)
		}
	}
}

// #129 / #127: an EXISTING profile's already-deferred media (walk-unseen, carried by the present-not-deleted
// rule) must be RE-TIERED to the current config on the next seal -- else curated defaults never take effect on
// media that is already deferred. Seal a Tier-0 map, then config app.foo->prefetch + remove it locally (so the
// re-seal takes the CARRY path, not the walk), and re-seal: it must be carried AND flipped to Tier-2.
func TestCarryRetiersDeferredMedia(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	base := newHTTPStore(t)
	name, pass := "carry", "carry horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	rel := "app.foo/files/region.mwm"
	if err := os.MkdirAll(filepath.Join(src, "app.foo/files"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, filepath.FromSlash(rel)), bytes.Repeat([]byte("MAPDATA-"), 20000), 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	dk := resolveDK(base, name, pass, nil)
	m1 := headManifest(t, base, dk, name, pass)
	if d, ok := m1.Deferred[rel]; !ok || d.Tier != int(tierOnDemand) {
		t.Fatalf("first seal: %s should be deferred Tier-0 (on-demand default); ok=%v tier=%d", rel, ok, d.Tier)
	}

	// re-tier app.foo -> prefetch, then REMOVE the file locally so the next seal must take the
	// present-not-deleted CARRY path (the walk never sees it), and re-seal.
	cfg := filepath.Join(src, "com.nowhere.chooser/files")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(cfg, "nowhere-media-tiers"), []byte("app.foo prefetch\n"), 0o644)
	os.Remove(filepath.Join(src, filepath.FromSlash(rel)))
	pushProfile(base, name, pass, src)

	m2 := headManifest(t, base, dk, name, pass)
	if d, ok := m2.Deferred[rel]; !ok || d.Tier != int(tierPrefetch) {
		t.Fatalf("carry re-tier: %s must be carried forward AND flipped to Tier-2 (prefetch); ok=%v tier=%d", rel, ok, d.Tier)
	}
}

// #129 P5: publishAppProg aggregates per-app Tier-2 progress (Sigma chunk bytes done/total), counting a
// materialized (tombstoned) file toward done; on-demand (Tier-0) media is excluded; 100% shows DONE.
func TestPublishAppProg(t *testing.T) {
	m := chunkManifest{Version: 2, Deferred: map[string]deferredFile{
		"app.maps/files/a.mwm":  {Chunks: []string{"h"}, Size: 100, Tier: int(tierPrefetch)},
		"app.maps/files/b.mwm":  {Chunks: []string{"h"}, Size: 300, Tier: int(tierPrefetch)},
		"app.other/files/c.bin": {Chunks: []string{"h"}, Size: 50, Tier: int(tierOnDemand)}, // Tier-0 -> excluded
	}}
	srv := newMediaServer("", nil, m, t.TempDir())
	srv.appProgPath = filepath.Join(t.TempDir(), mediaAppProgFile)

	srv.markDeleted("app.maps/files/a.mwm") // 100 of 400 materialized
	srv.publishAppProg()
	got, err := os.ReadFile(srv.appProgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(got, []byte("app.maps 100 400 FETCHING")) {
		t.Fatalf("app.maps progress wrong: %q", got)
	}
	if bytes.Contains(got, []byte("app.other")) {
		t.Fatalf("on-demand (Tier-0) app must be excluded from prefetch progress: %q", got)
	}

	srv.markDeleted("app.maps/files/b.mwm") // 400 of 400 -- nothing left in flight
	srv.publishAppProg()
	// NWP-20260902-02: a SETTLED app leaves the list, and with nothing in flight the file is REMOVED so
	// GET-MEDIA-APP-PROGRESS answers IDLE. This assertion previously required "app.maps 400 400 DONE" --
	// it encoded the defect: both readers treat any non-IDLE reply as "still running", so a finished
	// prefetch pinned an ongoing, non-dismissable "Downloading offline media" notice on screen until
	// logoff, with the Launcher3 icon ring stuck at 100% (NW-56d64ab6cab3).
	if _, err := os.Stat(srv.appProgPath); !os.IsNotExist(err) {
		got, _ = os.ReadFile(srv.appProgPath)
		t.Fatalf("with nothing in flight the progress file must be gone, got %q (stat err %v)", got, err)
	}
}

// NWP-20260902-02: the MIXED case, which is the one the notice actually got wrong. One app settled, one
// still fetching: the settled app must vanish and the fetching one must remain. This also pins the reason
// the chooser had to stop using pollDaemon -- that returns only the FIRST line, so whichever app sorted
// first decided whether the notice appeared at all.
func TestPublishAppProgOmitsSettledButKeepsInFlight(t *testing.T) {
	m := chunkManifest{Version: 2, Deferred: map[string]deferredFile{
		"app.done/files/a.bin":     {Chunks: []string{"h"}, Size: 100, Tier: int(tierPrefetch)},
		"app.fetching/files/b.bin": {Chunks: []string{"h"}, Size: 200, Tier: int(tierPrefetch)},
	}}
	srv := newMediaServer("", nil, m, t.TempDir())
	srv.appProgPath = filepath.Join(t.TempDir(), mediaAppProgFile)

	srv.markDeleted("app.done/files/a.bin") // settled; app.fetching has not started
	srv.publishAppProg()
	got, err := os.ReadFile(srv.appProgPath)
	if err != nil {
		t.Fatalf("a still-fetching app must keep the file present: %v", err)
	}
	if bytes.Contains(got, []byte("app.done")) {
		t.Fatalf("settled app must be omitted: %q", got)
	}
	if !bytes.Contains(got, []byte("app.fetching 0 200 FETCHING")) {
		t.Fatalf("in-flight app must remain: %q", got)
	}
}

// #128 smoothness: an IN-FLIGHT fetch's live bytes advance the app ring WITHIN a file (on the fixed materialize
// total), staying monotonic; when the file lands the live partial becomes a materialized full (no dip).
func TestPublishAppProgLivePartial(t *testing.T) {
	m := chunkManifest{Version: 2, Deferred: map[string]deferredFile{
		"app.maps/files/a.mwm": {Chunks: []string{"h"}, Size: 100, Tier: int(tierPrefetch)},
	}}
	srv := newMediaServer("", nil, m, t.TempDir())
	srv.progPath = filepath.Join(t.TempDir(), mediaProgressFile) // progSet is a no-op without progPath
	srv.appProgPath = filepath.Join(t.TempDir(), mediaAppProgFile)

	// a.mwm is fetching, 60 of 100 bytes in -> the ring shows 60/100 (live partial on the fixed total).
	srv.progSet("k", "app.maps/files/a.mwm", 60, 100)
	got, err := os.ReadFile(srv.appProgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(got, []byte("app.maps 60 100 FETCHING")) {
		t.Fatalf("in-flight bytes must advance the ring within a file: %q", got)
	}

	// completes: progDone drops it from active (does NOT publish -> no dip), markDeleted materializes it -> 100/100
	srv.progDone("k")
	srv.markDeleted("app.maps/files/a.mwm")
	srv.publishAppProg()
	// NWP-20260902-02: once it lands, nothing is in flight -- the app leaves the list and the file is removed,
	// so every reader clears. This previously asserted "app.maps 100 100 DONE"; that reading is what kept the
	// ongoing notice and the icon ring on screen forever. The no-dip property this test exists for is intact
	// and in fact stronger: a settled app is DROPPED, so it can never regress to a smaller number first.
	if _, err := os.Stat(srv.appProgPath); !os.IsNotExist(err) {
		got, _ = os.ReadFile(srv.appProgPath)
		t.Fatalf("after the file lands nothing is in flight, so the file must be gone, got %q (stat %v)", got, err)
	}
}
