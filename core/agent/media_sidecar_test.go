package main

// NWP-20261112-23: initPart returned as soon as a .part existed at its full size, without looking at its .have
// sidecar, and markHave opens the sidecar without O_CREATE and drops the error. So a full-size part whose sidecar
// write failed (a full disk, a kill between the part and the sidecar) or was torn short had every chunk refetched on
// every read, recorded no mark, and never promoted to a complete cache entry. initPart now re-zeroes a missing or
// short sidecar, keeps a valid one, and still serves when that repair cannot be written.

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type mscEnv struct {
	srv        *mediaServer
	d          deferredFile
	rel        string
	data       []byte
	cp, pp, hp string
	fetches    *atomic.Int64 // GET /blob/<chunk> through srv's store URL
}

// newMSCEnv seals a three-plus-chunk deferred file for its own profile and builds a mediaServer on a proxy in front
// of the store that counts chunk-blob GETs (NOWHERE_CHUNK_CACHE stays unset, so every chunk fetch reaches it).
func newMSCEnv(t *testing.T, name, pass string) *mscEnv {
	t.Helper()
	preGateSeal(t)
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	direct := newHTTPStore(t)
	createVault(direct, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := prBytes(9 << 20)
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), data, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(direct, name, pass, src)
	dk := resolveDK(direct, name, pass, nil)
	m := headManifest(t, direct, dk, name, pass)
	d := m.Deferred[rel]
	if len(d.Chunks) < 3 {
		t.Fatalf("test needs >=3 chunks, got %d", len(d.Chunks))
	}
	chunks := map[string]bool{}
	for _, c := range d.Chunks {
		chunks[c] = true
	}

	u, err := url.Parse(direct)
	if err != nil {
		t.Fatal(err)
	}
	var n atomic.Int64
	proxy := httputil.NewSingleHostReverseProxy(u)
	ps := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/") && chunks[strings.TrimPrefix(r.URL.Path, "/blob/")] {
			n.Add(1)
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(ps.Close)

	srv := newMediaServer(ps.URL, dk, m, t.TempDir())
	cp := filepath.Join(srv.cacheDir, cacheKey(d))
	return &mscEnv{srv: srv, d: d, rel: rel, data: data, cp: cp, pp: cp + ".part", hp: cp + ".have", fetches: &n}
}

// read runs ensureRange over [off, off+n) and checks the returned file holds the file's bytes there.
func (e *mscEnv) read(t *testing.T, off, n int64) {
	t.Helper()
	p, err := e.srv.ensureRange(e.rel, off, n)
	if err != nil {
		t.Fatalf("ensureRange(%d, %d): %v", off, n, err)
	}
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	got := make([]byte, n)
	if _, err := f.ReadAt(got, off); err != nil {
		t.Fatalf("pread %d@%d: %v", n, off, err)
	}
	if !bytes.Equal(got, e.data[off:off+n]) {
		t.Fatalf("bytes [%d,%d) differ from the source", off, off+n)
	}
}

func (e *mscEnv) have(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(e.hp)
	if err != nil {
		t.Fatalf("sidecar: %v", err)
	}
	return b
}

// orphan leaves a full-size part with no sidecar (its write failed, or a kill landed between the two), counter reset.
func (e *mscEnv) orphan(t *testing.T) {
	t.Helper()
	if err := e.srv.initPart(e.pp, e.hp, e.d); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(e.hp); err != nil {
		t.Fatal(err)
	}
	e.fetches.Store(0)
}

// repaired is D1/D2's outcome: one read fetches chunk 0 once and records it, so the same read again fetches nothing.
func (e *mscEnv) repaired(t *testing.T) {
	t.Helper()
	off := e.d.Pz[0] / 2
	e.read(t, off, 1000)
	if got := e.fetches.Load(); got != 1 {
		t.Fatalf("first read inside chunk 0 fetched %d chunks, want 1", got)
	}
	h := e.have(t)
	if len(h) != len(e.d.Chunks) || h[0] != 1 {
		t.Fatalf("sidecar after the read: len %d (want %d), byte 0 = %v (want 1)", len(h), len(e.d.Chunks), h[:min(1, len(h))])
	}
	e.read(t, off, 1000)
	if got := e.fetches.Load(); got != 1 {
		t.Fatalf("the same read again fetched %d more chunk(s), want 0 -- the mark was not kept", got-1)
	}
}

func TestMediaSidecarMissingIsRepaired(t *testing.T) {
	e := newMSCEnv(t, "mscmissing", "sidecar missing horse staple")
	e.orphan(t)
	e.repaired(t)
}

func TestMediaSidecarShortIsRepaired(t *testing.T) {
	e := newMSCEnv(t, "mscshort", "sidecar short horse staple")
	e.orphan(t)
	if err := os.WriteFile(e.hp, []byte{0}, 0o600); err != nil {
		t.Fatal(err)
	}
	e.repaired(t)
}

func TestMediaSidecarMissingFileCompletes(t *testing.T) {
	e := newMSCEnv(t, "msccomplete", "sidecar complete horse staple")
	e.orphan(t)
	offs := e.srv.chunkOffsets(cacheKey(e.d), e.d)
	for i := range e.d.Chunks {
		if _, err := e.srv.ensureRange(e.rel, offs[i], e.d.Pz[i]); err != nil {
			t.Fatalf("ensureRange chunk %d: %v", i, err)
		}
	}
	idle := func() bool {
		e.srv.mu.Lock()
		defer e.srv.mu.Unlock()
		return len(e.srv.prefetching) == 0
	}
	whole := func() bool {
		fi, err := os.Stat(e.cp)
		return err == nil && fi.Size() == e.d.Size
	}
	deadline := time.Now().Add(10 * time.Second)
	for !(idle() && whole()) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if !whole() {
		for drain := time.Now().Add(10 * time.Second); !idle() && time.Now().Before(drain); {
			time.Sleep(50 * time.Millisecond)
		}
		_, cerr := os.Stat(e.cp)
		t.Fatalf("file never promoted after a read of every chunk: %d chunk fetches, complete entry: %v", e.fetches.Load(), cerr)
	}
	if !idle() {
		t.Fatal("a background prefetch is still running 10 s after the file promoted")
	}
	for _, p := range []string{e.pp, e.hp} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s survived the promotion (stat: %v)", filepath.Base(p), err)
		}
	}
	if got := e.fetches.Load(); got != int64(len(e.d.Chunks)) {
		t.Fatalf("%d chunk fetches for a %d-chunk file, want one each", got, len(e.d.Chunks))
	}
	b, err := os.ReadFile(e.cp)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(b, e.data) {
		t.Fatal("the promoted entry differs from the source")
	}
}

// Control: a valid sidecar is kept, so its marks stand.
func TestMediaSidecarValidIsKept(t *testing.T) {
	e := newMSCEnv(t, "msckeep", "sidecar keep horse staple")
	off := e.d.Pz[0] / 2
	e.read(t, off, 1000)
	e.fetches.Store(0)
	if err := e.srv.initPart(e.pp, e.hp, e.d); err != nil {
		t.Fatal(err)
	}
	if h := e.have(t); len(h) != len(e.d.Chunks) || h[0] != 1 {
		t.Fatalf("initPart rewrote a valid sidecar: len %d (want %d), byte 0 = %d (want 1)", len(h), len(e.d.Chunks), h[0])
	}
	e.read(t, off, 1000)
	if got := e.fetches.Load(); got != 0 {
		t.Fatalf("a read of a marked chunk fetched %d chunk(s), want 0", got)
	}
}

// Control: a repair that cannot be written (here a non-empty directory where its temp file goes) still serves.
func TestMediaSidecarFailedRepairStillServes(t *testing.T) {
	e := newMSCEnv(t, "mscfailrepair", "sidecar failrepair horse staple")
	e.orphan(t)
	tmp := e.hp + ".tmp"
	if err := os.Mkdir(tmp, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "x"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	e.read(t, e.d.Pz[0]/2, 1000)
	if _, err := os.Stat(e.hp); !os.IsNotExist(err) {
		t.Fatalf("a sidecar appeared although its repair could not be written (stat: %v)", err)
	}
	if fi, err := os.Stat(tmp); err != nil || !fi.IsDir() {
		t.Fatalf("the planted %s.tmp directory is gone (stat: %v)", filepath.Base(e.hp), err)
	}
}
