package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260906-16 (#91 slice 5c). `Chunks` is "a flat list over one concatenated tar with no per-file labels",
// so a reader can locate a DEFERRED file and nothing in the essential half -- which is where installed app
// CODE rides. That is what made the filed 5c shape unbuildable. The Ess index records the per-file spans the
// walk already computes, under one flag that also forces per-file alignment.

// essSeal runs one #apps push with the essential index on, and returns the sealed manifest.
func essSeal(t *testing.T, base, name, pass, src string) chunkManifest {
	t.Helper()
	sealRefused = false
	pushProfile(base, name+"#apps", pass, src)
	if sealRefused {
		t.Fatal("the #apps seal was refused")
	}
	return headManifestOf(t, base, name+"#apps", pass)
}

// TestEssIndexNamesEveryStagedFile: with the flag on, every file the walk saw has a span.
func TestEssIndexNamesEveryStagedFile(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	const name, pass = "essnames", "correct horse battery staple"
	createVault(base, name, pass)

	src := stageApps(t, "com.example.a", "com.example.b")
	m := essSeal(t, base, name, pass, src)
	for _, rel := range []string{"manifest.tsv", "com.example.a/base.apk", "com.example.b/base.apk"} {
		r, ok := m.Ess[rel]
		if !ok {
			t.Fatalf("Ess has no span for %q -- an unindexed file cannot be carried (index: %v)", rel, m.Ess)
		}
		if r.S < 0 || r.E > len(m.Chunks) || r.E <= r.S {
			t.Fatalf("Ess[%q] = [%d,%d) is not a valid span of %d chunks", rel, r.S, r.E, len(m.Chunks))
		}
	}
}

// TestEssIndexSpanReconstructsTheFile is the assertion that makes the index TRUE rather than plausible: fetch
// exactly the chunks a span names, and the file must come back out of them. A span that merely looks
// well-formed would carry corrupt bytes to another lineage and install a broken APK.
func TestEssIndexSpanReconstructsTheFile(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	const name, pass = "essrecon", "correct horse battery staple"
	createVault(base, name, pass)

	// ⚠ ONE PACKAGE IS DEFERRED, AND IT SORTS FIRST, so the walk emits its chunks BEFORE the file under
	// test and the emit indices stop equalling the essential ones. Without this the remap through essIdx
	// is an identity and a mutation publishing RAW emit indices convicts nothing -- which is what happened
	// on the first pass. Once anything in a scope defers, an unmapped span silently names other files'
	// chunks, and #apps defers routinely (every on-demand app).
	src := stageApps(t, "com.aaa.deferred", "com.example.solo")
	dfl := filepath.Join(t.TempDir(), "defer.list")
	if err := os.WriteFile(dfl, []byte("com.aaa.deferred/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", dfl)
	want, err := os.ReadFile(filepath.Join(src, "com.example.solo", "base.apk"))
	if err != nil {
		t.Fatal(err)
	}
	m := essSeal(t, base, name, pass, src)
	if len(m.Deferred) == 0 {
		t.Fatal("fixture: nothing deferred, so the emit->essential remap is an identity and untested here")
	}
	r, ok := m.Ess["com.example.solo/base.apk"]
	if !ok {
		t.Fatal("no span for the file under test")
	}
	key, _, _ := resolveKey(base, name+"#apps", pass)

	// Per-file alignment means the span is exactly this file's own tar region -- untar it standalone.
	var raw []byte
	for i := r.S; i < r.E; i++ {
		pt, ue := unpackChunk(unseal(key, getChunk(base, m.Chunks[i])), m.Version)
		if ue != nil {
			t.Fatalf("chunk %d of the span did not unpack: %v", i, ue)
		}
		raw = append(raw, pt...)
	}
	dest := t.TempDir()
	// untarFrom returns the count of REJECTED entries and check()s any malformed stream, so a clean return
	// of 0 is the success case; the real proof is the file content compared below.
	if rejected := untarFrom(dest, bytes.NewReader(raw)); rejected != 0 {
		t.Fatalf("the span untarred with %d rejected entr(ies) -- it is not this file's own region", rejected)
	}
	got, err := os.ReadFile(filepath.Join(dest, "com.example.solo", "base.apk"))
	if err != nil {
		t.Fatalf("the span untarred but did not contain its own file: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("the span reconstructed %d bytes, want %d -- the index is describing the wrong chunks",
			len(got), len(want))
	}
}

// TestEssIndexSurvivesAWarmScanCache is the D1 trap, and the reason this is worth a test of its own. `ranges`
// used to be appended in ONE arm -- the fresh-chunk one. In steady state almost every file takes the OTHER
// arm, so the index would be empty on every seal after the first. #apps escapes that today only because roamd
// stages with a plain `cp` (no `-p`), giving every APK a fresh mtime so the cache never hits; adding `cp -p`
// as an optimisation would have made the whole carry silently inert.
func TestEssIndexSurvivesAWarmScanCache(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir()) // the scan cache persists between seals
	const name, pass = "esswarm", "correct horse battery staple"
	createVault(base, name, pass)

	// Package names unique to this test, because blobCacheAdd below writes a PROCESS-GLOBAL set: shared
	// content would mark another test's chunks present in a store that does not have them.
	src := stageApps(t, "warmcache.a", "warmcache.b")
	first := essSeal(t, base, name, pass, src)
	if len(first.Ess) == 0 {
		t.Fatal("fixture: the first seal produced no index")
	}
	// ⚠ WITHOUT THIS THE CACHE CANNOT HIT AND THE TEST PROVES NOTHING. fileScanCache.get refuses any entry
	// whose chunks are not CONFIRMED PRESENT in the store -- a GC'd chunk must force a re-chunk rather than
	// be re-referenced. On a real handset that confirmation arrives at LOGIN, where the restore seeds
	// blobCacheAdd from the manifest it just fetched; here nothing has restored, so it is seeded explicitly.
	// The first version of this test omitted it, the cache silently never hit, and the mutation that removes
	// the whole fix passed clean.
	for _, h := range first.Chunks {
		blobCacheAdd(h)
	}
	if n := scanCacheHitsFor(t, dkOf(t, base, name, pass), src); n == 0 {
		t.Fatal("fixture: the scan cache still answers for NO file, so the re-seal below re-chunks everything " +
			"and the cached arm this test exists to cover is never reached")
	}
	// Seal the SAME tree again: same mtime/size/mode, so the scan cache answers for every file.
	second := essSeal(t, base, name, pass, src)
	for rel, want := range first.Ess {
		got, ok := second.Ess[rel]
		if !ok {
			t.Fatalf("the SECOND seal lost %q from the index -- the scan-cache arm records no range, so the "+
				"index empties out in steady state and the carry silently does nothing", rel)
		}
		if got.E-got.S != want.E-want.S {
			t.Fatalf("%q spans %d chunks on the re-seal, %d on the first", rel, got.E-got.S, want.E-want.S)
		}
	}
}

// TestEssIndexIsAbsentWithoutTheFlag: the fleet's manifests must not change shape at all.
func TestEssIndexIsAbsentWithoutTheFlag(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "essoff", "correct horse battery staple"
	createVault(base, name, pass)

	// ⚠ A BIG FILE, DELIBERATELY. With only sub-threshold files this test passes for the WRONG REASON:
	// they group, the large-file arm never runs, and no range is recorded whether the gate works or not.
	// A mutation publishing the index unconditionally did NOT fail this test until the file went over the
	// threshold, which is exactly the false comfort the mutation pass exists to find.
	src := stageApps(t, "com.example.a")
	if err := os.WriteFile(filepath.Join(src, "com.example.a", "big.apk"), bytes.Repeat([]byte("z"), 2<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	m := essSeal(t, base, name, pass, src)
	if len(m.Ess) != 0 {
		t.Fatalf("Ess was written with the flag OFF (%d entries) -- every fielded manifest would change shape", len(m.Ess))
	}
	// And it must be omitted from the JSON entirely, not serialised as an empty object.
	j, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(j, []byte(`"ess"`)) {
		t.Fatal("the ess key is present in a flag-off manifest -- omitempty is what keeps a legacy head byte-identical")
	}
}

// TestEssIndexForcesPerFileAlignment. Sub-threshold files are otherwise GROUPED through one cdcSplit, so their
// chunks span packages and no per-file span exists to record. The flag implies threshold 0 for exactly this
// reason, and it is ONE flag because sealFileThreshold() silently ignores a non-positive override.
func TestEssIndexForcesPerFileAlignment(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	const name, pass = "essalign", "correct horse battery staple"
	createVault(base, name, pass)

	// Every staged file is far below the 1 MiB default threshold, so without the forced alignment they would
	// share one grouped region and none would be individually addressable.
	m := essSeal(t, base, name, pass, stageApps(t, "com.example.a", "com.example.b", "com.example.c"))
	seen := map[int]string{}
	for rel, r := range m.Ess {
		for i := r.S; i < r.E; i++ {
			if other, dup := seen[i]; dup {
				t.Fatalf("chunk %d is claimed by BOTH %q and %q -- the files were grouped, so the spans overlap "+
					"and carrying one would drag in the other's bytes", i, other, rel)
			}
			seen[i] = rel
		}
	}
	if len(m.Ess) < 4 { // 3 apks + manifest.tsv
		t.Fatalf("only %d files indexed, want at least 4 -- sub-threshold files were grouped away", len(m.Ess))
	}
}

// dkOf opens the #apps scope data key, which is what the scan cache is tagged by.
func dkOf(t *testing.T, base, name, pass string) []byte {
	t.Helper()
	dk := resolveDK(base, name+"#apps", pass, nil)
	if dk == nil {
		t.Fatal("no #apps DK")
	}
	return dk
}

// scanCacheHitsFor counts the files under src the scan cache would answer for, asking it EXACTLY as the
// walk does -- info.Mode() entire, not just the permission bits. Getting that wrong is why an earlier probe
// of this reported zero hits and sent me looking in the wrong place.
func scanCacheHitsFor(t *testing.T, dk []byte, src string) int {
	t.Helper()
	sc := newFileScanCache(dk)
	hits := 0
	for rel := range sc.m {
		st, err := os.Stat(filepath.Join(src, rel))
		if err != nil {
			continue
		}
		if sc.getIf(true, rel, st.ModTime().UnixNano(), st.Size(), uint32(st.Mode())) != nil {
			hits++
		}
	}
	return hits
}
