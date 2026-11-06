package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261102-16: restore-preflight reads each destination ref STRICTLY. In cap mode the old reader (capGet)
// took a 403 on a fresh cap for a definitive miss, so a destination whose store answered every presigned GET 403
// read as empty and SAFE and the copy overwrote the live heads. The store below is a cap-mode mock behind a
// proxy that answers chosen object GETs 403; the retry backoffs are a millisecond.

type pfStore struct {
	objs   map[string][]byte
	mu     *sync.Mutex
	forbid map[string]int  // object key -> how many GETs of it to answer 403 (-1: every one)
	fail   map[string]bool // object key -> answer every GET of it 500 (NWP-20261120-20)
	fmu    sync.Mutex
}

func preflightStrictStore(t *testing.T) *pfStore {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	s := &pfStore{objs: objs, mu: mu, forbid: map[string]int{}, fail: map[string]bool{}}
	target, _ := url.Parse(srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" {
			k := r.URL.Query().Get("k")
			s.fmu.Lock()
			fail := s.fail[k]
			n, ok := s.forbid[k]
			if ok && n > 0 {
				s.forbid[k] = n - 1
			}
			s.fmu.Unlock()
			if fail {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			if ok && n != 0 {
				w.WriteHeader(http.StatusForbidden)
				return
			}
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	t.Setenv("GATEWAY_URL", px.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	return s
}

func (s *pfStore) put(k string, b []byte) {
	s.mu.Lock()
	s.objs[k] = b
	s.mu.Unlock()
}

// pfBlob stores a vault head of the given version and returns its hash.
func (s *pfStore) pfBlob(version uint64) string {
	b := serializeVault(&vault{V: 1, Slots: []keyslot{{}}, Manifest: "m", Version: version})
	h := sha256.Sum256(b)
	hx := hex.EncodeToString(h[:])
	s.put("blob/"+hx, b)
	return hx
}

func pfManifest(refs ...ManifestRef) *ExportManifest { return &ExportManifest{Version: 1, Refs: refs} }

const pfHexA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const pfHexB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

// A ref the store answers 403 on every attempt is UNREADABLE and blocks; it is not absent, and the summary names
// it without a URL.
func TestPreflightFresh403IsUnreadable(t *testing.T) {
	s := preflightStrictStore(t)
	s.put("ref/pf-fresh403-a", []byte(pfHexA))
	s.forbid["ref/pf-fresh403-a"] = -1
	rep := preflightRestore("s3", pfManifest(ManifestRef{Key: "ref/pf-fresh403-a", Value: pfHexB}))
	if len(rep.Verdicts) != 1 || rep.Verdicts[0].State != "unreadable" {
		t.Fatalf("verdicts = %+v, want one unreadable", rep.Verdicts)
	}
	if rep.Blocking != 1 || rep.Safe() {
		t.Fatalf("Blocking=%d Safe=%v, want 1/false", rep.Blocking, rep.Safe())
	}
	sum := rep.summary()
	if !strings.Contains(sum, "UNREADABLE ref/pf-fresh403-a") || !strings.Contains(sum, "1 UNREADABLE") {
		t.Fatalf("summary does not name the unreadable ref:\n%s", sum)
	}
	if strings.Contains(sum, "http") {
		t.Fatalf("summary carries a URL:\n%s", sum)
	}
}

// A real 404 is still absent and SAFE: the guard must not refuse an empty destination on a 404 store.
func TestPreflight404IsAbsent(t *testing.T) {
	preflightStrictStore(t)
	rep := preflightRestore("s3", pfManifest(ManifestRef{Key: "ref/pf-404-a", Value: pfHexA}))
	if len(rep.Verdicts) != 1 || rep.Verdicts[0].State != "absent" || rep.Blocking != 0 || !rep.Safe() {
		t.Fatalf("report = %+v, want one absent and safe", rep)
	}
	if !strings.Contains(rep.summary(), "1 absent") {
		t.Fatalf("summary:\n%s", rep.summary())
	}
}

// An existing empty ref is a tombstone, named and not blocking.
func TestPreflightEmptyObjectIsTombstone(t *testing.T) {
	s := preflightStrictStore(t)
	s.put("ref/pf-tomb-a", []byte{})
	rep := preflightRestore("s3", pfManifest(ManifestRef{Key: "ref/pf-tomb-a", Value: pfHexA}))
	if len(rep.Verdicts) != 1 || rep.Verdicts[0].State != "tombstone" || rep.Tombstoned != 1 || !rep.Safe() {
		t.Fatalf("report = %+v, want one tombstone and safe", rep)
	}
	if !strings.Contains(rep.summary(), "TOMBSTONE") {
		t.Fatalf("summary:\n%s", rep.summary())
	}
}

// Identical stays same; a different head stays differs with both versions.
func TestPreflightSameAndDiffersUnchanged(t *testing.T) {
	s := preflightStrictStore(t)
	s.put("ref/pf-same-a", []byte(pfHexA))
	s.put("ref/pf-same-b", []byte(s.pfBlob(9)))
	rep := preflightRestore("s3", pfManifest(
		ManifestRef{Key: "ref/pf-same-a", Value: pfHexA},
		ManifestRef{Key: "ref/pf-same-b", Value: s.pfBlob(4)}))
	if len(rep.Verdicts) != 2 || rep.Verdicts[0].State != "same" || rep.Verdicts[1].State != "differs" {
		t.Fatalf("verdicts = %+v", rep.Verdicts)
	}
	if v := rep.Verdicts[1]; v.DestVersion != 9 || v.SrcVersion != 4 || rep.Blocking != 1 {
		t.Fatalf("differs verdict = %+v Blocking=%d", v, rep.Blocking)
	}
	if !strings.Contains(rep.summary(), "ROLL THE PROFILE BACK") {
		t.Fatalf("summary:\n%s", rep.summary())
	}
}

// One 403 on a stale cap costs a refetch, and the 200 on the fresh cap is read: no false refusal.
func TestPreflightStaleThenFreshCapReadsTheObject(t *testing.T) {
	s := preflightStrictStore(t)
	s.put("ref/pf-stale-a", []byte(pfHexA))
	s.forbid["ref/pf-stale-a"] = 1
	rep := preflightRestore("s3", pfManifest(ManifestRef{Key: "ref/pf-stale-a", Value: pfHexA}))
	if len(rep.Verdicts) != 1 || rep.Verdicts[0].State != "same" || !rep.Safe() {
		t.Fatalf("report = %+v, want one same and safe", rep)
	}
}

// NWP-20261120-20: a DIFFERS ref whose head blob the store never answers (500 on every attempt) leaves that
// head's version unknown (0) and still refuses. headVersionOf's read used to panic out of preflightRestore in
// cap mode, and main's recover then printed one ERR line in place of the whole report.
func TestPreflightUnreadableHeadBlobLeavesVersionUnknown(t *testing.T) {
	for _, side := range []string{"dest", "src"} {
		t.Run(side, func(t *testing.T) {
			s := preflightStrictStore(t)
			key := "ref/pf-headfail-" + side
			dest, src := s.pfBlob(9), s.pfBlob(4)
			s.put(key, []byte(dest))
			if side == "dest" {
				s.fail["blob/"+dest] = true
			} else {
				s.fail["blob/"+src] = true
			}
			var rep *PreflightReport
			func() {
				defer func() {
					if recover() != nil {
						t.Fatalf("preflightRestore panicked on an unreadable head blob")
					}
				}()
				rep = preflightRestore("s3", pfManifest(ManifestRef{Key: key, Value: src}))
			}()
			if len(rep.Verdicts) != 1 || rep.Verdicts[0].State != "differs" {
				t.Fatalf("verdicts = %+v, want one differs", rep.Verdicts)
			}
			v := rep.Verdicts[0]
			wantDest, wantSrc := uint64(0), uint64(4)
			if side == "src" {
				wantDest, wantSrc = 9, 0
			}
			if v.DestVersion != wantDest || v.SrcVersion != wantSrc {
				t.Fatalf("versions dest=%d src=%d, want dest=%d src=%d", v.DestVersion, v.SrcVersion, wantDest, wantSrc)
			}
			if rep.Blocking != 1 || rep.Safe() {
				t.Fatalf("Blocking=%d Safe=%v, want 1/false", rep.Blocking, rep.Safe())
			}
			sum := rep.summary()
			if !strings.Contains(sum, "versions could not be compared") {
				t.Fatalf("summary does not say the versions could not be compared:\n%s", sum)
			}
			if strings.Contains(sum, "ROLL THE PROFILE BACK") || strings.Contains(sum, "http") {
				t.Fatalf("summary claims a direction or carries a URL:\n%s", sum)
			}
		})
	}
}
