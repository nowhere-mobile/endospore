package main

import (
	"bytes"
	"crypto/ed25519"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// bwpStore is an http store as delRelAckOnlyStore: POST /blob stores the body under its SHA-256 hex, PUT /ref/<r>
// stores a ref, GET serves both. It counts the writes. abortRefs makes every GET /ref/ abort the connection, so the
// read fails as a transport error (a 500 would not: a non-S3 getRefBytes reads any non-404 body as the ref).
type bwpStore struct {
	mu     sync.Mutex
	url    string
	refs   map[string]string
	blobs  map[string][]byte
	writes int
}

func newBwpStore(t *testing.T, abortRefs bool) *bwpStore {
	t.Helper()
	s := &bwpStore{refs: map[string]string{}, blobs: map[string][]byte{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			key := bwfHash(body)
			s.blobs[key] = body
			s.writes++
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			if b, ok := s.blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			body, _ := io.ReadAll(r.Body)
			s.refs[strings.TrimPrefix(r.URL.Path, "/ref/")] = string(body)
			s.writes++
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			if abortRefs {
				panic(http.ErrAbortHandler)
			}
			if v, ok := s.refs[strings.TrimPrefix(r.URL.Path, "/ref/")]; ok {
				io.WriteString(w, v)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	s.url = srv.URL
	return s
}

// publish puts env into the store as the published warning, without counting it as a write.
func (s *bwpStore) publish(env []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	h := bwfHash(env)
	s.blobs[h] = env
	s.refs[buildWarningRefName] = h
}

// state returns the published ref and the number of writes so far.
func (s *bwpStore) state() (string, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.refs[buildWarningRefName], s.writes
}

// bwpFile writes env to a file in the test's own temp dir.
func bwpFile(t *testing.T, env []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "warning.env")
	if err := os.WriteFile(p, env, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// bwpRefused asserts that publishing env is refused with an error naming every want, and that nothing was written.
func bwpRefused(t *testing.T, s *bwpStore, env []byte, want ...string) {
	t.Helper()
	ref0, n0 := s.state()
	w, h, err := buildWarningPut(s.url, bwpFile(t, env), bwNow)
	if err == nil || w != nil || h != "" {
		t.Fatalf("published (seq %v, %q), want refused", w, h)
	}
	for _, x := range want {
		if !strings.Contains(err.Error(), x) {
			t.Errorf("error %q does not name %q", err, x)
		}
	}
	if ref, n := s.state(); ref != ref0 || n != n0 {
		t.Fatalf("a refused publish wrote to the store: ref %q -> %q, writes %d -> %d", ref0, ref, n0, n)
	}
}

// bwpPublished asserts that publishing env succeeds and that the ref names a blob holding exactly env.
func bwpPublished(t *testing.T, s *bwpStore, env []byte, seq int64) {
	t.Helper()
	w, h, err := buildWarningPut(s.url, bwpFile(t, env), bwNow)
	if err != nil || w == nil {
		t.Fatalf("seq %d refused: %v", seq, err)
	}
	if w.Seq != seq {
		t.Errorf("published seq %d, want %d", w.Seq, seq)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.refs[buildWarningRefName] != h || h != bwfHash(env) {
		t.Fatalf("ref %s = %q, returned %q, want the file's hash %q", buildWarningRefName, s.refs[buildWarningRefName], h, bwfHash(env))
	}
	if b := s.blobs[h]; !bytes.Equal(b, env) || bwfHash(b) != h {
		t.Fatalf("the blob named by the ref is not the file")
	}
}

func TestBuildWarningPutFirst(t *testing.T) {
	k := bwUseKey(t)
	s := newBwpStore(t, false)
	bwpPublished(t, s, bwfFresh(k, 1, "0.5.45"), 1)
}

func TestBuildWarningPutRefusesNotAbove(t *testing.T) {
	k := bwUseKey(t)
	s := newBwpStore(t, false)
	s.publish(bwfFresh(k, 4, "0.5.45"))
	bwpRefused(t, s, bwfFresh(k, 4, "0.5.46"), "seq 4 is not above the published seq 4")
	bwpRefused(t, s, bwfFresh(k, 3, "0.5.45"), "seq 3 is not above the published seq 4")
	bwpPublished(t, s, bwfFresh(k, 5, "0.5.45"), 5)
}

func TestBuildWarningPutOverExpired(t *testing.T) {
	k := bwUseKey(t)
	s := newBwpStore(t, false)
	s.publish(bwfEnv(k, 4, bwNow-40*86400, bwNow-86400, "0.5.45"))
	bwpRefused(t, s, bwfFresh(k, 4, "0.5.46"), "seq 4 is not above the published seq 4")
	bwpPublished(t, s, bwfFresh(k, 5, "0.5.45"), 5)
}

func TestBuildWarningPutRefusesForeignPublished(t *testing.T) {
	k := bwUseKey(t)
	s := newBwpStore(t, false)
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32))
	s.publish(bwfFresh(other, 1, "0.5.45"))
	bwpRefused(t, s, bwfFresh(k, 5, "0.5.45"), "verifies neither")
}

func TestBuildWarningPutRefusesStoreError(t *testing.T) {
	k := bwUseKey(t)
	s := newBwpStore(t, true)
	bwpRefused(t, s, bwfFresh(k, 5, "0.5.45"), "could not be read")
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.blobs) != 0 || len(s.refs) != 0 {
		t.Fatalf("a refused publish left %d blob(s) and %d ref(s)", len(s.blobs), len(s.refs))
	}
}

func TestBuildWarningCheckRefuses(t *testing.T) {
	k := bwUseKey(t)
	good := bwfFresh(k, 2, "0.5.45")
	w, env, err := buildWarningCheckFile(bwpFile(t, good), bwNow)
	if err != nil || w == nil || w.Seq != 2 || !bytes.Equal(env, good) {
		t.Fatalf("a good file: %v, %v", w, err)
	}
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32))
	pad := append(append([]byte(nil), good...), bytes.Repeat([]byte(" "), buildWarningEnvMax+1-len(good))...)
	for _, c := range []struct {
		name string
		env  []byte
		want string
	}{
		{"bad signature", bwfFresh(other, 2, "0.5.45"), "signature"},
		{"expired", bwfEnv(k, 2, bwNow-40*86400, bwNow-86400, "0.5.45"), "expired"},
		{"oversized", pad, "cap"},
	} {
		w, env, err := buildWarningCheckFile(bwpFile(t, c.env), bwNow)
		if err == nil || w != nil || env != nil {
			t.Errorf("%s: accepted", c.name)
		} else if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: error %q does not name %q", c.name, err, c.want)
		}
	}
}
