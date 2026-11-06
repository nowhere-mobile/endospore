package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// deterministic pseudo-random bytes: unique-ish per offset, so a misplaced chunk can never compare equal,
// and content-defined boundaries actually occur (~1MiB avg), unlike a short repeating pattern.
func prBytes(n int) []byte {
	b := make([]byte, n)
	x := uint32(0x12345678)
	for i := range b {
		x = x*1664525 + 1013904223
		b[i] = byte(x >> 24)
	}
	return b
}

// #84 P4: the seal must record plaintext chunk lengths (Pz) on fresh deferred entries -- parallel to Chunks,
// summing exactly to the file size. Chunks are zstd-then-sealed, so without Pz a byte offset can never be
// mapped to a chunk and the entry is stuck on whole-file-on-open.
func TestSealRecordsPz(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "pzseal", "range horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := prBytes(9 << 20) // ~9MiB of varied bytes -> several CDC chunks
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), data, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	d := headManifest(t, base, dk, name, pass).Deferred[rel]
	if len(d.Chunks) < 2 {
		t.Fatalf("test needs a multi-chunk file, got %d chunk(s)", len(d.Chunks))
	}
	if len(d.Pz) != len(d.Chunks) {
		t.Fatalf("Pz len %d != Chunks len %d", len(d.Pz), len(d.Chunks))
	}
	var sum int64
	for _, n := range d.Pz {
		if n <= 0 {
			t.Fatalf("non-positive Pz entry: %v", d.Pz)
		}
		sum += n
	}
	if sum != d.Size {
		t.Fatalf("Pz sums to %d, want Size %d", sum, d.Size)
	}
	if !d.rangeable() {
		t.Fatal("fresh entry with valid Pz must be rangeable")
	}
}

// #84 P4 keystone: a read fetches ONLY the chunk(s) covering it (sidecar proves it), bytes come back exact,
// EOF reads fetch nothing, and completing the last chunk promotes the part to the plain cache entry.
func TestRangeServesChunkGranular(t *testing.T) {
	tr := trackGoSafe(t)
	defer tr.wait(t, 10*time.Second) // a hang guard, not a bound on the job: the job ends in microseconds once the file is whole
	var srv *mediaServer
	stateDirMustStayGone(t, func() string {
		if srv == nil {
			return ""
		}
		return filepath.Dir(srv.cacheDir)
	})
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "rangesrv", "chunk horse battery staple"
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
	d := m.Deferred[rel]
	if len(d.Chunks) < 3 {
		t.Fatalf("test needs >=3 chunks, got %d", len(d.Chunks))
	}
	srv = newMediaServer(base, dk, m, t.TempDir())
	key := cacheKey(d)
	cp := filepath.Join(srv.cacheDir, key)
	pp, hp := cp+".part", cp+".have"

	countHave := func() int {
		b, err := os.ReadFile(hp)
		if err != nil {
			t.Fatalf("sidecar: %v", err)
		}
		n := 0
		for _, v := range b {
			if v == 1 {
				n++
			}
		}
		return n
	}

	// (1) a small read inside the FIRST chunk fetches exactly one chunk
	off, ln := d.Pz[0]/2, int64(1000)
	p, err := srv.ensureRange(rel, off, ln)
	if err != nil {
		t.Fatal(err)
	}
	if p != pp {
		t.Fatalf("partial state must serve the part file, got %q", p)
	}
	got := make([]byte, ln)
	f, _ := os.Open(p)
	if _, err := f.ReadAt(got, off); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if !bytes.Equal(got, data[off:off+ln]) {
		t.Fatal("range bytes mismatch")
	}
	if n := countHave(); n != 1 {
		t.Fatalf("one in-chunk read fetched %d chunks, want exactly 1", n)
	}
	if _, err := os.Stat(cp); err == nil {
		t.Fatal("complete cache entry must not exist after a partial fetch")
	}

	// (2) a read at EOF fetches nothing
	if _, err := srv.ensureRange(rel, d.Size, 4096); err != nil {
		t.Fatal(err)
	}
	if n := countHave(); n != 1 {
		t.Fatalf("EOF read changed the fetched set: %d", n)
	}

	// (3) a read spanning a chunk boundary fetches both sides
	offs := srv.chunkOffsets(key, d)
	span := offs[2] - 10 // 10 bytes before chunk 2 -> covers chunks 1 and 2
	if _, err := srv.ensureRange(rel, span, 20); err != nil {
		t.Fatal(err)
	}
	if n := countHave(); n != 3 {
		t.Fatalf("boundary-spanning read: have %d chunks, want 3 (0..2)", n)
	}

	// (4) reading everything promotes part -> complete (and the whole-file path now hits it instantly)
	if _, err := srv.ensureRange(rel, 0, d.Size); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(cp)
	if err != nil || fi.Size() != d.Size {
		t.Fatalf("promotion failed: %v size=%v", err, fi)
	}
	if _, err := os.Stat(pp); err == nil {
		t.Fatal("part file must be gone after promotion")
	}
	if _, err := os.Stat(hp); err == nil {
		t.Fatal("sidecar must be gone after promotion")
	}
	whole, err := os.ReadFile(cp)
	if err != nil || !bytes.Equal(whole, data) {
		t.Fatalf("promoted file mismatch: %d bytes err=%v", len(whole), err)
	}
}

// #84 P4b: once foreground reads fault in >= prefetchTriggerChunks chunks (a real search, not a header
// read), a background prefetch fetches the REST so the file becomes fully local -- and promotes. A single
// header-sized read (1 chunk) must NOT prefetch (quota-decoupling: don't download files barely touched).
func TestRangePrefetchesActiveFile(t *testing.T) {
	tr := trackGoSafe(t)
	defer tr.wait(t, 10*time.Second) // a hang guard, not a bound on the job: the job ends in microseconds once the file is whole
	var srv *mediaServer
	stateDirMustStayGone(t, func() string {
		if srv == nil {
			return ""
		}
		return filepath.Dir(srv.cacheDir)
	})
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "prefetch", "warm horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := prBytes(9 << 20)
	rel := "app.maps/files/maps/region.mwm"
	os.WriteFile(filepath.Join(src, rel), data, 0o644)
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	d := m.Deferred[rel]
	if len(d.Chunks) < 4 {
		t.Fatalf("need >=4 chunks, got %d", len(d.Chunks))
	}
	key := cacheKey(d)

	// (1) header read: exactly the first chunk. Must NOT trigger a prefetch.
	srv1 := newMediaServer(base, dk, m, t.TempDir())
	if _, err := srv1.ensureRange(rel, 0, 4096); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if h, _ := os.ReadFile(filepath.Join(srv1.cacheDir, key+".have")); countOnes(h) != 1 {
		t.Fatalf("header read prefetched (have=%d); must stay 1", countOnes(h))
	}

	// (2) two distinct chunks read (real use) -> background prefetch fills the whole file + promotes.
	srv = newMediaServer(base, dk, m, t.TempDir())
	offs := srv.chunkOffsets(key, d)
	srv.ensureRange(rel, offs[0], 1000)
	srv.ensureRange(rel, offs[2], 1000) // 2 distinct chunks -> crosses the trigger
	cp := filepath.Join(srv.cacheDir, key)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if fi, err := os.Stat(cp); err == nil && fi.Size() == d.Size {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	whole, err := os.ReadFile(cp)
	if err != nil || !bytes.Equal(whole, data) {
		t.Fatalf("prefetch did not complete+promote the file: %d bytes err=%v (want %d)", len(whole), err, len(data))
	}
	if _, err := os.Stat(cp + ".part"); err == nil {
		t.Fatal("part file should be gone after prefetch promotion")
	}
}

// A pre-P4 entry (no Pz -- every carried-forward record from an older head) must gate off range serving and
// fall back to whole-file-on-open through the same call.
func TestRangeLegacyFallsBackToWholeFile(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "rangelegacy", "legacy horse battery staple"
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
	d := m.Deferred[rel]
	d.Pz = nil // simulate a pre-P4 / carried-forward record
	m.Deferred[rel] = d
	if d.rangeable() {
		t.Fatal("entry without Pz must not be rangeable")
	}
	bad := d
	bad.Pz = make([]int64, len(d.Chunks)) // right length, zero values -> also not rangeable
	if bad.rangeable() {
		t.Fatal("entry with zero Pz values must not be rangeable")
	}

	srv := newMediaServer(base, dk, m, t.TempDir())
	p, err := srv.ensureRange(rel, 100, 50)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(p) != cacheKey(d) {
		t.Fatalf("legacy fallback must return the COMPLETE cache entry, got %q", p)
	}
	whole, err := os.ReadFile(p)
	if err != nil || !bytes.Equal(whole, data) {
		t.Fatalf("whole-file fallback mismatch: %d bytes err=%v", len(whole), err)
	}
}
