package main

// NWP-20261101-09 (#120): A REFUSED SEAL MUST NOT HAVE UPLOADED ANYTHING.
//
// The seal guards whose verdict does not need the walk -- no-receipt and the stale-base refusal -- used to
// run AFTER walkChunks had streamed the changed set to the store, so a partial restore's session (no
// receipt, sealing every 120 s) added billed orphans on every retry. They now run before the walk.
// These tests drive the real pushProfile through a recording proxy in front of the test store and assert
// the refused push made no request that writes a blob, moves a ref or touches a lease.

import (
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// recordingStore fronts a test store and remembers every request that could spend or reserve anything.
type recordingStore struct {
	mu     sync.Mutex
	URL    string
	writes []string // "METHOD path" of every POST/PUT/DELETE
	lease  []string // any request whose path names a lease
}

func newRecordingStore(t *testing.T) *recordingStore {
	t.Helper()
	inner := newHTTPStore(t)
	u, err := url.Parse(inner)
	if err != nil {
		t.Fatal(err)
	}
	rs := &recordingStore{}
	proxy := httputil.NewSingleHostReverseProxy(u)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rs.mu.Lock()
		if r.Method != "GET" && r.Method != "HEAD" {
			rs.writes = append(rs.writes, r.Method+" "+r.URL.Path)
		}
		if strings.Contains(strings.ToLower(r.URL.Path), "lease") {
			rs.lease = append(rs.lease, r.Method+" "+r.URL.Path)
		}
		rs.mu.Unlock()
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	rs.URL = srv.URL
	return rs
}

// mark forgets everything seen so far; what is recorded afterwards belongs to the push under test.
func (rs *recordingStore) mark() {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	rs.writes, rs.lease = nil, nil
}

func (rs *recordingStore) seen() (writes, lease []string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return append([]string(nil), rs.writes...), append([]string(nil), rs.lease...)
}

// assertNothingSpent fails if the push since mark() wrote a blob, moved a ref, or requested a lease.
func (rs *recordingStore) assertNothingSpent(t *testing.T, what string) {
	t.Helper()
	w, l := rs.seen()
	if len(w) != 0 {
		t.Errorf("%s: the refused push still wrote to the store (%d request(s), first %q) -- every one is a "+
			"billed orphan, repeated on every retry", what, len(w), w[0])
	}
	if len(l) != 0 {
		t.Errorf("%s: the refused push requested a lease: %v", what, l)
	}
}

func resetSealCaches() { blobCache, contentCache = nil, nil }

func writeRandom(t *testing.T, dir, rel string, n int) {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, rel), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// noReceiptSession seals once, then drops the receipt (a restore that never completed) and returns the
// second session's tree, holding a large new file.
func noReceiptSession(t *testing.T, base, name, pass string) string {
	t.Helper()
	createVault(base, name, pass)
	src := t.TempDir()
	writeRandom(t, src, "one.bin", 2<<20)
	sealRefused = false
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatal("fixture: the first seal was refused")
	}
	os.RemoveAll(restoreReceiptDir())
	src2 := t.TempDir()
	writeRandom(t, src2, "two.bin", 3<<20)
	return src2
}

func TestSealEarlyGuard_NoReceiptRefusesBeforeAnythingIsUploaded(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	resetSealCaches()
	rs := newRecordingStore(t)
	name, pass := "earlynorcpt", "early receipt horse staple"
	src2 := noReceiptSession(t, rs.URL, name, pass)

	rs.mark()
	sealRefused, sealRefusedWhy = false, ""
	pushProfile(rs.URL, name, pass, src2)
	if !sealRefused || sealRefusedWhy != "no-receipt" {
		t.Fatalf("refused=%v why=%q, want no-receipt", sealRefused, sealRefusedWhy)
	}
	rs.assertNothingSpent(t, "no-receipt")
}

func TestSealEarlyGuard_StaleBaseRefusesBeforeAnythingIsUploaded(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	resetSealCaches()
	rs := newRecordingStore(t)
	name, pass := "earlystale", "early stale horse staple"
	createVault(rs.URL, name, pass)
	a, b := newHandset(t, rs.URL, name, pass), newHandset(t, rs.URL, name, pass)

	a.put("shared.txt", "original")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	base0 := a.head("")
	b.as(func() { writeRestoreReceipt(profileRefV2(name, pass), base0) })
	a.put("shared.txt", "A's newer work")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("A's second seal: %s", msg)
	}
	if a.head("") == base0 {
		t.Fatal("setup: A's second seal did not move the head")
	}
	writeRandom(t, b.work, "big.bin", 3<<20)

	rs.mark()
	sealRefusedWhy = ""
	if b.seal("") == "" || sealRefusedWhy != "stale-base" {
		t.Fatalf("why=%q, want the stale handset refused as stale-base", sealRefusedWhy)
	}
	rs.assertNothingSpent(t, "stale-base")
}

// A profile the media carry can excuse keeps the guard AFTER the walk, where its "allowed" arm applies.
func TestSealEarlyGuard_TheCarryExcusedStaleBaseStillReachesTheWalk(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	resetSealCaches()
	a, b := twoWriters(t, "earlycarry", "correct horse battery staple")
	ref := profileRefV2("earlycarry#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, atLogin) })
	a.put("DCIM/from-a.jpg", "a small photo only A has")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}
	var msg string
	out := captureStdout(t, func() { msg = b.seal("#media") })
	if msg != "" {
		t.Fatalf("B's seal was refused (%s); the carry folds the head in, so it must be allowed:\n%s", msg, out)
	}
	if !strings.Contains(out, "STALE BASE allowed") {
		t.Errorf("the walk and the allowed arm were not reached:\n%s", out)
	}
}

func TestSealEarlyGuard_ForceBypassesBoth(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	t.Setenv("NOWHERE_SEAL_FORCE", "1")
	resetSealCaches()
	rs := newRecordingStore(t)
	name, pass := "earlyforce", "early force horse staple"
	src2 := noReceiptSession(t, rs.URL, name, pass)
	sealRefused, sealRefusedWhy = false, ""
	pushProfile(rs.URL, name, pass, src2)
	if sealRefused {
		t.Errorf("NOWHERE_SEAL_FORCE=1 did not bypass no-receipt (why=%q)", sealRefusedWhy)
	}

	a, b := newHandset(t, rs.URL, "earlyforce2", pass), newHandset(t, rs.URL, "earlyforce2", pass)
	createVault(rs.URL, "earlyforce2", pass)
	a.put("f.txt", "one")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	base0 := a.head("")
	b.as(func() { writeRestoreReceipt(profileRefV2("earlyforce2", pass), base0) })
	a.put("f.txt", "two")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("A's second seal: %s", msg)
	}
	b.put("f.txt", "three")
	if msg := b.seal(""); msg != "" {
		t.Errorf("NOWHERE_SEAL_FORCE=1 did not bypass stale-base: %s", msg)
	}
}
