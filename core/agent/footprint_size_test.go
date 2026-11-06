package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// #85: pushProfile records each chunk's sealed blob size in the manifest so profileFootprint (and billing's
// payRent/leaseRefs) size the profile from the manifest alone -- no per-chunk store round-trip (which in cap
// mode DOWNLOADED every chunk just to measure it). Assert the manifest carries a correct Size for every
// chunk, that a no-change re-seal carries those sizes FORWARD (dedup path, no re-seal), and that the
// footprint total agrees with the chunk sizes.
func TestManifestChunkSizes(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "sizes", "footprint horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	big := make([]byte, 6<<20) // ~6 MiB random -> several chunks
	if _, err := rand.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "a.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "b.txt"), []byte("a second file"), 0o600); err != nil {
		t.Fatal(err)
	}

	// checkManifestSizes reads the head -> manifest and verifies every chunk's recorded size == the real blob.
	checkManifestSizes := func(stage string) chunkManifest {
		key, mb, ok := resolveKey(base, name, pass)
		if !ok {
			t.Fatalf("%s: resolveKey failed", stage)
		}
		pt := unseal(key, mb)
		if !bytes.HasPrefix(pt, cdcMagic) {
			t.Fatalf("%s: head is not a CDC manifest", stage)
		}
		var m chunkManifest
		if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
			t.Fatalf("%s: %v", stage, err)
		}
		if len(m.Chunks) < 2 {
			t.Fatalf("%s: expected multiple chunks to exercise this, got %d", stage, len(m.Chunks))
		}
		if len(m.Sizes) != len(m.Chunks) {
			t.Fatalf("%s: Sizes not populated: %d sizes for %d chunks", stage, len(m.Sizes), len(m.Chunks))
		}
		for i, ch := range m.Chunks {
			if want := int64(len(getBlob(base, ch))); m.Sizes[i] != want {
				t.Fatalf("%s: chunk %d recorded size %d != actual blob %d", stage, i, m.Sizes[i], want)
			}
		}
		return m
	}

	pushProfile(base, name, pass, src) // fresh seal: sizes come from the sealed length
	m1 := checkManifestSizes("first seal")

	pushProfile(base, name, pass, src) // no-change re-seal: all chunks dedup -> sizes CARRIED FORWARD, not re-sealed
	m2 := checkManifestSizes("carry-forward re-seal")

	// The carry-forward seal must reproduce the same chunk sizes (same content -> same sealed blobs).
	if len(m1.Sizes) != len(m2.Sizes) {
		t.Fatalf("chunk count changed across a no-op re-seal: %d -> %d", len(m1.Sizes), len(m2.Sizes))
	}

	// footprint total = head + manifest + sum(chunk sizes); it must at least cover the chunk bytes.
	var chunkSum int64
	for _, sz := range m2.Sizes {
		chunkSum += sz
	}
	var total int64
	for _, sz := range mustFootprint(t, base, name, pass, nil) {
		total += sz
	}
	if total < chunkSum || chunkSum == 0 {
		t.Fatalf("footprint total %d does not cover chunk sum %d", total, chunkSum)
	}
}

// TestFootprintSpansAllScopes (task_2cd90cd1): profileFootprint(name) must count + lease the SIBLING sealed
// scopes -- device-encrypted app data (name#de) and external offline media (name#media, e.g. a downloaded
// OrganicMaps map under /data/media) -- not just the vault. Counting only the vault undercounted GET-USAGE (a
// 72MB offline map read as ~1MB) AND left the #media/#de blobs un-leased, so the gateway GC reaped them =
// offline-media data-loss. The base footprint must be a SUPERSET of each sibling scope's footprint and cover
// the offline-map bytes.
func TestFootprintSpansAllScopes(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "allscopes", "footprint horse battery staple"
	createVault(base, name, pass)

	// base vault: a small essential file
	vsrc := t.TempDir()
	if err := os.WriteFile(filepath.Join(vsrc, "vault.txt"), []byte("small vault file"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, vsrc)

	// #de scope: device-encrypted app data (multi-chunk)
	dsrc := t.TempDir()
	if err := os.WriteFile(filepath.Join(dsrc, "de.bin"), prBytes(2<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#de", pass, dsrc)

	// #media scope: a big multi-chunk DEFERRED offline-media file, like a downloaded OrganicMaps map
	msrc := t.TempDir()
	bigMap := prBytes(9 << 20)
	if err := os.MkdirAll(filepath.Join(msrc, "maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(msrc, "maps", "region.map"), bigMap, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#media", pass, msrc)

	fpBase, _ := profileFootprint(base, name, pass, nil)
	fpDe, _ := profileFootprint(base, name+"#de", pass, nil)
	fpMedia, _ := profileFootprint(base, name+"#media", pass, nil)
	if len(fpBase) == 0 || len(fpDe) == 0 || len(fpMedia) == 0 {
		t.Fatalf("empty footprint(s): base=%d de=%d media=%d", len(fpBase), len(fpDe), len(fpMedia))
	}

	// The base profile's footprint must COVER every sibling-scope object key -- else it is un-leased and the
	// gateway GC reaps the #de app data / the offline map (data-loss).
	for ref := range fpDe {
		if _, ok := fpBase[ref]; !ok {
			t.Fatalf("#de ref %q missing from the base footprint -- un-leased, GC would reap it", ref)
		}
	}
	for ref := range fpMedia {
		if _, ok := fpBase[ref]; !ok {
			t.Fatalf("#media ref %q missing from the base footprint -- un-leased, GC would reap the offline map", ref)
		}
	}

	// GET-USAGE undercount: the base footprint total must cover the big offline map's bytes (pre-fix it read
	// only the vault for a 9 MiB map).
	var total int64
	for _, sz := range fpBase {
		total += sz
	}
	if total < int64(len(bigMap)) {
		t.Fatalf("base footprint total %d does not cover the %d-byte offline map -> GET-USAGE undercount", total, len(bigMap))
	}
}

// TestFootprintCoversAppsScope (#199 app-persistence P1): the captured user-installed APK bytes seal to the
// name#apps sibling scope (like #media), so profileFootprint(name) MUST lease every #apps chunk -- else the
// gateway GC reaps a kept app's code out from under it (the same un-leased-reap data-loss #media/#de hit in
// task_2cd90cd1), and GET-USAGE undercounts the app footprint the user is billed for.
func TestFootprintCoversAppsScope(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "appscope", "footprint horse battery staple"
	createVault(base, name, pass)

	// base vault: a small essential file
	vsrc := t.TempDir()
	if err := os.WriteFile(filepath.Join(vsrc, "vault.txt"), []byte("small vault file"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, vsrc)

	// #apps scope: a staged APK set (a multi-chunk base.apk under a per-package dir + the restore manifest),
	// exactly what the logoff worker stages before `push s3 name#apps`.
	asrc := t.TempDir()
	if err := os.MkdirAll(filepath.Join(asrc, "com.example.app"), 0o755); err != nil {
		t.Fatal(err)
	}
	apk := prBytes(3 << 20)
	if err := os.WriteFile(filepath.Join(asrc, "com.example.app", "base.apk"), apk, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(asrc, "manifest.tsv"), []byte("com.example.app\t42\t1\tbase.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#apps", pass, asrc)

	fpBase, _ := profileFootprint(base, name, pass, nil)
	fpApps, _ := profileFootprint(base, name+"#apps", pass, nil)
	if len(fpBase) == 0 || len(fpApps) == 0 {
		t.Fatalf("empty footprint(s): base=%d apps=%d", len(fpBase), len(fpApps))
	}
	// Every #apps object key must be covered by the base profile's footprint (else un-leased -> GC reaps it).
	for ref := range fpApps {
		if _, ok := fpBase[ref]; !ok {
			t.Fatalf("#apps ref %q missing from the base footprint -- un-leased, GC would reap the captured APK", ref)
		}
	}
	// GET-USAGE: the base total must cover the captured APK's bytes.
	var total int64
	for _, sz := range fpBase {
		total += sz
	}
	if total < int64(len(apk)) {
		t.Fatalf("base footprint total %d does not cover the %d-byte captured APK -> GET-USAGE undercount", total, len(apk))
	}
}
