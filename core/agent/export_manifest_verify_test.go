package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// NWP-20261021-13. export_manifest_test.go fills a VerifyReport by hand; nothing there runs verifyExportManifest,
// the function that fills it from a store and the only thing between a short copy and a login that publishes a
// head naming objects that are not there (NWP-20260919-05). These tests run it against a store that answers HEAD
// the way the dev store does (newHTTPStore answers HEAD 404, so it cannot be used).

type verifyStore struct {
	mu    sync.Mutex
	blobs map[string][]byte // hash -> bytes
	refs  map[string]string // name -> value; "" is a tombstone (200 with an empty body)
}

func newVerifyStore(t *testing.T) (*verifyStore, *httptest.Server) {
	t.Helper()
	st := &verifyStore{blobs: map[string][]byte{}, refs: map[string]string{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		st.mu.Lock()
		defer st.mu.Unlock()
		switch {
		case strings.HasPrefix(r.URL.Path, "/blob/") && (r.Method == http.MethodGet || r.Method == http.MethodHead):
			b, ok := st.blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.Write(b) // net/http drops the body on HEAD
		case strings.HasPrefix(r.URL.Path, "/ref/") && r.Method == http.MethodGet:
			v, ok := st.refs[strings.TrimPrefix(r.URL.Path, "/ref/")]
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.Write([]byte(v))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return st, srv
}

// putBlob stores data under its real hash and returns the manifest entry.
func (s *verifyStore) putBlob(data []byte) ManifestBlob {
	sum := sha256.Sum256(data)
	h := hex.EncodeToString(sum[:])
	s.mu.Lock()
	s.blobs[h] = data
	s.mu.Unlock()
	return ManifestBlob{Key: "blob/" + h, Size: int64(len(data))}
}

// goodStore holds two blobs and two refs and returns the manifest that names exactly them.
func goodStore(t *testing.T) (*verifyStore, *httptest.Server, *ExportManifest) {
	st, srv := newVerifyStore(t)
	m := &ExportManifest{
		Version: exportManifestVersion,
		Blobs:   []ManifestBlob{st.putBlob([]byte("first chunk")), st.putBlob([]byte("second chunk"))},
		Refs: []ManifestRef{
			{Key: "ref/p:one", Value: strings.Repeat("1", 64)},
			{Key: "ref/p:two", Value: strings.Repeat("2", 64)},
		},
	}
	for _, r := range m.Refs {
		st.refs[strings.TrimPrefix(r.Key, "ref/")] = r.Value
	}
	return st, srv, m
}

func hasEntry(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}

func TestVerifyManifestCompleteStorePasses(t *testing.T) {
	for _, deep := range []bool{false, true} {
		_, srv, m := goodStore(t)
		rep := verifyExportManifest(srv.URL, m, deep)
		if !rep.ok() {
			t.Fatalf("deep=%v: a complete store failed: %s", deep, rep.summary())
		}
		if rep.CheckedBlobs != 2 || rep.CheckedRefs != 2 {
			t.Fatalf("deep=%v: checked %d blobs, %d refs; want 2 and 2", deep, rep.CheckedBlobs, rep.CheckedRefs)
		}
	}
}

func TestVerifyManifestWrongRefValue(t *testing.T) {
	st, srv, m := goodStore(t)
	st.refs["p:two"] = strings.Repeat("9", 64)
	rep := verifyExportManifest(srv.URL, m, false)
	if rep.ok() || !hasEntry(rep.WrongRefs, "ref/p:two") || len(rep.WrongRefs) != 1 {
		t.Fatalf("a ref holding another value was not reported WRONG: %+v", rep)
	}
	if len(rep.MissingRefs) != 0 {
		t.Fatalf("a wrong value was also reported missing: %+v", rep.MissingRefs)
	}
}

func TestVerifyManifestMissingRef(t *testing.T) {
	st, srv, m := goodStore(t)
	delete(st.refs, "p:one")
	rep := verifyExportManifest(srv.URL, m, false)
	if rep.ok() || !hasEntry(rep.MissingRefs, "ref/p:one") || len(rep.WrongRefs) != 0 {
		t.Fatalf("an absent ref was not reported MISSING: %+v", rep)
	}
}

func TestVerifyManifestTombstonedRefIsMissingNotWrong(t *testing.T) {
	st, srv, m := goodStore(t)
	st.refs["p:one"] = "" // exists, empty
	rep := verifyExportManifest(srv.URL, m, false)
	if rep.ok() || !hasEntry(rep.MissingRefs, "ref/p:one") {
		t.Fatalf("a tombstoned ref was not reported MISSING: %+v", rep)
	}
	if len(rep.WrongRefs) != 0 {
		t.Fatalf("a tombstone was reported WRONG: %+v", rep.WrongRefs)
	}
}

func TestVerifyManifestKeyWithoutRefPrefix(t *testing.T) {
	_, srv, m := goodStore(t)
	m.Refs = append(m.Refs, ManifestRef{Key: "p:three", Value: strings.Repeat("3", 64)})
	rep := verifyExportManifest(srv.URL, m, false)
	if rep.ok() || !hasEntry(rep.WrongRefs, "p:three (not a ref key)") {
		t.Fatalf("a malformed ref key was not reported with its suffix: %+v", rep)
	}
	if rep.CheckedRefs != 2 {
		t.Fatalf("CheckedRefs = %d; a malformed key must not count as checked (want 2)", rep.CheckedRefs)
	}
}

func TestVerifyManifestMissingBlob(t *testing.T) {
	for _, deep := range []bool{false, true} {
		st, srv, m := goodStore(t)
		gone := strings.TrimPrefix(m.Blobs[1].Key, "blob/")
		delete(st.blobs, gone)
		rep := verifyExportManifest(srv.URL, m, deep)
		if rep.ok() || !hasEntry(rep.MissingBlobs, m.Blobs[1].Key) || len(rep.MissingBlobs) != 1 {
			t.Fatalf("deep=%v: an absent blob was not reported MISSING: %+v", deep, rep)
		}
		if len(rep.CorruptBlobs) != 0 {
			t.Fatalf("deep=%v: an absent blob was reported corrupt: %+v", deep, rep.CorruptBlobs)
		}
	}
}

func TestVerifyManifestCorruptBlobPresenceVsDeep(t *testing.T) {
	st, srv, m := goodStore(t)
	h := strings.TrimPrefix(m.Blobs[0].Key, "blob/")
	st.blobs[h] = []byte("not what hashes to the key")

	// Presence is deliberately not content: a blob that is there passes the cheap mode. Pinned so nobody
	// believes the default mode proves integrity.
	if rep := verifyExportManifest(srv.URL, m, false); !rep.ok() {
		t.Fatalf("presence mode rejected a blob that is present: %s", rep.summary())
	}
	rep := verifyExportManifest(srv.URL, m, true)
	if rep.ok() || !hasEntry(rep.CorruptBlobs, m.Blobs[0].Key) || len(rep.CorruptBlobs) != 1 {
		t.Fatalf("deep mode did not report the mis-hashed blob CORRUPT: %+v", rep)
	}
	if len(rep.MissingBlobs) != 0 {
		t.Fatalf("a corrupt blob was also reported missing: %+v", rep.MissingBlobs)
	}
}

func TestVerifyManifestKeyWithoutBlobPrefix(t *testing.T) {
	for _, deep := range []bool{false, true} {
		_, srv, m := goodStore(t)
		m.Blobs = append(m.Blobs, ManifestBlob{Key: strings.Repeat("d", 64), Size: 1})
		rep := verifyExportManifest(srv.URL, m, deep)
		if rep.ok() || !hasEntry(rep.MissingBlobs, strings.Repeat("d", 64)+" (not a blob key)") {
			t.Fatalf("deep=%v: a malformed blob key was not reported with its suffix: %+v", deep, rep)
		}
		if rep.CheckedBlobs != 2 {
			t.Fatalf("deep=%v: CheckedBlobs = %d; a malformed key must not count (want 2)", deep, rep.CheckedBlobs)
		}
	}
}

func TestVerifyManifestDeepFlagAndSummary(t *testing.T) {
	_, srv, m := goodStore(t)
	cheap := verifyExportManifest(srv.URL, m, false)
	deep := verifyExportManifest(srv.URL, m, true)
	if cheap.DeepVerified || !deep.DeepVerified {
		t.Fatalf("DeepVerified does not mirror the flag: cheap=%v deep=%v", cheap.DeepVerified, deep.DeepVerified)
	}
	if s := cheap.summary(); !strings.Contains(s, "presence") || strings.Contains(s, "deep") {
		t.Fatalf("presence summary = %q", s)
	}
	if s := deep.summary(); !strings.Contains(s, "deep") || strings.Contains(s, "presence") {
		t.Fatalf("deep summary = %q", s)
	}
}

// A store that is gone must never verify. getRef panics through checkRead on a transport error, which is also
// a refusal; a report is accepted too, provided it is not ok().
func TestVerifyManifestStoreGoneIsNeverOK(t *testing.T) {
	for _, deep := range []bool{false, true} {
		_, srv, m := goodStore(t)
		srv.Close()
		func() {
			defer func() { _ = recover() }()
			if rep := verifyExportManifest(srv.URL, m, deep); rep.ok() {
				t.Fatalf("deep=%v: a store that is gone verified: %s", deep, rep.summary())
			}
		}()

		// Blobs only: no ref read to panic first, so the blob probes themselves must fail toward absent.
		blobsOnly := &ExportManifest{Version: exportManifestVersion, Blobs: m.Blobs}
		func() {
			defer func() { _ = recover() }()
			rep := verifyExportManifest(srv.URL, blobsOnly, deep)
			if rep.ok() || len(rep.MissingBlobs) != len(m.Blobs) {
				t.Fatalf("deep=%v: blob probes against a gone store did not all fail toward absent: %+v", deep, rep)
			}
		}()
	}
}

// decodeExportManifest refuses a ref-less index, so the CLI never passes nil; this is today's behaviour.
func TestVerifyManifestNilManifestIsTheEmptyReport(t *testing.T) {
	rep := verifyExportManifest("http://unused.invalid", nil, true)
	if !rep.ok() || rep.CheckedBlobs != 0 || rep.CheckedRefs != 0 || !rep.DeepVerified {
		t.Fatalf("nil manifest report = %+v", rep)
	}
}

// NWP-20261120-20: a store read that fails in transport is listed UNREADABLE and refuses; it no longer panics out
// of verifyExportManifest, where main's recover printed one ERR line in place of the whole report.

// vuHijackingFront forwards to srv, but hijacks and closes the connection on every request for path, so the
// client sees a transport error rather than an HTTP status.
func vuHijackingFront(t *testing.T, srv *httptest.Server, path string) *httptest.Server {
	t.Helper()
	target, _ := url.Parse(srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == path {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				conn.Close()
			}
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	return front
}

// vuVerify runs verifyExportManifest and fails the test, rather than the binary, when it panics.
func vuVerify(t *testing.T, base string, m *ExportManifest, deep bool) *VerifyReport {
	t.Helper()
	defer func() {
		if recover() != nil {
			t.Fatalf("deep=%v: verifyExportManifest panicked on a failed store read", deep)
		}
	}()
	return verifyExportManifest(base, m, deep)
}

// vuCapStore is a cap-mode store (preflightStrictStore's fixture) holding two blobs and one ref.
func vuCapStore(t *testing.T) (*pfStore, *ExportManifest) {
	t.Helper()
	s := preflightStrictStore(t)
	m := &ExportManifest{Version: exportManifestVersion}
	for _, data := range []string{"vu cap first", "vu cap second"} {
		sum := sha256.Sum256([]byte(data))
		h := hex.EncodeToString(sum[:])
		s.put("blob/"+h, []byte(data))
		m.Blobs = append(m.Blobs, ManifestBlob{Key: "blob/" + h, Size: int64(len(data))})
	}
	v := strings.Repeat("3", 64)
	s.put("ref/vu-cap-one", []byte(v))
	m.Refs = []ManifestRef{{Key: "ref/vu-cap-one", Value: v}}
	return s, m
}

// Plain HTTP: getRefBytes panics through checkRead on a transport error, with no retry.
func TestVerifyManifestUnreadableRefIsListed(t *testing.T) {
	for _, deep := range []bool{false, true} {
		// The only fault is the unreadable ref, so ok() turns on Unreadable alone.
		_, srv, m := goodStore(t)
		front := vuHijackingFront(t, srv, "/ref/p:one")
		rep := vuVerify(t, front.URL, m, deep)
		if len(rep.Unreadable) != 1 || rep.Unreadable[0] != "ref/p:one" {
			t.Fatalf("deep=%v: Unreadable = %v, want [ref/p:one]", deep, rep.Unreadable)
		}
		if rep.ok() {
			t.Fatalf("deep=%v: a store that did not answer a ref read verified: %s", deep, rep.summary())
		}
		if len(rep.MissingRefs)+len(rep.WrongRefs)+len(rep.MissingBlobs)+len(rep.CorruptBlobs) != 0 {
			t.Fatalf("deep=%v: the rest was not judged as before: %+v", deep, rep)
		}
		if rep.CheckedRefs != 2 || rep.CheckedBlobs != 2 {
			t.Fatalf("deep=%v: checked %d refs, %d blobs; want 2 and 2", deep, rep.CheckedRefs, rep.CheckedBlobs)
		}
		sum := rep.summary()
		if !strings.Contains(sum, "UNREADABLE (1):") ||
			!strings.Contains(sum, "UNREADABLE ref/p:one -- the store did not answer; refusing") {
			t.Fatalf("deep=%v: summary does not name the unreadable ref:\n%s", deep, sum)
		}
		if strings.Contains(sum, "http") {
			t.Fatalf("deep=%v: summary carries a URL:\n%s", deep, sum)
		}

		// The loop goes on past the unreadable ref and judges the next one.
		st, srv, m := goodStore(t)
		st.refs["p:two"] = strings.Repeat("9", 64)
		front = vuHijackingFront(t, srv, "/ref/p:one")
		rep = vuVerify(t, front.URL, m, deep)
		if len(rep.Unreadable) != 1 || rep.Unreadable[0] != "ref/p:one" ||
			len(rep.WrongRefs) != 1 || rep.WrongRefs[0] != "ref/p:two" {
			t.Fatalf("deep=%v: Unreadable = %v WrongRefs = %v, want [ref/p:one] and [ref/p:two]",
				deep, rep.Unreadable, rep.WrongRefs)
		}
	}
}

// Cap mode: capGet retries a 500 and then panics; a 403 would not do, since a fresh-cap 403 reads as absent.
func TestVerifyManifestCapDeepUnreadableBlob(t *testing.T) {
	s, m := vuCapStore(t)
	bad := m.Blobs[0].Key
	s.fail[bad] = true
	rep := vuVerify(t, "s3", m, true)
	if len(rep.Unreadable) != 1 || rep.Unreadable[0] != bad {
		t.Fatalf("Unreadable = %v, want [%s]", rep.Unreadable, bad)
	}
	if hasEntry(rep.MissingBlobs, bad) {
		t.Fatalf("an unreadable blob was reported MISSING: %+v", rep)
	}
	if len(rep.MissingRefs)+len(rep.WrongRefs)+len(rep.MissingBlobs)+len(rep.CorruptBlobs) != 0 {
		t.Fatalf("the rest was not judged as before: %+v", rep)
	}
	if rep.CheckedBlobs != 2 || rep.CheckedRefs != 1 {
		t.Fatalf("checked %d blobs, %d refs; want 2 and 1", rep.CheckedBlobs, rep.CheckedRefs)
	}
	if rep.ok() {
		t.Fatalf("a store that did not answer a blob read verified: %s", rep.summary())
	}
	sum := rep.summary()
	if !strings.Contains(sum, "UNREADABLE "+bad+" -- the store did not answer; refusing") {
		t.Fatalf("summary does not name the unreadable blob:\n%s", sum)
	}
	if strings.Contains(sum, "http") {
		t.Fatalf("summary carries a URL:\n%s", sum)
	}
}

// With no failed read, Unreadable is empty and the pass is unchanged, in both modes.
func TestVerifyManifestNoFailureLeavesUnreadableEmpty(t *testing.T) {
	for _, deep := range []bool{false, true} {
		_, srv, m := goodStore(t)
		rep := vuVerify(t, srv.URL, m, deep)
		if len(rep.Unreadable) != 0 || !rep.ok() || strings.Contains(rep.summary(), "UNREADABLE") {
			t.Fatalf("deep=%v: a complete plain-HTTP store did not pass cleanly: %+v\n%s", deep, rep, rep.summary())
		}
	}
	_, m := vuCapStore(t)
	rep := vuVerify(t, "s3", m, true)
	if len(rep.Unreadable) != 0 || !rep.ok() || rep.CheckedBlobs != 2 || rep.CheckedRefs != 1 {
		t.Fatalf("a complete cap-mode store did not pass cleanly: %+v\n%s", rep, rep.summary())
	}
}

// The summary prints every unreadable key: the other sections stop at twelve, this one must not, or the
// thirteenth failed read is hidden behind "... and 1 more" and cannot be re-read by name.
func TestVerifyManifestSummaryPrintsEveryUnreadableKey(t *testing.T) {
	rep := &VerifyReport{CheckedBlobs: 13, DeepVerified: true}
	for i := 0; i < 13; i++ {
		rep.Unreadable = append(rep.Unreadable, fmt.Sprintf("blob/%064x", i))
	}
	sum := rep.summary()
	if !strings.Contains(sum, "UNREADABLE (13):") {
		t.Fatalf("summary does not count 13 unreadable keys:\n%s", sum)
	}
	for _, k := range rep.Unreadable {
		if !strings.Contains(sum, "UNREADABLE "+k+" -- the store did not answer; refusing") {
			t.Fatalf("summary does not name %s:\n%s", k, sum)
		}
	}
	if strings.Contains(sum, "more") {
		t.Fatalf("summary truncates the unreadable keys:\n%s", sum)
	}
}
