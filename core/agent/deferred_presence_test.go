package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// h51 #2 (NWP-20261207-02): the restore lists a head's deferred chunks instead of seeding them, the late sign-in
// step and the seal ask the store about each, and a seal refuses while one the stored head names is missing.

// presenceReset clears the process-wide caches and seal verdict, so a test reads its own store.
func presenceReset(t *testing.T) {
	t.Helper()
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCache = nil
	sealRefused = false
	sealRefusedWhy = ""
}

// stubPresenceProbe replaces the store probe with answer for the test, and records every hash it is asked about.
func stubPresenceProbe(t *testing.T, answer func(h string) (bool, error)) *presenceAsked {
	t.Helper()
	old := deferredChunkProbe
	asked := &presenceAsked{m: map[string]int{}}
	deferredChunkProbe = func(base, h string) (bool, error) {
		asked.mu.Lock()
		asked.m[h]++
		asked.mu.Unlock()
		return answer(h)
	}
	t.Cleanup(func() { deferredChunkProbe = old })
	return asked
}

type presenceAsked struct {
	mu sync.Mutex
	m  map[string]int
}

func (a *presenceAsked) count(h string) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.m[h]
}

// presenceSealEnv is a deferring vault profile on a plain HTTP store with a state dir, pushed once, so the next push
// meets a stored head with deferred chunks and holds the restore receipt the first push wrote.
func presenceSealEnv(t *testing.T, name, pass string) (base, state, src string, d deferredFile) {
	t.Helper()
	preGateSeal(t)
	state = healTestEnv(t)
	presenceReset(t)
	base = newHTTPStore(t)
	createVault(base, name, pass)
	src = t.TempDir()
	rel := filepath.Join("app.maps", "files", "maps", "region.mwm")
	if err := os.MkdirAll(filepath.Dir(filepath.Join(src, rel)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, rel), bytes.Repeat([]byte("PRESENCE-MAP-BYTES--"), 5000), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "app.maps", "note.txt"), []byte("essential"), 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatalf("first push refused (%s)", sealRefusedWhy)
	}
	dk := resolveDK(base, name, pass, nil)
	d, ok := headManifest(t, base, dk, name, pass).Deferred[rel]
	if !ok || len(d.Chunks) == 0 {
		t.Fatal("first push: the map file was not deferred")
	}
	return base, state, src, d
}

func presenceHeadRef(base, name, pass string) string { return getRef(base, headKey(base, name, pass)) }

// presenceTouch changes an essential file, so a push that lands moves the head.
func presenceTouch(t *testing.T, src, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(src, "app.maps", "note.txt"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readPendingT(t *testing.T, path string) (map[string]bool, bool) {
	t.Helper()
	set, exists, err := readDeferredPending(path)
	if err != nil {
		t.Fatal(err)
	}
	return set, exists
}

func TestRestoreListsDeferredDoesNotSeed(t *testing.T) {
	preGateSeal(t)
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	presenceReset(t)
	base := newHTTPStore(t)
	name, pass := "dp-lists", "lists horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	rel := filepath.Join("app.maps", "files", "maps", "region.mwm")
	os.MkdirAll(filepath.Dir(filepath.Join(src, rel)), 0o755)
	os.WriteFile(filepath.Join(src, rel), bytes.Repeat([]byte("LISTED-MAP-BYTES----"), 5000), 0o644)
	os.WriteFile(filepath.Join(src, "app.maps", "note.txt"), []byte("essential"), 0o644)
	pushProfile(base, name, pass, src)

	presenceReset(t)
	m, _ := restoreManifest(t, base, name, pass)
	if len(m.Deferred) == 0 {
		t.Fatal("the head has no deferred entry")
	}
	var want []string
	seen := map[string]bool{}
	for _, d := range m.Deferred {
		for _, h := range d.Chunks {
			if blobCacheKnown(h) {
				t.Fatal("the restore marked a deferred chunk as stored before anything asked the store (h51 #2)")
			}
			if !seen[h] {
				seen[h] = true
				want = append(want, h)
			}
		}
	}
	for _, h := range m.Chunks {
		if !blobCacheKnown(h) {
			t.Fatal("the restore no longer seeds the essential chunks it fetched")
		}
	}
	state := t.TempDir()
	if err := writeDeferredPending(state, name, pass, m); err != nil {
		t.Fatal(err)
	}
	sort.Strings(want)
	b, err := os.ReadFile(filepath.Join(state, deferredPresenceFile(name, pass)))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(b); got != strings.Join(want, "\n")+"\n" {
		t.Fatalf("the pending list is %q, want the head's deferred hashes, sorted", got)
	}
	if fi, _ := os.Stat(filepath.Join(state, deferredPresenceFile(name, pass))); fi.Mode().Perm() != 0o600 {
		t.Fatalf("the pending list's mode is %v, want 0600", fi.Mode().Perm())
	}
	// An empty head is listed too: an empty list differs from none.
	if err := writeDeferredPending(state, name+"#de", pass, chunkManifest{}); err != nil {
		t.Fatal(err)
	}
	if set, exists := readPendingT(t, filepath.Join(state, deferredPresenceFile(name+"#de", pass))); !exists || len(set) != 0 {
		t.Fatalf("an empty head: exists=%v set=%v, want an empty list", exists, set)
	}

	// The restore case clears the list beside the heal list and lists the FULL head after restoreSkippingParked.
	src2, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src2)
	i := strings.Index(s, "\tcase \"restore\":")
	if i < 0 {
		t.Fatal("no restore case in main.go")
	}
	body := s[i:]
	if j := strings.Index(body[1:], "\n\tcase \""); j > 0 {
		body = body[:j+1]
	}
	if !strings.Contains(body, "clearDeferredPending(os.Getenv(\"NOWHERE_STATE\"), profile, pass) // h51 #2: the same rule for the deferred list\n\t\tclearHealList(os.Getenv(\"NOWHERE_STATE\"), profile, pass)") {
		t.Fatal("the restore case does not clear the deferred list beside the heal list")
	}
	k := strings.Index(body, "skipped = restoreSkippingParked(")
	w := strings.Index(body, "writeDeferredPending(os.Getenv(\"NOWHERE_STATE\"), profile, pass, m)")
	if k < 0 || w < k {
		t.Fatal("the restore case does not list the full head's deferred chunks after restoreSkippingParked")
	}
}

func TestSettleDeferredPresence(t *testing.T) {
	presenceReset(t)
	t.Setenv("NOWHERE_BLOBCACHE", "")
	state := t.TempDir()
	path := filepath.Join(state, deferredPresenceFile("dp-settle", "settle pass"))
	cache := filepath.Join(state, "blobcache.daemon")
	hp, ha, he := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	if err := writePendingSet(path, map[string]bool{hp: true, ha: true, he: true}); err != nil {
		t.Fatal(err)
	}
	stubPresenceProbe(t, func(h string) (bool, error) {
		switch h {
		case hp:
			return true, nil
		case ha:
			return false, nil
		}
		return true, errors.New("store down")
	})
	p, m, u := settleDeferredPresence("http://store.invalid", path, cache, nil, nil)
	if p != 1 || m != 1 || u != 1 {
		t.Fatalf("counts %d present, %d missing, %d unknown; want 1/1/1", p, m, u)
	}
	if b, _ := os.ReadFile(cache); string(b) != hp+"\n" {
		t.Fatalf("the blob cache file holds %q, want only the present hash", b)
	}
	set, _ := readPendingT(t, path)
	if len(set) != 2 || !set[ha] || !set[he] || set[hp] {
		t.Fatalf("the pending list keeps %v, want the missing and the unanswered hash", set)
	}

	old := deferredPresenceBudget
	deferredPresenceBudget = 0
	t.Cleanup(func() { deferredPresenceBudget = old })
	stubPresenceProbe(t, func(string) (bool, error) { return true, nil })
	if p, m, u := settleDeferredPresence("http://store.invalid", path, cache, nil, nil); p != 0 || m != 0 || u != 2 {
		t.Fatalf("budget 0: counts %d/%d/%d, want every hash unknown", p, m, u)
	}
	if set, _ := readPendingT(t, path); len(set) != 2 {
		t.Fatalf("budget 0 dropped a hash from the pending list: %v", set)
	}
}

func TestSealRefusesMissingDeferredPiece(t *testing.T) {
	name, pass := "dp-refuse", "refuse horse battery staple"
	base, state, src, d := presenceSealEnv(t, name, pass)
	dk := resolveDK(base, name, pass, nil)
	if err := writeDeferredPending(state, name, pass, headManifest(t, base, dk, name, pass)); err != nil {
		t.Fatal(err)
	}
	gone := d.Chunks[0]
	stubPresenceProbe(t, func(h string) (bool, error) { return h != gone, nil })
	head0 := presenceHeadRef(base, name, pass)
	presenceReset(t)
	presenceTouch(t, src, "changed once")
	pushProfile(base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "deferred-missing" {
		t.Fatalf("a deferred piece missing from the store: refused=%v why=%q, want deferred-missing", sealRefused, sealRefusedWhy)
	}
	if presenceHeadRef(base, name, pass) != head0 {
		t.Fatal("the refused seal moved the head")
	}

	stubPresenceProbe(t, func(h string) (bool, error) {
		if h == gone {
			return false, errors.New("store down")
		}
		return true, nil
	})
	presenceReset(t)
	pushProfile(base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "deferred-unchecked" {
		t.Fatalf("a deferred piece the store could not answer: refused=%v why=%q, want deferred-unchecked", sealRefused, sealRefusedWhy)
	}
	if presenceHeadRef(base, name, pass) != head0 {
		t.Fatal("the unchecked seal moved the head")
	}

	// The restore page re-run filled the gap: every piece is present, and the next save lands.
	stubPresenceProbe(t, func(string) (bool, error) { return true, nil })
	presenceReset(t)
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatalf("every deferred piece present: the seal still refused (%s)", sealRefusedWhy)
	}
	if presenceHeadRef(base, name, pass) == head0 {
		t.Fatal("the seal after the re-run did not move the head")
	}
	if set, exists := readPendingT(t, filepath.Join(state, deferredPresenceFile(name, pass))); !exists || len(set) != 0 {
		t.Fatalf("after the landing seal the pending list is exists=%v %v, want empty", exists, set)
	}
}

func TestSealWithoutPresenceFileChecksTheHead(t *testing.T) {
	name, pass := "dp-nofile", "nofile horse battery staple"
	base, state, src, d := presenceSealEnv(t, name, pass)
	path := filepath.Join(state, deferredPresenceFile(name, pass))
	os.Remove(path)
	gone := d.Chunks[len(d.Chunks)-1]
	stubPresenceProbe(t, func(h string) (bool, error) { return h != gone, nil })
	head0 := presenceHeadRef(base, name, pass)
	presenceReset(t)
	presenceTouch(t, src, "changed once")
	pushProfile(base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "deferred-missing" {
		t.Fatalf("no pending list and a piece missing: refused=%v why=%q, want deferred-missing", sealRefused, sealRefusedWhy)
	}
	if presenceHeadRef(base, name, pass) != head0 {
		t.Fatal("the refused seal moved the head")
	}
	if set, exists := readPendingT(t, path); !exists || !set[gone] {
		t.Fatalf("the seal did not list the head it checked: exists=%v %v", exists, set)
	}

	os.Remove(path)
	stubPresenceProbe(t, func(string) (bool, error) { return true, nil })
	presenceReset(t)
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatalf("every piece present: refused (%s)", sealRefusedWhy)
	}
	if set, exists := readPendingT(t, path); !exists || len(set) != 0 {
		t.Fatalf("after the landing seal the pending list is exists=%v %v, want present and empty", exists, set)
	}
}

func TestPendingHashNotInHeadNeverRefuses(t *testing.T) {
	name, pass := "dp-stray", "stray horse battery staple"
	base, state, src, _ := presenceSealEnv(t, name, pass)
	stray := strings.Repeat("e", 64)
	if err := writePendingSet(filepath.Join(state, deferredPresenceFile(name, pass)), map[string]bool{stray: true}); err != nil {
		t.Fatal(err)
	}
	asked := stubPresenceProbe(t, func(h string) (bool, error) { return h != stray, nil })
	presenceReset(t)
	presenceTouch(t, src, "changed once")
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatalf("a listed hash the head does not name refused the seal (%s)", sealRefusedWhy)
	}
	if asked.count(stray) != 0 {
		t.Fatal("the seal asked the store about a hash the head does not name")
	}
}

// TestSealRefusesWhenPendingListUnreadable (RF-003): the seal reads its pending list, then the settle cannot lock it.
// Nothing is probed, so the seal refuses deferred-unchecked even though an earlier sign-in left every deferred chunk
// in the blob cache. A list that is gone before the settle reads it leaves the seal's set unchecked too.
func TestSealRefusesWhenPendingListUnreadable(t *testing.T) {
	name, pass := "dp-nolock", "nolock horse battery staple"
	base, state, src, d := presenceSealEnv(t, name, pass)
	dk := resolveDK(base, name, pass, nil)
	path := filepath.Join(state, deferredPresenceFile(name, pass))
	if err := writeDeferredPending(state, name, pass, headManifest(t, base, dk, name, pass)); err != nil {
		t.Fatal(err)
	}
	os.Remove(path + ".lock")
	if err := os.Mkdir(path+".lock", 0o700); err != nil {
		t.Fatal(err)
	}
	asked := stubPresenceProbe(t, func(string) (bool, error) { return false, nil })
	head0 := presenceHeadRef(base, name, pass)
	presenceReset(t)
	for _, h := range d.Chunks {
		blobCacheAdd(h) // an earlier sign-in's belief: the carry would pass on it
	}
	presenceTouch(t, src, "changed once")
	pushProfile(base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "deferred-unchecked" {
		t.Fatalf("the pending list could not be locked: refused=%v why=%q, want deferred-unchecked", sealRefused, sealRefusedWhy)
	}
	if presenceHeadRef(base, name, pass) != head0 {
		t.Fatal("the unchecked seal moved the head")
	}
	for _, h := range d.Chunks {
		if asked.count(h) != 0 {
			t.Fatal("the store was asked although the list could not be locked: the fixture did not reach the lock failure")
		}
	}

	only := map[string]bool{d.Chunks[0]: true}
	if p, m, u := settleDeferredPresence(base, filepath.Join(state, "deferred-presence-gone"), "", only, nil); p != 0 || m != 0 || u != 1 {
		t.Fatalf("a list gone before the settle: %d/%d/%d, want 0/0/1 (unchecked)", p, m, u)
	}
}

func TestDeferredRefusalsAreRetryClass(t *testing.T) {
	for _, r := range []string{"deferred-missing", "deferred-unchecked"} {
		if refusalReasonFinal(r) {
			t.Errorf("%s is final; the restore page re-run fills the gap, so it must stay retry class", r)
		}
	}
}

func TestRoamInLateWorkSettlesPresence(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "\nfunc handleRoamIn(")
	if i < 0 {
		t.Fatal("no handleRoamIn in main.go")
	}
	fn := s[i+1:]
	if j := strings.Index(fn, "\n}\n"); j > 0 {
		fn = fn[:j]
	}
	k := strings.Index(fn, "startLateWork(dest, uid,")
	if k < 0 {
		t.Fatal("handleRoamIn does not start the late work")
	}
	call := fn[k:]
	end := strings.Index(call, "\n\t\t)\n")
	if end < 0 {
		t.Fatal("the startLateWork call has no closing line")
	}
	steps := strings.Split(call[:end], "\n\t\t\tfunc(lw *lateWork)")
	last := steps[len(steps)-1]
	if !strings.Contains(last, "if lw.mayWrite() {") ||
		!strings.Contains(last, "goSafe(\"deferred-presence\", func() {") ||
		!strings.Contains(last, "settleSignInPresence(\"s3\", lateState, lateCache, lateName, latePass, lw.mayWrite)") {
		t.Fatalf("the late work's last step does not start settleSignInPresence through goSafe:\n%s", last)
	}
}

func TestPresenceSettlesOnlyThisProfile(t *testing.T) {
	presenceReset(t)
	t.Setenv("NOWHERE_BLOBCACHE", "")
	state := t.TempDir()
	pass := "only horse battery staple"
	mine, theirs := strings.Repeat("1", 64), strings.Repeat("2", 64)
	mineP := filepath.Join(state, deferredPresenceFile("dp-mine#media", pass))
	theirsP := filepath.Join(state, deferredPresenceFile("dp-theirs#media", pass))
	writePendingSet(mineP, map[string]bool{mine: true})
	writePendingSet(theirsP, map[string]bool{theirs: true})
	before, _ := os.ReadFile(theirsP)
	asked := stubPresenceProbe(t, func(string) (bool, error) { return true, nil })
	settleSignInPresence("http://store.invalid", state, filepath.Join(state, "cache"), "dp-mine", pass, nil)
	if set, _ := readPendingT(t, mineP); len(set) != 0 {
		t.Fatalf("this profile's list was not settled: %v", set)
	}
	after, _ := os.ReadFile(theirsP)
	if !bytes.Equal(before, after) || asked.count(theirs) != 0 {
		t.Fatal("settling one profile touched another profile's pending list")
	}
	// mayWrite false stops it before the first scope.
	writePendingSet(mineP, map[string]bool{mine: true})
	settleSignInPresence("http://store.invalid", state, filepath.Join(state, "cache"), "dp-mine", pass, func() bool { return false })
	if set, _ := readPendingT(t, mineP); !set[mine] {
		t.Fatal("a refused mayWrite still settled the list")
	}
}

// RF-001: a check left over from an earlier sign-in must publish nothing into a later sign-in's list. The old check
// confirms one hash while another probe is held; then a new restore lists the head again (a new generation), or the
// old session ends. The old check's confirmation must neither clear the new list nor reach the blob cache.
func TestOldPresenceCheckDoesNotClearNewSignIn(t *testing.T) {
	for _, tc := range []struct {
		label     string
		newList   bool
		endOldRun bool
	}{
		{"a new restore replaced the list", true, false},
		{"the old session ended", false, true},
	} {
		t.Run(strings.ReplaceAll(tc.label, " ", "_"), func(t *testing.T) {
			presenceReset(t)
			t.Setenv("NOWHERE_BLOBCACHE", "")
			state := t.TempDir()
			name, pass := "dp-stale", "stale horse battery staple"
			path := filepath.Join(state, deferredPresenceFile(name+"#media", pass))
			cache := filepath.Join(state, "blobcache.daemon")
			ha, hb := strings.Repeat("d", 64), strings.Repeat("e", 64)
			m := chunkManifest{Deferred: map[string]deferredFile{"x": {Chunks: []string{ha, hb}}}}
			if err := writeDeferredPending(state, name+"#media", pass, m); err != nil {
				t.Fatal(err)
			}
			held, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			stubPresenceProbe(t, func(h string) (bool, error) {
				if h == hb {
					once.Do(func() { close(held) })
					<-release
					return false, nil
				}
				return true, nil
			})
			var live sync.Mutex
			alive := true
			mayWrite := func() bool { live.Lock(); defer live.Unlock(); return alive }
			done := make(chan struct{})
			goSafe("test-old-presence", func() {
				defer close(done)
				settleSignInPresence("http://store.invalid", state, cache, name, pass, mayWrite)
			})
			<-held
			if tc.endOldRun {
				live.Lock()
				alive = false
				live.Unlock()
			}
			if tc.newList {
				if err := writeDeferredPending(state, name+"#media", pass, m); err != nil {
					t.Fatal(err)
				}
			}
			close(release)
			<-done
			if set, _ := readPendingT(t, path); !set[ha] || !set[hb] {
				t.Fatalf("%s: the old check cleared the list to %v, want both hashes still pending", tc.label, set)
			}
			if b, _ := os.ReadFile(cache); strings.Contains(string(b), ha) {
				t.Fatalf("%s: the old check recorded its confirmation in the blob cache", tc.label)
			}
			// The new sign-in's own check now meets a store short of ha, and must say so.
			stubPresenceProbe(t, func(h string) (bool, error) { return h == hb, nil })
			if p, mi, u := settleDeferredPresence("http://store.invalid", path, cache, nil, nil); p != 1 || mi != 1 || u != 0 {
				t.Fatalf("%s: the new check counts %d/%d/%d, want 1 present, 1 missing", tc.label, p, mi, u)
			}
		})
	}
}

// presenceRoundTrip is an http.RoundTripper from a func, so the probe tests need no socket.
type presenceRoundTrip func(*http.Request) (*http.Response, error)

func (f presenceRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// RF-002: a probe that meets transient store failures retries, and neither its retry lines nor its error carry the
// chunk hash (or any long piece of it). The real deferredChunkProbe runs against a fake transport, in cap mode and
// in direct S3 mode, answering 500 (cap) or 503 (S3) and then a transport error that repeats the URL.
func TestPresenceProbeLogsNoChunkHash(t *testing.T) {
	h := strings.Repeat("0123456789abcdef", 4)
	oldBase := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = oldBase })
	oldHTTP := storeHTTP
	t.Cleanup(func() { storeHTTP = oldHTTP })
	failures := func(status int) presenceRoundTrip {
		var n int
		var mu sync.Mutex
		return func(r *http.Request) (*http.Response, error) {
			mu.Lock()
			n++
			k := n
			mu.Unlock()
			if k%2 == 0 {
				return nil, &url.Error{Op: "Get", URL: r.URL.String(), Err: errors.New("connection reset")}
			}
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(r.URL.Path)),
				Header: http.Header{}, Request: r}, nil
		}
	}
	leaks := func(out string) bool {
		for i := 0; i+12 <= len(h); i += 4 {
			if strings.Contains(out, h[i:i+12]) {
				return true
			}
		}
		return false
	}

	t.Run("cap", func(t *testing.T) {
		t.Setenv("GATEWAY_URL", "http://gateway.invalid")
		t.Setenv("S3_ACCESS_KEY", "")
		storeHTTP = &http.Client{Transport: failures(http.StatusInternalServerError)}
		key := "blob/" + h
		var err error
		capReadMu.Lock()
		capReadCache[key] = capEntry{url: "http://store.invalid/" + key + "?X-Amz-Signature=s", exp: time.Now().Add(time.Hour)}
		capReadMu.Unlock()
		t.Cleanup(func() { capInvalidate(key) })
		out := captureStderr(t, func() { _, err = presenceProbeWithCap(t, key) })
		if err == nil {
			t.Fatal("a store answering 500 was read as an answer")
		}
		if !strings.Contains(out, "retry ") {
			t.Fatalf("no retry line was printed, so the test proves nothing:\n%s", out)
		}
		if leaks(out) || leaks(err.Error()) {
			t.Fatalf("the cap probe's retry output or error carries the chunk hash:\n%s\nerr: %v", out, err)
		}
	})

	t.Run("s3", func(t *testing.T) {
		t.Setenv("GATEWAY_URL", "")
		t.Setenv("S3_ACCESS_KEY", "test-access")
		cl, err := minio.New("store.invalid", &minio.Options{
			Creds:     credentials.NewStaticV4("test-access", "test-secret", ""),
			Region:    "us-east-1",
			Transport: failures(http.StatusForbidden),
		})
		if err != nil {
			t.Fatal(err)
		}
		s3InitMu.Lock()
		oldCl, oldBk := s3client, s3bucket
		s3client, s3bucket = cl, "bucket"
		s3InitMu.Unlock()
		t.Cleanup(func() { s3InitMu.Lock(); s3client, s3bucket = oldCl, oldBk; s3InitMu.Unlock() })
		var perr error
		out := captureStderr(t, func() { _, perr = deferredChunkProbe("s3", h) })
		if perr == nil {
			t.Fatal("a store answering 403 was read as an answer")
		}
		if !strings.Contains(out, "retry ") {
			t.Fatalf("no retry line was printed, so the test proves nothing:\n%s", out)
		}
		if leaks(out) || leaks(perr.Error()) {
			t.Fatalf("the S3 probe's retry output or error carries the chunk hash:\n%s\nerr: %v", out, perr)
		}
	})
}

// presenceProbeWithCap runs the real probe in cap mode, re-caching key's cap before each attempt through the
// transport, so no attempt reaches the gateway.
func presenceProbeWithCap(t *testing.T, key string) (bool, error) {
	t.Helper()
	inner := storeHTTP.Transport
	storeHTTP = &http.Client{Transport: presenceRoundTrip(func(r *http.Request) (*http.Response, error) {
		resp, err := inner.RoundTrip(r)
		capReadMu.Lock()
		capReadCache[key] = capEntry{url: "http://store.invalid/" + key + "?X-Amz-Signature=s", exp: time.Now().Add(time.Hour)}
		capReadMu.Unlock()
		return resp, err
	})}
	return deferredChunkProbe("s3", strings.TrimPrefix(key, "blob/"))
}
