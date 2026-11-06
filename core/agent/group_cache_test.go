package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261119-01 (h49 #4): the small-file group cache. A group of small files flushes at each top-level directory,
// and an unchanged group (same key, every chunk still known-present) is reused by hash with no file opened. These
// tests drive walkChunks directly with a fake store, as incremental_seal_test.go does, and refresh the caches
// through sealCacheRefresh, the helper pushProfile calls once the head commits.

const gcThreshold = 1 << 20 // the vault push's threshold (NOWHERE_CARRY_ESSENTIAL=0)

// gcReset gives a test a fresh blob cache in its own state dir and switches off every list that changes a walk.
func gcReset(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	t.Setenv("NOWHERE_DROP_LIST", "")
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
}

// gcDK is a test's own DK, so no two tests share a cache tag.
func gcDK(name string) []byte {
	dk := sha256.Sum256([]byte("gc-" + name))
	return dk[:]
}

var gcBase = time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)

// gcTree builds dirs top-level dirs d0..dN, each holding files small files under dK/f/, with fixed mtimes.
func gcTree(t *testing.T, dirs, files int) string {
	t.Helper()
	src := t.TempDir()
	for d := 0; d < dirs; d++ {
		for f := 0; f < files; f++ {
			rel := fmt.Sprintf("d%d/f/%03d.txt", d, f)
			iwrite(t, src, rel, []byte(strings.Repeat(fmt.Sprintf("dir %d file %d; ", d, f), 10+f%7)))
			mt := gcBase.Add(time.Duration(d*1000+f) * time.Second)
			if err := os.Chtimes(filepath.Join(src, rel), mt, mt); err != nil {
				t.Fatal(err)
			}
		}
		for _, rel := range []string{fmt.Sprintf("d%d/f", d), fmt.Sprintf("d%d", d)} {
			if err := os.Chtimes(filepath.Join(src, rel), gcBase, gcBase); err != nil {
				t.Fatal(err)
			}
		}
	}
	return src
}

// gcCountOpens counts sealOpenFile calls per top-level dir of src.
func gcCountOpens(t *testing.T, src string) func() map[string]int {
	t.Helper()
	var mu sync.Mutex
	counts := map[string]int{}
	old := sealOpenFile
	sealOpenFile = func(p string) (*os.File, error) {
		if rel, err := filepath.Rel(src, p); err == nil {
			mu.Lock()
			counts[strings.SplitN(filepath.ToSlash(rel), "/", 2)[0]]++
			mu.Unlock()
		}
		return old(p)
	}
	t.Cleanup(func() { sealOpenFile = old })
	return func() map[string]int {
		mu.Lock()
		defer mu.Unlock()
		c := map[string]int{}
		for k, v := range counts {
			c[k] = v
		}
		return c
	}
}

type gcOut struct {
	order  []string // every emitted hash, emitSeal and emitCached, in order
	ranges []scanRange
	seen   map[string]bool
}

// gcWalk runs one walk; emitSeal stores the plaintext in store and marks the chunk known, as a real upload does.
func gcWalk(t *testing.T, src string, sc *fileScanCache, store map[string][]byte, forceFull bool) gcOut {
	t.Helper()
	var o gcOut
	emitSeal := func(c []byte) int {
		h := chunkHash(c)
		store[h] = append([]byte(nil), c...)
		blobCacheAdd(h)
		o.order = append(o.order, h)
		return len(o.order) - 1
	}
	emitCached := func(h string) int {
		o.order = append(o.order, h)
		return len(o.order) - 1
	}
	o.ranges, o.seen, _, _, _, _, _, _ = walkChunks(src, sc, gcThreshold, forceFull, false, nil, nil, nil, nil, 0, emitSeal, emitCached, func(int64) {}, nil)
	return o
}

// gcRefresh is pushProfile's refresh after the head commits.
func gcRefresh(sc *fileScanCache, o gcOut) {
	results := map[int]string{}
	for i, h := range o.order {
		results[i] = h
	}
	sealCacheRefresh(sc, o.ranges, o.seen, results)
}

// gcDirKeys computes each top-level dir's group key as the walk does, for a tree of small files only.
func gcDirKeys(t *testing.T, src string) map[string]string {
	t.Helper()
	groups := map[string][]walkEnt{}
	filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			t.Fatal(err)
		}
		rel, _ := filepath.Rel(src, p)
		if rel == "." {
			return nil
		}
		top := strings.SplitN(filepath.ToSlash(rel), "/", 2)[0]
		groups[top] = append(groups[top], walkEnt{p, rel, info})
		return nil
	})
	keys := map[string]string{}
	for top, g := range groups {
		keys[top] = groupCacheKey(g)
	}
	return keys
}

// gcFirstWalk runs the first walk and the refresh, and returns the walk's output.
func gcFirstWalk(t *testing.T, src string, dk []byte, store map[string][]byte) gcOut {
	t.Helper()
	sc := newFileScanCache(dk)
	o := gcWalk(t, src, sc, store, false)
	if !bytes.Equal(concatChunks(store, o.order), tarBytes(t, src)) {
		t.Fatal("walk 1: the emitted chunks are not the tar of the tree")
	}
	gcRefresh(sc, o)
	return o
}

func gcWantOpens(t *testing.T, got map[string]int, want map[string]int) {
	t.Helper()
	for _, k := range []string{"d0", "d1", "d2", "d3", "d4"} {
		if got[k] != want[k] {
			t.Errorf("opens in %s = %d, want %d (all: %v)", k, got[k], want[k], got)
		}
	}
}

// G1: an unchanged tree opens no small file on the second walk and emits the same hash sequence.
func TestGroupCacheNoChangeOpensNothing(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := gcTree(t, 5, 40)
	store := map[string][]byte{}
	o1 := gcFirstWalk(t, src, dk, store)
	opens := gcCountOpens(t, src)
	o2 := gcWalk(t, src, newFileScanCache(dk), store, false)
	n := 0
	for _, v := range opens() {
		n += v
	}
	if n != 0 {
		t.Fatalf("a no-change walk opened %d small file(s), want 0: %v", n, opens())
	}
	if strings.Join(o2.order, ",") != strings.Join(o1.order, ",") {
		t.Fatalf("a no-change walk emitted a different hash sequence:\n walk 1 %v\n walk 2 %v", o1.order, o2.order)
	}
	if !bytes.Equal(concatChunks(store, o2.order), tarBytes(t, src)) {
		t.Fatal("walk 2: the reused chunks are not the tar of the tree")
	}
}

// G2: one file in d3 changed (same length, new content, new mtime): only d3's files are read.
func TestGroupCacheOneChangeRereadsOnlyItsDir(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := gcTree(t, 5, 40)
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)
	p := filepath.Join(src, "d3", "f", "007.txt")
	old, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	nb := bytes.ToUpper(old)
	if bytes.Equal(nb, old) || len(nb) != len(old) {
		t.Fatal("the test needs a same-length change")
	}
	if err := os.WriteFile(p, nb, 0o644); err != nil {
		t.Fatal(err)
	}
	mt := gcBase.Add(99 * time.Hour)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	opens := gcCountOpens(t, src)
	o2 := gcWalk(t, src, newFileScanCache(dk), store, false)
	gcWantOpens(t, opens(), map[string]int{"d3": 40})
	if !bytes.Equal(concatChunks(store, o2.order), tarBytes(t, src)) {
		t.Fatal("walk 2: the emitted chunks are not the tar of the changed tree")
	}
}

// G3: a group whose chunk is no longer known-present is read again; the others are not.
func TestGroupCacheUnknownChunkRereads(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := gcTree(t, 5, 40)
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)
	cs := newFileScanCache(dk).groups[gcDirKeys(t, src)["d2"]]
	if len(cs) == 0 {
		t.Fatal("d2's group is not in the saved group cache")
	}
	blobCacheMu.Lock()
	delete(blobCache, cs[len(cs)-1])
	blobCacheMu.Unlock()
	opens := gcCountOpens(t, src)
	o2 := gcWalk(t, src, newFileScanCache(dk), store, false)
	gcWantOpens(t, opens(), map[string]int{"d2": 40})
	if !bytes.Equal(concatChunks(store, o2.order), tarBytes(t, src)) {
		t.Fatal("walk 2: the emitted chunks are not the tar of the tree")
	}
}

// G4: forceFull reads every small file, as it re-reads every large one.
func TestGroupCacheForceFullReadsAll(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := gcTree(t, 5, 40)
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)
	opens := gcCountOpens(t, src)
	gcWalk(t, src, newFileScanCache(dk), store, true)
	gcWantOpens(t, opens(), map[string]int{"d0": 40, "d1": 40, "d2": 40, "d3": 40, "d4": 40})
}

// G5: a member changed while it was read -> its group is not cached, and the next walk reads it again.
func TestGroupCacheTornGroupNotCached(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := gcTree(t, 5, 40)
	target := filepath.Join(src, "d1", "f", "005.txt")
	orig, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Lstat(target)
	if err != nil {
		t.Fatal(err)
	}
	origMt := fi.ModTime()
	keys := gcDirKeys(t, src)
	old := sealAfterGroupedRead
	t.Cleanup(func() { sealAfterGroupedRead = old })
	fired := false
	sealAfterGroupedRead = func(p string) {
		if p == target && !fired {
			fired = true
			if err := os.WriteFile(target, append([]byte("TORN "), orig...), 0o644); err != nil {
				panic(err)
			}
		}
	}
	store := map[string][]byte{}
	sc := newFileScanCache(dk)
	o1 := gcWalk(t, src, sc, store, false)
	if !fired {
		t.Fatal("the hook never fired")
	}
	sc.mu.Lock()
	pending := map[string]bool{}
	for _, g := range sc.gPending {
		pending[g.key] = true
	}
	sc.mu.Unlock()
	for d, k := range keys {
		if d == "d1" && pending[k] {
			t.Errorf("the torn group d1 is pending for the group cache")
		}
		if d != "d1" && !pending[k] {
			t.Errorf("the clean group %s is not pending for the group cache", d)
		}
	}
	gcRefresh(sc, o1)
	sealAfterGroupedRead = old
	if err := os.WriteFile(target, orig, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"d1/f/005.txt", "d1/f", "d1"} {
		mt := gcBase
		if rel == "d1/f/005.txt" {
			mt = origMt
		}
		if err := os.Chtimes(filepath.Join(src, rel), mt, mt); err != nil {
			t.Fatal(err)
		}
	}
	if gcDirKeys(t, src)["d1"] != keys["d1"] {
		t.Fatal("the restored d1 does not have its walk-1 key; the test premise is broken")
	}
	opens := gcCountOpens(t, src)
	o2 := gcWalk(t, src, newFileScanCache(dk), store, false)
	gcWantOpens(t, opens(), map[string]int{"d1": 40})
	if !bytes.Equal(concatChunks(store, o2.order), tarBytes(t, src)) {
		t.Fatal("walk 2: the emitted chunks are not the tar of the tree (a torn group was reused)")
	}
}

// G6: identical trees give identical group keys; a new file in d1 changes d1's key only.
func TestGroupCacheKeysFollowTopLevelDirs(t *testing.T) {
	gcReset(t)
	walkKeys := func(src, name string) []string {
		sc := newFileScanCache(gcDK(name))
		gcWalk(t, src, sc, map[string][]byte{}, false)
		sc.mu.Lock()
		defer sc.mu.Unlock()
		var ks []string
		for _, g := range sc.gPending {
			ks = append(ks, g.key)
		}
		return ks
	}
	a, b := gcTree(t, 5, 40), gcTree(t, 5, 40)
	ka, kb := walkKeys(a, t.Name()+"a"), walkKeys(b, t.Name()+"b")
	if len(ka) != 5 {
		t.Fatalf("a tree of 5 top-level dirs gave %d group(s), want 5", len(ka))
	}
	if strings.Join(ka, ",") != strings.Join(kb, ",") {
		t.Fatalf("identical trees gave different keys:\n %v\n %v", ka, kb)
	}
	iwrite(t, b, "d1/f/new.txt", []byte("a new file in d1"))
	kc := walkKeys(b, t.Name()+"c")
	if len(kc) != 5 {
		t.Fatalf("after the new file: %d group(s), want 5", len(kc))
	}
	for i := range ka {
		if (i == 1) == (ka[i] == kc[i]) {
			t.Errorf("group %d: key changed = %v, want %v", i, ka[i] != kc[i], i == 1)
		}
	}
}

// gcDispatchJudge returns the sealChunkDispatchHook both progress-denominator tests install. A dispatch is bad when it
// sees this push's own stored total; total is the *atomic.Int64 sealProgTotalHook handed this push. The hook needs no
// walk-end signal: every sealChunk of the incremental arm runs synchronously inside walkChunks (emitSeal from a
// cdcSplit callback in flushGroup, in the per-file split and in the footer), and pushProfile runs
// totalBytes.Store(sealStats.bytes) only after walkChunks returns, so a correct push never dispatches a chunk that
// sees its own total. It does not read $NOWHERE_PROGRESS: that file has other writers (push 1's unjoined ticker beat,
// cdcRestore's ordered writer), so a frame there says nothing about this push (NWP-20261123-15).
func gcDispatchJudge(total **atomic.Int64, dispatched, bad, badTotal *atomic.Int64) func() {
	return func() {
		dispatched.Add(1)
		if tv := (*total).Load(); tv != 0 {
			if bad.Add(1) == 1 {
				badTotal.Store(tv)
			}
		}
	}
}

// G7: the progress denominator. (a) the frame the ticker writes: with no total yet a unit-less "sizes 0 <beat>"
// that changes every beat and claims no total, then writeProg's own frame once the total is stored; (b) pushProfile
// does no pre-walk in the incremental arm: the stored total is 0 at every chunk dispatch (every dispatch runs inside
// walkChunks), and the total is st.bytes after the walk. A second push of the same tree opens no file.
func TestGroupCacheProgressDenominator(t *testing.T) {
	prog := filepath.Join(t.TempDir(), "roam.progress")
	t.Setenv("NOWHERE_PROGRESS", prog)
	t.Setenv("NOWHERE_PHASE", "")
	oldScope, _ := progScope.Load().(string)
	oldPhase, _ := progPhase.Load().(string)
	t.Cleanup(func() { progScope.Store(oldScope); progPhase.Store(oldPhase) })
	progScope.Store("")
	progPhase.Store("")
	frame := func() string {
		b, err := os.ReadFile(prog)
		if err != nil {
			return ""
		}
		return strings.TrimRight(string(b), "\n")
	}
	for _, c := range []struct {
		done, total, beat int64
		want              string
	}{
		{5, 0, 1, "sizes 0 1"},
		{7, 0, 2, "sizes 0 2"},
		{7, 9, 3, "data 7 9"},
	} {
		writeSealProg(c.done, c.total, c.beat)
		if got := frame(); got != c.want {
			t.Fatalf("writeSealProg(%d, %d, %d) wrote %q, want %q", c.done, c.total, c.beat, got, c.want)
		}
	}
	os.Remove(prog)
	blobCache = nil
	contentCache = nil
	contentCacheLoadedTag = ""
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "0")
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	t.Setenv("NOWHERE_DROP_LIST", "")
	base := newHTTPStore(t)
	name, pass := "gcprogden", "group cache progress denominator staple"
	createVault(base, name, pass)
	src := gcTree(t, 5, 10)
	var want int64
	filepath.Walk(src, func(p string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			want += fi.Size()
		}
		return nil
	})
	var total *atomic.Int64
	sealProgTotalHook = func(tot *atomic.Int64) { total = tot }
	t.Cleanup(func() { sealProgTotalHook = nil })
	var dispatched, bad, badTotal atomic.Int64
	oldHook := sealChunkDispatchHook
	t.Cleanup(func() { sealChunkDispatchHook = oldHook })
	sealChunkDispatchHook = gcDispatchJudge(&total, &dispatched, &bad, &badTotal)
	pushProfile(base, name, pass, src)
	if dispatched.Load() == 0 {
		t.Fatal("push 1 dispatched no chunk")
	}
	if bad.Load() != 0 {
		t.Fatalf("push 1: %d dispatch(es) saw a total during the walk (first: total=%d)", bad.Load(), badTotal.Load())
	}
	if total.Load() != want {
		t.Fatalf("push 1: total after the walk = %d, want st.bytes %d", total.Load(), want)
	}
	// The test store's postBlob does not mark a blob known; a restore seeds the blob cache from the head, as the
	// login restore does on a device.
	restoreManifest(t, base, name, pass)
	os.Remove(prog)
	opens := gcCountOpens(t, src)
	pushProfile(base, name, pass, src)
	n := 0
	for _, v := range opens() {
		n += v
	}
	if n != 0 {
		t.Fatalf("push 2 of an unchanged tree opened %d small file(s), want 0: %v", n, opens())
	}
	if bad.Load() != 0 || total.Load() != want {
		t.Fatalf("push 2: bad=%d total=%d, want 0 and %d (first: total=%d)", bad.Load(), total.Load(), want, badTotal.Load())
	}
}

// TestGroupCacheProgressDenominatorIgnoresAForeignFrame pins that the dispatch judgement reads only its own push's
// stored total. Another writer's frame in the shared progress file -- here planted before every judgement, in the
// shape push 1's last ticker beat leaves ("data 8680 8680") -- is not a defect of this push (NWP-20261123-15).
func TestGroupCacheProgressDenominatorIgnoresAForeignFrame(t *testing.T) {
	prog := filepath.Join(t.TempDir(), "roam.progress")
	t.Setenv("NOWHERE_PROGRESS", prog)
	t.Setenv("NOWHERE_PHASE", "")
	oldScope, _ := progScope.Load().(string)
	oldPhase, _ := progPhase.Load().(string)
	t.Cleanup(func() { progScope.Store(oldScope); progPhase.Store(oldPhase) })
	progScope.Store("")
	progPhase.Store("")
	blobCache = nil
	contentCache = nil
	contentCacheLoadedTag = ""
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "0")
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	t.Setenv("NOWHERE_DROP_LIST", "")
	base := newHTTPStore(t)
	name, pass := "gcforeignframe", "group cache foreign frame staple"
	createVault(base, name, pass)
	src := gcTree(t, 5, 10)
	var want int64
	filepath.Walk(src, func(p string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			want += fi.Size()
		}
		return nil
	})
	var total *atomic.Int64
	sealProgTotalHook = func(tot *atomic.Int64) { total = tot }
	t.Cleanup(func() { sealProgTotalHook = nil })
	var dispatched, bad, badTotal atomic.Int64
	judge := gcDispatchJudge(&total, &dispatched, &bad, &badTotal)
	oldHook := sealChunkDispatchHook
	t.Cleanup(func() { sealChunkDispatchHook = oldHook })
	sealChunkDispatchHook = func() {
		if err := os.WriteFile(prog, []byte("data 8680 8680\n"), 0o600); err != nil {
			t.Fatalf("plant the foreign frame: %v", err)
		}
		judge()
	}
	pushProfile(base, name, pass, src)
	if dispatched.Load() == 0 {
		t.Fatal("the push dispatched no chunk")
	}
	if bad.Load() != 0 {
		t.Fatalf("%d dispatch(es) judged bad with a foreign frame in the progress file (first: total=%d)", bad.Load(), badTotal.Load())
	}
	if total.Load() != want {
		t.Fatalf("total after the walk = %d, want the walk's regular-file bytes %d", total.Load(), want)
	}
}
