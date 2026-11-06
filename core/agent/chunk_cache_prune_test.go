package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261017-11: the OTA chunk cache (/data/nowhere/otacache) had no remover, so it kept every release's
// changed chunks forever. pruneChunkCache bounds it to the payload last restored; the restore command calls
// pruneAfterRestore after a COMPLETE CDC restore. These tests pin the bound, the partial-restore guard, the
// names the pruner may touch, and that the next restore of the same payload is served entirely from cache.

func cacheNames(t *testing.T, dir string) map[string]bool {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, e := range ents {
		got[e.Name()] = true
	}
	return got
}

// restoreCached restores m from base through a cache in dir and returns the (hits, misses) of that restore.
func restoreCached(t *testing.T, base string, key []byte, m chunkManifest, dir string) (int64, int64) {
	t.Helper()
	oc := chunkCacheDir
	chunkCacheDir = dir
	t.Cleanup(func() { chunkCacheDir = oc })
	atomic.StoreInt64(&chunkHits, 0)
	atomic.StoreInt64(&chunkMiss, 0)
	if sk := cdcRestore(base, key, m, t.TempDir()); sk != 0 {
		t.Fatalf("restore skipped %d entries", sk)
	}
	return atomic.LoadInt64(&chunkHits), atomic.LoadInt64(&chunkMiss)
}

// (a) a cache holding the chunks of two payloads is cut to the second's after its complete restore, and every
// remaining entry still verifies; (e) restoring the same payload again then fetches nothing.
func TestCompleteRestorePrunesCacheToThatPayload(t *testing.T) {
	baseA, keyA, mA := sealedForCut(t, "prunea", "prune a horse battery staple")
	baseB, keyB, mB := sealedForCut(t, "pruneb", "prune b horse battery staple")
	dir := filepath.Join(t.TempDir(), "otacache")
	restoreCached(t, baseA, keyA, mA, dir)
	restoreCached(t, baseB, keyB, mB, dir)
	if got := len(cacheNames(t, dir)); got <= len(mB.Chunks) {
		t.Fatalf("fixture: the cache holds %d entries, want the union of two payloads (> %d)", got, len(mB.Chunks))
	}
	pruneAfterRestore(dir, 0, mB)
	want := map[string]bool{}
	for _, h := range mB.Chunks {
		want[h] = true
	}
	got := cacheNames(t, dir)
	if len(got) != len(want) {
		t.Fatalf("cache holds %d entries after the prune, want exactly the second payload's %d", len(got), len(want))
	}
	for h := range got {
		if !want[h] {
			t.Errorf("chunk %s of the OLD payload survived the prune", h)
		}
	}
	for h := range want {
		if _, ok := cacheRead(dir, h); !ok {
			t.Errorf("chunk %s of the restored payload no longer reads back verified", h)
		}
	}
	hits, miss := restoreCached(t, baseB, keyB, mB, dir)
	if miss != 0 || hits != int64(len(mB.Chunks)) {
		t.Errorf("second restore of the same payload: %d cached, %d fetched; want %d cached, 0 fetched", hits, miss, len(mB.Chunks))
	}
}

// (b) a restore that skipped entries is partial: the retry needs every chunk, so nothing is pruned.
func TestPartialRestorePrunesNothing(t *testing.T) {
	baseA, keyA, mA := sealedForCut(t, "pprunea", "partial a horse battery staple")
	baseB, keyB, mB := sealedForCut(t, "pprunec", "partial c horse battery staple")
	dir := filepath.Join(t.TempDir(), "otacache")
	restoreCached(t, baseA, keyA, mA, dir)
	restoreCached(t, baseB, keyB, mB, dir)
	before := len(cacheNames(t, dir))
	pruneAfterRestore(dir, 1, mB)
	if after := len(cacheNames(t, dir)); after != before {
		t.Errorf("a restore with skipped > 0 pruned the cache: %d entries -> %d", before, after)
	}
}

// (c) only 64-hex names outside keep and hour-old .tmp-* files go; everything else survives.
func TestPruneTouchesOnlyCacheShapedFiles(t *testing.T) {
	dir := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("not the cache's"), 0o600); err != nil {
		t.Fatal(err)
	}
	hexA := strings.Repeat("a", 64)
	hexB := strings.Repeat("b", 64)
	write := func(n string) string {
		p := filepath.Join(dir, n)
		if err := os.WriteFile(p, []byte(n), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	write(hexA)
	write(hexB)
	write("notes.txt")
	write(strings.Repeat("A", 64)) // upper-case hex is not a name cacheWrite produces
	write(strings.Repeat("a", 63))
	write(".tmp-fresh")
	old := write(".tmp-old")
	past := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(old, past, past); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, strings.Repeat("c", 64)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, strings.Repeat("d", 64))); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, ".tmp-link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(dir, ".tmp-link"), past, past); err != nil {
		// a symlink's own mtime is not essential; the entry must survive either way
		t.Log(err)
	}
	removed, err := pruneChunkCache(dir, map[string]bool{hexA: true})
	if err != nil {
		t.Fatal(err)
	}
	if removed != 2 {
		t.Errorf("removed %d files, want 2 (the unkept hash and the hour-old temp)", removed)
	}
	got := cacheNames(t, dir)
	for _, n := range []string{hexA, "notes.txt", strings.Repeat("A", 64), strings.Repeat("a", 63), ".tmp-fresh",
		strings.Repeat("c", 64), strings.Repeat("d", 64), ".tmp-link"} {
		if !got[n] {
			t.Errorf("%s was removed", n)
		}
	}
	if got[hexB] || got[".tmp-old"] {
		t.Errorf("an unkept chunk or a stale temp file survived: %v", got)
	}
	if b, err := os.ReadFile(outside); err != nil || string(b) != "not the cache's" {
		t.Errorf("the file a symlink pointed at was touched: %q, %v", b, err)
	}
}

// (d) with no cache dir nothing is pruned, and the restore command reaches the prune only through
// pruneAfterRestore with the cache dir and the restore's skipped count.
func TestNoCacheDirNeverPrunes(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	if !strings.Contains(s, "pruneAfterRestore(chunkCacheDir, skipped, m)") {
		t.Error("the restore command does not call pruneAfterRestore(chunkCacheDir, skipped, m)")
	}
	if strings.Count(s, "pruneChunkCache(") != 2 { // the definition and pruneAfterRestore's one call
		t.Error("pruneChunkCache is called from somewhere other than pruneAfterRestore")
	}
	if !strings.Contains(s, "if dir == \"\" || skipped != 0 {") {
		t.Error("pruneAfterRestore lost its empty-dir / skipped guard")
	}
	// in the cwd a stray cache-shaped file must survive an empty dir argument
	t.Chdir(t.TempDir())
	stray := strings.Repeat("e", 64)
	if err := os.WriteFile(stray, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	pruneAfterRestore("", 0, chunkManifest{})
	if _, err := os.Stat(stray); err != nil {
		t.Errorf("an empty cache dir pruned the working directory: %v", err)
	}
}
