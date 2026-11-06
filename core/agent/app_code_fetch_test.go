package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261011-01: restoreAppCode fetches an on-demand app's APK set the way the login restore fetches a scope --
// read caps batched up front, downloadWorkers() chunks in flight, written in order, every chunk verified.

// odSeedBytes is prBytes with a per-file seed, so two files of one set never share chunks (prBytes alone would
// make a 1 MiB split the first chunk of a 10 MiB base, and dedup would blur which file a chunk belongs to).
func odSeedBytes(n int, seed uint32) []byte {
	b := make([]byte, n)
	x := seed*2654435761 + 0x12345678
	for i := range b {
		x = x*1664525 + 1013904223
		b[i] = byte(x >> 24)
	}
	return b
}

type odFetchFixture struct {
	base, name, pass string
	files            map[string][]byte // rel under the package -> bytes
	chunks           []string          // the set's chunks in fetch order (sorted rels, then each file's chunks)
	other            []string          // the OTHER on-demand package's chunks, which must never be fetched
}

// odFetchSetup seals a #apps scope holding two on-demand packages: com.big (a multi-chunk base + a split) and
// com.other. Store and seal mirror TestOnDemandAppDefersAndSelectiveFetch.
func odFetchSetup(t *testing.T, base string) odFetchFixture {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	f := odFetchFixture{base: base, name: "odfetch", pass: "materialise horse battery staple",
		files: map[string][]byte{"base.apk": odSeedBytes(10<<20, 1), "split_config.apk": odSeedBytes(2<<20, 2)}}
	createVault(base, f.name, f.pass)
	src := t.TempDir()
	for _, d := range []string{"com.big/_meta", "com.other/_meta"} {
		if err := os.MkdirAll(filepath.Join(src, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(p string, b []byte) {
		if err := os.WriteFile(filepath.Join(src, p), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for rel, b := range f.files {
		write("com.big/"+rel, b)
	}
	write("com.other/base.apk", odSeedBytes(3<<20, 3))
	write("com.big/_meta/meta", []byte("vc\t1\n"))
	write("com.other/_meta/meta", []byte("vc\t1\n"))
	write("manifest.tsv", []byte("com.big\t1\t1\tondemand\tbase.apk\tsplit_config.apk\ncom.other\t1\t1\tondemand\tbase.apk\n"))
	deferPath := filepath.Join(t.TempDir(), "defer")
	if err := os.WriteFile(deferPath, []byte("com.big/base.apk\ncom.big/split_config.apk\ncom.other/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)
	pushProfile(base, f.name+"#apps", f.pass, src)

	key, mb, ok := resolveKey(base, f.name+"#apps", f.pass)
	if !ok {
		t.Fatal("no #apps head after push")
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatal(err)
	}
	rels := []string{"com.big/base.apk", "com.big/split_config.apk"}
	for _, rel := range rels {
		d, ok := m.Deferred[rel]
		if !ok {
			t.Fatalf("%s not deferred; the fixture is wrong", rel)
		}
		f.chunks = append(f.chunks, d.Chunks...)
	}
	f.other = m.Deferred["com.other/base.apk"].Chunks
	if len(f.chunks) < 8 || len(m.Deferred["com.big/split_config.apk"].Chunks) < 1 {
		t.Fatalf("fixture has %d chunks; the concurrency tests need at least 8", len(f.chunks))
	}
	return f
}

// check asserts the materialised set is byte-for-byte the sealed one.
func (f odFetchFixture) check(t *testing.T, dest string, n int, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("restoreAppCode: %v", err)
	}
	if n != len(f.files) {
		t.Fatalf("materialised %d files, want %d", n, len(f.files))
	}
	for rel, want := range f.files {
		got, rerr := os.ReadFile(filepath.Join(dest, "com.big", rel))
		if rerr != nil || !bytes.Equal(got, want) {
			t.Fatalf("com.big/%s did not materialise byte-for-byte (err=%v, %d bytes, want %d)", rel, rerr, len(got), len(want))
		}
	}
}

// swapFetch replaces the chunk-fetch seam for one test.
func swapFetch(t *testing.T, fn func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error)) {
	t.Helper()
	old := healFetchChunk
	healFetchChunk = func(base string, key []byte, v int, h string) ([]byte, error) { return fn(old, base, key, v, h) }
	t.Cleanup(func() { healFetchChunk = old })
}

// Bounded AND concurrent: with NOWHERE_DOWNLOAD_WORKERS=3, exactly three chunks are ever in flight. A serial
// fetch peaks at 1; an unbounded one at the set's whole chunk count.
func TestRestoreAppCodeFetchIsConcurrentAndBounded(t *testing.T) {
	f := odFetchSetup(t, newHTTPStore(t))
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "3")
	var cur, peak int32
	swapFetch(t, func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error) {
		n := atomic.AddInt32(&cur, 1)
		for {
			p := atomic.LoadInt32(&peak)
			if n <= p || atomic.CompareAndSwapInt32(&peak, p, n) {
				break
			}
		}
		time.Sleep(40 * time.Millisecond) // long enough that a free worker slot is always taken
		defer atomic.AddInt32(&cur, -1)
		return old(base, key, v, h)
	})
	dest := t.TempDir()
	n, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
	if p := atomic.LoadInt32(&peak); p != 3 {
		t.Fatalf("peak chunks in flight = %d, want exactly 3 (NOWHERE_DOWNLOAD_WORKERS): 1 is a serial fetch, "+
			"more than 3 is an unbounded one", p)
	}
}

// Order-independent: chunks that COMPLETE out of order (the first ones slowest) still assemble each file in
// manifest order. The completion order is checked too, so the test cannot pass on a fetch that never reorders.
func TestRestoreAppCodeAssemblesOutOfOrderCompletions(t *testing.T) {
	f := odFetchSetup(t, newHTTPStore(t))
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "8")
	idx := map[string]int{}
	for i, h := range f.chunks {
		idx[h] = i
	}
	var mu sync.Mutex
	var completed []int
	swapFetch(t, func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error) {
		i := idx[h]
		time.Sleep(time.Duration(8-i%8) * 15 * time.Millisecond) // within each window of 8, earlier = slower
		b, err := old(base, key, v, h)
		mu.Lock()
		completed = append(completed, i)
		mu.Unlock()
		return b, err
	})
	dest := t.TempDir()
	n, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
	if sort.IntsAreSorted(completed) {
		t.Fatalf("chunks completed in order %v; the test never exercised reordering", completed)
	}
}

// One batched read-cap request for exactly this package's chunks, made before the first chunk is fetched.
func TestRestoreAppCodeBatchesReadCaps(t *testing.T) {
	f := odFetchSetup(t, newHTTPStore(t))
	var mu sync.Mutex
	var events []string
	var batches [][]string
	old := appCodePrefetchCaps
	appCodePrefetchCaps = func(keys []string) {
		mu.Lock()
		batches = append(batches, append([]string(nil), keys...))
		events = append(events, "prefetch")
		mu.Unlock()
	}
	t.Cleanup(func() { appCodePrefetchCaps = old })
	swapFetch(t, func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error) {
		mu.Lock()
		events = append(events, "fetch")
		mu.Unlock()
		return old(base, key, v, h)
	})
	dest := t.TempDir()
	n, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
	if len(batches) != 1 {
		t.Fatalf("%d read-cap batches, want exactly 1 (one per chunk is the round trip this slice removes)", len(batches))
	}
	if events[0] != "prefetch" {
		t.Errorf("a chunk was fetched before the read caps were batched: %v", events[:3])
	}
	want := map[string]bool{}
	for _, h := range f.chunks {
		want["blob/"+h] = true
	}
	got := map[string]bool{}
	for _, k := range batches[0] {
		got[k] = true
	}
	for k := range want {
		if !got[k] {
			t.Errorf("chunk %s missing from the batch", k)
		}
	}
	for _, h := range f.other {
		if got["blob/"+h] {
			t.Errorf("the batch asked for com.other's chunk %s -- the fetch must stay selective", h)
		}
	}
	if len(got) != len(want) {
		t.Errorf("batch holds %d distinct keys, want %d", len(got), len(want))
	}
}

// corruptingStore fronts a real store and serves corrupt bytes for the first `bad` GETs of one blob (all GETs
// when bad < 0). It counts that blob's GETs.
func corruptingStore(t *testing.T, real, blob string, bad int) (string, *int32) {
	t.Helper()
	var gets int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" && r.URL.Path == "/blob/"+blob {
			n := atomic.AddInt32(&gets, 1)
			if bad < 0 || int(n) <= bad {
				w.Write([]byte("torn-or-rotten-bytes"))
				return
			}
		}
		req, _ := http.NewRequest(r.Method, real+r.URL.Path, r.Body)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &gets
}

// odNoChunkCache sends every fetch to the store and shrinks the retry backoff. A failed materialise returns
// while fetches it already started are still retrying (the CLI exits at once on device), so the restore of the
// globals waits for them: cleanups run last-registered first.
func odNoChunkCache(t *testing.T) {
	t.Helper()
	oc, rb := chunkCacheDir, s3RetryBase
	chunkCacheDir, s3RetryBase = "", time.Millisecond
	t.Cleanup(func() { chunkCacheDir, s3RetryBase = oc, rb })
	var wg sync.WaitGroup
	swapFetch(t, func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error) {
		wg.Add(1)
		defer wg.Done()
		return old(base, key, v, h)
	})
	t.Cleanup(wg.Wait)
}

// A chunk the store serves corrupt once is re-fetched ALONE and the set still materialises -- getChunk's
// verify-and-retry (#207) runs inside the concurrent window.
func TestRestoreAppCodeRetriesACorruptChunk(t *testing.T) {
	odNoChunkCache(t)
	real := newHTTPStore(t)
	f := odFetchSetup(t, real)
	victim := f.chunks[len(f.chunks)/2]
	base, gets := corruptingStore(t, real, victim, 1)
	dest := t.TempDir()
	n, err := restoreAppCode(base, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
	if g := atomic.LoadInt32(gets); g != 2 {
		t.Errorf("the corrupt chunk was fetched %d times, want 2 (one corrupt, one good)", g)
	}
}

// A chunk that is corrupt on every fetch fails the materialise as an ERROR naming the integrity failure -- the
// fetch goroutine's panic must not escape -- and nothing reports success.
func TestRestoreAppCodeFailsOnAPersistentlyCorruptChunk(t *testing.T) {
	odNoChunkCache(t)
	real := newHTTPStore(t)
	f := odFetchSetup(t, real)
	base, _ := corruptingStore(t, real, f.chunks[1], -1)
	n, err := restoreAppCode(base, f.name+"#apps", f.pass, "com.big", t.TempDir())
	if err == nil {
		t.Fatalf("a persistently corrupt chunk materialised (%d files) -- verify-on-read is not running", n)
	}
	if !strings.Contains(err.Error(), "corrupt chunk") {
		t.Errorf("error %q does not name the integrity failure", err)
	}
	if n == len(f.files) {
		t.Errorf("reported %d whole files after a failed chunk", n)
	}
}

// apkSetWriter splits one in-order chunk stream back into the set's files, including a file with no chunks,
// and refuses a stream that does not fit the manifest.
func TestApkSetWriterSplitsTheStream(t *testing.T) {
	dir := t.TempDir()
	mk := func(sizes ...int) []apkPart {
		var ps []apkPart
		for i, n := range sizes {
			d := deferredFile{Chunks: make([]string, n)}
			d.Size = int64(n * 3)
			rel := "p/" + string(rune('a'+i))
			ps = append(ps, apkPart{rel: rel, d: d, out: filepath.Join(dir, string(rune('a'+i)))})
		}
		return ps
	}
	// An empty file between two others is written by write(); one after the last chunk only by finish().
	w := &apkSetWriter{parts: mk(2, 0, 1, 0), i: -1}
	for _, c := range []string{"AAA", "aaa", "CCC"} {
		if err := w.write([]byte(c)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.finish(); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"a": "AAAaaa", "b": "", "c": "CCC", "d": ""} {
		if got, err := os.ReadFile(filepath.Join(dir, name)); err != nil || string(got) != want {
			t.Errorf("file %s = %q (err %v), want %q", name, got, err, want)
		}
	}
	if w.done != 4 {
		t.Errorf("done = %d, want 4", w.done)
	}

	over := &apkSetWriter{parts: mk(1), i: -1}
	over.write([]byte("XXX"))
	if err := over.write([]byte("YYY")); err == nil || !strings.Contains(err.Error(), "more chunks than") {
		t.Errorf("a chunk beyond the set's last file returned %v, want the more-chunks refusal", err)
	}
	over.abort()

	short := &apkSetWriter{parts: mk(2), i: -1}
	short.write([]byte("XXX"))
	// Asserted by KIND: the size check would also refuse this file, so a bare err != nil could not tell
	// whether finish's own owed-chunk check exists.
	if err := short.finish(); err == nil || !strings.Contains(err.Error(), "never arrived") {
		t.Errorf("a file owed a chunk finished with %v, want the owed-chunk refusal", err)
	}
	short.abort()

	wrong := &apkSetWriter{parts: mk(1), i: -1}
	wrong.write([]byte("XX")) // 2 bytes where the manifest says 3
	if err := wrong.finish(); err == nil || !strings.Contains(err.Error(), "size mismatch") {
		t.Errorf("a short reassembly finished with %v, want a size mismatch", err)
	}
}
