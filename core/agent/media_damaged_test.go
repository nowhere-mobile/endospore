package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// corruptibleStore is newHTTPStore plus two hooks the #109 tests need: mark any blob hash CORRUPT (its GET
// then returns garbage that cannot hash to the key -- the #207 verified-read path retries and gives up), and
// count the GETs per blob so a test can prove a damaged chunk is never refetched.
type corruptibleStore struct {
	mu      sync.Mutex
	blobs   map[string][]byte
	refs    map[string]string
	corrupt map[string]bool
	gets    map[string]int
	url     string
}

func newCorruptibleStore(t *testing.T) *corruptibleStore {
	t.Helper()
	cs := &corruptibleStore{blobs: map[string][]byte{}, refs: map[string]string{}, corrupt: map[string]bool{}, gets: map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cs.mu.Lock()
		defer cs.mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			h := sha256.Sum256(body)
			key := hex.EncodeToString(h[:])
			cs.blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			key := strings.TrimPrefix(r.URL.Path, "/blob/")
			cs.gets[key]++
			if cs.corrupt[key] {
				w.Write([]byte("corrupt-bytes-that-cannot-hash-to-the-key")) // torn PUT / bit-rot
				return
			}
			if b, ok := cs.blobs[key]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			body, _ := io.ReadAll(r.Body)
			cs.refs[strings.TrimPrefix(r.URL.Path, "/ref/")] = string(body)
		case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/ref/"):
			delete(cs.refs, strings.TrimPrefix(r.URL.Path, "/ref/"))
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			if v, ok := cs.refs[strings.TrimPrefix(r.URL.Path, "/ref/")]; ok {
				io.WriteString(w, v)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	cs.url = srv.URL
	return cs
}

func (cs *corruptibleStore) getCount(h string) int {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.gets[h]
}

// clearCorrupt un-marks a blob, so a test can prove the ORIGINAL bytes are still in the store after a
// refusal -- i.e. that nothing overwrote them (#116).
func (cs *corruptibleStore) clearCorrupt(h string) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	delete(cs.corrupt, h)
}

func (cs *corruptibleStore) setCorrupt(h string) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	cs.corrupt[h] = true
}

// pushDeferredFixture seals a multi-chunk deferred media file and returns everything the #109 tests need.
func pushDeferredFixture(t *testing.T, base, name, pass string) (rel string, m chunkManifest, d deferredFile, dk []byte) {
	t.Helper()
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	rel = "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), prBytes(9<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	dk = resolveDK(base, name, pass, nil)
	m = headManifest(t, base, dk, name, pass)
	d = m.Deferred[rel]
	if len(d.Chunks) < 3 {
		t.Fatalf("test needs >=3 chunks, got %d", len(d.Chunks))
	}
	return
}

// #109 keystone: a chunk PROVEN corrupt in the store (verified-hash mismatch after getChunk's retries) is
// marked damaged STICKY -- the first read pays the store round-trips, every later read of that chunk fails
// FAST with zero store traffic (this was the "every NY search slow" refetch loop, nfctest 2026-07-05). Good
// chunks of the same file keep serving, and the DAMAGED verdict is published for the chooser (#110).
func TestCorruptChunkFailsFastAndPublishesDamaged(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	cs := newCorruptibleStore(t)
	rel, m, d, dk := pushDeferredFixture(t, cs.url, "dmgfast", "damaged horse battery staple")

	badIdx := 1
	badHash := d.Chunks[badIdx]
	cs.setCorrupt(badHash)

	srv := newMediaServer(cs.url, dk, m, t.TempDir())
	srv.progPath = filepath.Join(t.TempDir(), "media.progress")
	offs := srv.chunkOffsets(cacheKey(d), d)

	// (1) first read over the bad chunk: hits the store (getChunk retries), fails typed errDamagedChunk.
	if _, err := srv.ensureRange(rel, offs[badIdx], 10); !errors.Is(err, errDamagedChunk) {
		t.Fatalf("first read of a corrupt chunk: want errDamagedChunk, got %v", err)
	}
	first := cs.getCount(badHash)
	if first == 0 {
		t.Fatal("the first read must have actually fetched from the store")
	}

	// (2) later reads fail FAST: same typed error, ZERO additional store fetches (the #109 point).
	if _, err := srv.ensureRange(rel, offs[badIdx], 10); !errors.Is(err, errDamagedChunk) {
		t.Fatalf("second read: want errDamagedChunk, got %v", err)
	}
	if got := cs.getCount(badHash); got != first {
		t.Fatalf("a known-damaged chunk was refetched: store GETs %d -> %d", first, got)
	}

	// (3) the file's GOOD chunks still serve.
	if _, err := srv.ensureRange(rel, offs[0], 10); err != nil {
		t.Fatalf("good chunk 0 must still serve: %v", err)
	}
	if _, err := srv.ensureRange(rel, offs[2], 10); err != nil {
		t.Fatalf("good chunk 2 must still serve: %v", err)
	}

	// (4) #110: the DAMAGED verdict is published for the chooser (survives the LOADING line coming and going).
	b, err := os.ReadFile(srv.progPath)
	if err != nil {
		t.Fatalf("progress file must exist while damaged: %v", err)
	}
	if want := "DAMAGED 1 region.mwm"; !strings.Contains(string(b), want) {
		t.Fatalf("progress file %q must contain %q", string(b), want)
	}
}

// #109: a corrupt chunk discovered DURING the background prefetch is skipped -- the walk continues and warms
// every good chunk (searches over the rest of the file stay fast) instead of stopping at the bad one and
// being restarted by the next read forever.
func TestPrefetchSkipsDamagedChunkAndWarmsRest(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	cs := newCorruptibleStore(t)
	rel, m, d, dk := pushDeferredFixture(t, cs.url, "dmgpre", "prefetch horse battery staple")

	badIdx := 1
	cs.setCorrupt(d.Chunks[badIdx])

	srv := newMediaServer(cs.url, dk, m, t.TempDir())
	key := cacheKey(d)
	srv.maybePrefetch(rel, key)

	// Wait for the prefetch goroutine to finish (it deregisters itself from srv.prefetching).
	deadline := time.Now().Add(30 * time.Second)
	for {
		srv.mu.Lock()
		running := srv.prefetching[key]
		srv.mu.Unlock()
		if !running {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("prefetch did not finish")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Every chunk except the corrupt one must be present in the sidecar.
	hp := filepath.Join(srv.cacheDir, key) + ".have"
	have, err := os.ReadFile(hp)
	if err != nil {
		t.Fatalf("sidecar: %v", err)
	}
	for i := range d.Chunks {
		want := byte(1)
		if i == badIdx {
			want = 0
		}
		if have[i] != want {
			t.Fatalf("chunk %d: have=%d want=%d (prefetch must skip ONLY the damaged chunk)", i, have[i], want)
		}
	}
	if !srv.hasDamaged(key) {
		t.Fatal("the corrupt chunk must be marked damaged")
	}
	// And the file's prefetch never restarts (it can't complete) -- maybePrefetch is now a no-op.
	srv.maybePrefetch(rel, key)
	srv.mu.Lock()
	restarted := srv.prefetching[key]
	srv.mu.Unlock()
	if restarted {
		t.Fatal("maybePrefetch must not restart for a damaged file")
	}
}
