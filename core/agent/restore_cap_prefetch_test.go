package main

// NWP-20261128-21: cdcRestore and healDeferred ask for their read caps a batch ahead of the chunks that use them,
// after the first progress frame. Before, both asked for every cap up front, serially, before the first fetch and
// before the first frame, so a large head sat on the previous scope's 100% for ceil(n/512) /caps POSTs, and its
// caps expired before a long restore's tail used them. These tests swap the restoreCap* seams: capMode itself
// cannot be turned on here, because GATEWAY_URL would also send getChunk down the cap path.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// capAheadCall is one restoreCapPrefetch call: its keys, the progress frame at that moment and, for the heal,
// which of the watched files were on disk.
type capAheadCall struct {
	keys    []string
	frame   string
	present []bool
}

// capAheadRecorder stands in for prefetchReadCapsOK. fail(n) says whether call n reports a failed batch.
type capAheadRecorder struct {
	mu    sync.Mutex
	calls []capAheadCall
	fail  func(n int) bool
	watch []string
}

func (r *capAheadRecorder) prefetch(keys []string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	c := capAheadCall{keys: append([]string(nil), keys...), frame: capAheadFrame()}
	for _, p := range r.watch {
		_, err := os.Lstat(p)
		c.present = append(c.present, err == nil)
	}
	n := len(r.calls)
	r.calls = append(r.calls, c)
	return r.fail == nil || !r.fail(n)
}

func (r *capAheadRecorder) snapshot() []capAheadCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]capAheadCall(nil), r.calls...)
}

// capAheadFrame reads the NOWHERE_PROGRESS line ("" when there is none yet).
func capAheadFrame() string {
	b, err := os.ReadFile(os.Getenv("NOWHERE_PROGRESS"))
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(b), "\n")
}

// capAheadParse splits a frame into its done and total. The frame must be exactly "<phase> <done> <total>".
func capAheadParse(t *testing.T, frame, phase string) (int, int) {
	t.Helper()
	f := strings.Fields(frame)
	if len(f) != 3 || f[0] != phase {
		t.Fatalf("frame %q is not a %q frame of this run", frame, phase)
	}
	d, err1 := strconv.Atoi(f[1])
	n, err2 := strconv.Atoi(f[2])
	if err1 != nil || err2 != nil {
		t.Fatalf("frame %q does not parse", frame)
	}
	return d, n
}

// swapRestoreCapSeams installs rec with the given batch size, asks always, and restores the seams afterwards.
func swapRestoreCapSeams(t *testing.T, batch int, rec *capAheadRecorder) {
	t.Helper()
	ob, op, oon := restoreCapBatch, restoreCapPrefetch, restoreCapPrefetchOn
	t.Cleanup(func() { restoreCapBatch, restoreCapPrefetch, restoreCapPrefetchOn = ob, op, oon })
	restoreCapBatch = batch
	restoreCapPrefetch = rec.prefetch
	restoreCapPrefetchOn = func() bool { return true }
}

// capAheadProgress points NOWHERE_PROGRESS into the test's temp dir and clears the sticky progress globals a
// fixture push leaves (pushProfile sets progScope; a sibling test may leave progPhase), so every frame is
// exactly "<phase> <done> <total>". Call it after the fixture push.
func capAheadProgress(t *testing.T, phase string) {
	t.Helper()
	t.Setenv("NOWHERE_PROGRESS", filepath.Join(t.TempDir(), "roam.progress"))
	t.Setenv("NOWHERE_PHASE", phase)
	oldScope, _ := progScope.Load().(string)
	oldPhase, _ := progPhase.Load().(string)
	t.Cleanup(func() { progScope.Store(oldScope); progPhase.Store(oldPhase) })
	progScope.Store("")
	progPhase.Store("")
}

// sealOneBigFile seals a bare-name vault holding one 24 MiB file of seeded random bytes and returns the store,
// the key, the manifest (Sizes cleared, so the frames count chunks) and the source bytes.
func sealOneBigFile(t *testing.T, name, pass string) (string, []byte, chunkManifest, []byte) {
	t.Helper()
	oc, rb := chunkCacheDir, s3RetryBase
	chunkCacheDir, s3RetryBase = "", time.Millisecond
	t.Cleanup(func() { chunkCacheDir, s3RetryBase = oc, rb })
	base := newHTTPStore(t)
	createVault(base, name, pass)
	src := t.TempDir()
	big := make([]byte, 24<<20)
	rand.New(rand.NewSource(59)).Read(big)
	if err := os.WriteFile(filepath.Join(src, "big.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	key, mb, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("resolveKey failed after the push")
	}
	pt := unseal(key, mb)
	if !bytes.HasPrefix(pt, cdcMagic) {
		t.Fatal("head is not a CDC manifest")
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		t.Fatal(err)
	}
	if len(m.Chunks) < 9 {
		t.Fatalf("need at least 9 chunks for three batches of 4, got %d", len(m.Chunks))
	}
	m.Sizes = nil
	return base, key, m, big
}

func capAheadSameFile(t *testing.T, path string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("restored %s differs (%d vs %d bytes, %v)", filepath.Base(path), len(got), len(want), err)
	}
}

func TestCdcRestoreRequestsCapsABatchAhead(t *testing.T) {
	base, key, m, big := sealOneBigFile(t, "capahead", "capahead horse battery staple")
	const batch, phase = 4, "capaheadrestore"
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "2")
	capAheadProgress(t, phase)
	rec := &capAheadRecorder{}
	swapRestoreCapSeams(t, batch, rec)

	dest := t.TempDir()
	if skipped := cdcRestore(base, key, m, dest); skipped != 0 {
		t.Fatalf("restore skipped %d entries", skipped)
	}
	calls := rec.snapshot()
	total := len(m.Chunks)

	// (a) the calls cover m.Chunks exactly once, in order, each at most one batch, call k from chunk batch*k.
	if want := (total + batch - 1) / batch; len(calls) != want {
		t.Fatalf("%d cap calls for %d chunks, want %d (one per batch of %d)", len(calls), total, want, batch)
	}
	j := 0
	for k, c := range calls {
		if len(c.keys) == 0 || len(c.keys) > batch {
			t.Fatalf("call %d holds %d keys, want 1..%d", k, len(c.keys), batch)
		}
		if j != k*batch {
			t.Fatalf("call %d starts at chunk %d, want %d", k, j, k*batch)
		}
		for _, got := range c.keys {
			if want := "blob/" + m.Chunks[j]; got != want {
				t.Fatalf("call %d key for chunk %d is %q, want %q", k, j, got, want)
			}
			j++
		}
	}
	if j != total {
		t.Fatalf("the calls cover %d keys, want all %d chunks", j, total)
	}
	// (c) the first frame of THIS restore is on disk before the first request.
	if d, n := capAheadParse(t, calls[0].frame, phase); d != 0 || n != total {
		t.Fatalf("frame at call 0 is %q, want %q", calls[0].frame, fmt.Sprintf("%s 0 %d", phase, total))
	}
	// (b) with a window of 2, the launcher reaches chunk 4k only after the writer released 4k-2 tokens, and the
	// writer releases chunk j's token only after chunk j-1's frame: at least 4k-3 chunks are written.
	for k := 1; k < len(calls); k++ {
		d, _ := capAheadParse(t, calls[k].frame, phase)
		if floor := batch*k - 3; d < floor {
			t.Fatalf("call %d (chunk %d) came when %d chunks were written, want at least %d: the request ran ahead of the fetch",
				k, batch*k, d, floor)
		}
	}
	// (d) the restore is whole.
	capAheadSameFile(t, filepath.Join(dest, "big.bin"), big)
}

func TestCdcRestoreStopsAskingAfterAFailedBatch(t *testing.T) {
	base, key, m, big := sealOneBigFile(t, "capstop", "capstop horse battery staple")
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "2")
	capAheadProgress(t, "capstoprestore")
	rec := &capAheadRecorder{fail: func(n int) bool { return n == 0 }}
	swapRestoreCapSeams(t, 4, rec)

	dest := t.TempDir()
	if skipped := cdcRestore(base, key, m, dest); skipped != 0 {
		t.Fatalf("restore skipped %d entries", skipped)
	}
	if calls := rec.snapshot(); len(calls) != 1 {
		t.Fatalf("%d cap calls after a failed first batch, want exactly 1 (a failed batch stops the asking)", len(calls))
	}
	capAheadSameFile(t, filepath.Join(dest, "big.bin"), big)
}

func TestHealAsksForCapsABatchAhead(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "healcapahead", "healcapahead horse battery staple"
	createVault(base, name, pass)
	preGateSeal(t)
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "app.other"), 0o755)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential"), 0o644)
	os.MkdirAll(filepath.Join(src, "app.heal/files"), 0o755)
	var rels []string
	data := map[string][]byte{}
	for i := 1; i <= 5; i++ {
		rel := fmt.Sprintf("app.heal/files/f%d.bin", i)
		b := make([]byte, 64<<10)
		rand.New(rand.NewSource(int64(5900 + i))).Read(b)
		if err := os.WriteFile(filepath.Join(src, rel), b, 0o644); err != nil {
			t.Fatal(err)
		}
		rels = append(rels, rel)
		data[rel] = b
	}
	pushProfile(base, name, pass, src)
	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	if len(m.Deferred) != len(rels) {
		t.Fatalf("fixture: %d deferred files, want %d", len(m.Deferred), len(rels))
	}
	var want []string
	var total int64
	for _, rel := range rels {
		d, ok := m.Deferred[rel]
		if !ok || len(d.Chunks) != 1 {
			t.Fatalf("fixture: %s is not deferred with exactly one chunk (%v, %d)", rel, ok, len(d.Chunks))
		}
		want = append(want, "blob/"+d.Chunks[0])
		total += d.Size
	}
	old := healFreeBytes
	healFreeBytes = func(string) (int64, error) { return 2 << 30, nil }
	t.Cleanup(func() { healFreeBytes = old })
	t.Setenv("NOWHERE_HEAL_RESERVE", "0")
	const phase = "capaheadheal"
	capAheadProgress(t, phase)
	dest := t.TempDir()
	rec := &capAheadRecorder{}
	for _, rel := range rels {
		rec.watch = append(rec.watch, filepath.Join(dest, rel))
	}
	swapRestoreCapSeams(t, 2, rec)

	r := healDeferred(base, dk, m, dest)
	calls := rec.snapshot()
	if len(calls) != 3 {
		t.Fatalf("%d cap calls for five one-chunk files in batches of 2, want 3", len(calls))
	}
	var got []string
	for k, c := range calls {
		if len(c.keys) == 0 || len(c.keys) > 2 {
			t.Fatalf("call %d holds %d keys, want 1..2", k, len(c.keys))
		}
		got = append(got, c.keys...)
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("the calls ask for %v, want the five files' keys in rel order %v", got, want)
	}
	if d, n := capAheadParse(t, calls[0].frame, phase); d != 0 || int64(n) != total {
		t.Fatalf("frame at call 0 is %q, want %q", calls[0].frame, fmt.Sprintf("%s 0 %d", phase, total))
	}
	for k, wantOn := range map[int]int{1: 2, 2: 4} {
		for i, on := range calls[k].present {
			if on != (i < wantOn) {
				t.Fatalf("call %d: file %d on disk = %v, want files 1-%d written and file %d not: the batch ran ahead of the files before it",
					k, i+1, on, wantOn, wantOn+1)
			}
		}
	}
	if r.fetched != len(rels) {
		t.Fatalf("result %+v, want all %d files healed", r, len(rels))
	}
	for _, rel := range rels {
		capAheadSameFile(t, filepath.Join(dest, rel), data[rel])
	}
}
