package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// ikpStore is bwpStore (build_warning_put_test.go) with one addition: at each PUT /ref/<r> it records, in refBlobStored,
// whether the blob that ref names was already stored. The final state is the same in either write order, so only this
// tells a ref written before its blob. abortRefs makes every GET /ref/ abort the connection, so the read fails as a
// transport error (a 500 would not: a non-S3 getRefBytes reads any non-404 body as the ref).
type ikpStore struct {
	mu            sync.Mutex
	url           string
	refs          map[string]string
	blobs         map[string][]byte
	refBlobStored map[string]bool
	writes        int
}

func newIkpStore(t *testing.T, abortRefs bool) *ikpStore {
	t.Helper()
	s := &ikpStore{refs: map[string]string{}, blobs: map[string][]byte{}, refBlobStored: map[string]bool{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			key := ikfHash(body)
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
			name := strings.TrimPrefix(r.URL.Path, "/ref/")
			_, stored := s.blobs[string(body)]
			s.refBlobStored[name] = stored
			s.refs[name] = string(body)
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

// publish puts env into the store as the published object, without counting it as a write or recording its order.
func (s *ikpStore) publish(env []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	h := ikfHash(env)
	s.blobs[h] = env
	s.refs[indexKeyRefName] = h
}

// state returns the published ref and the number of writes so far.
func (s *ikpStore) state() (string, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.refs[indexKeyRefName], s.writes
}

// ikpFile writes env to a file in the test's own temp dir.
func ikpFile(t *testing.T, env []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "index-key.env")
	if err := os.WriteFile(p, env, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// ikpRefused asserts that publishing env is refused with an error naming every want, and that nothing was written.
func ikpRefused(t *testing.T, s *ikpStore, env []byte, want ...string) {
	t.Helper()
	ref0, n0 := s.state()
	obj, h, err := indexKeyPut(s.url, ikpFile(t, env), iktNow)
	if err == nil || obj != nil || h != "" {
		t.Fatalf("published (%+v, %q), want refused", obj, h)
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

// ikpPublished asserts that publishing env succeeds, that the ref names a blob holding exactly env whose sha256 is its
// name, and that the blob was stored before the ref named it.
func ikpPublished(t *testing.T, s *ikpStore, env []byte, seq int64) {
	t.Helper()
	obj, h, err := indexKeyPut(s.url, ikpFile(t, env), iktNow)
	if err != nil || obj == nil {
		t.Fatalf("seq %d refused: %v", seq, err)
	}
	if obj.Seq != seq {
		t.Errorf("published seq %d, want %d", obj.Seq, seq)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.refs[indexKeyRefName] != h || h != ikfHash(env) {
		t.Fatalf("ref %s = %q, returned %q, want the file's hash %q", indexKeyRefName, s.refs[indexKeyRefName], h, ikfHash(env))
	}
	if b := s.blobs[h]; !bytes.Equal(b, env) || ikfHash(b) != h {
		t.Fatalf("the blob named by the ref is not the file")
	}
	if !s.refBlobStored[indexKeyRefName] {
		t.Fatalf("the ref named the blob before the blob was stored")
	}
}

func TestIndexKeyPutFirst(t *testing.T) {
	k := iktUseKey(t)
	s := newIkpStore(t, false)
	ikpPublished(t, s, ikfRollover(k, 1, iktIndexKey(1)), 1)
}

func TestIndexKeyPutRefusesNotAbove(t *testing.T) {
	k := iktUseKey(t)
	s := newIkpStore(t, false)
	s.publish(ikfRollover(k, 4, iktIndexKey(1)))
	ikpRefused(t, s, ikfRollover(k, 4, iktIndexKey(2)), "seq 4 is not above the published seq 4")
	ikpRefused(t, s, ikfRollover(k, 3, iktIndexKey(2)), "seq 3 is not above the published seq 4")
	ikpPublished(t, s, ikfRollover(k, 5, iktIndexKey(2)), 5)
}

func TestIndexKeyPutRefusesForeignPublished(t *testing.T) {
	k := iktUseKey(t)
	s := newIkpStore(t, false)
	// Seed 8: seed 9 is the release key here (iktUseKey), so an object it signs would verify.
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{8}, 32))
	s.publish(ikfRollover(other, 1, iktIndexKey(1)))
	ikpRefused(t, s, ikfRollover(k, 5, iktIndexKey(2)), "another key wrote it")
}

func TestIndexKeyPutRefusesStoreError(t *testing.T) {
	k := iktUseKey(t)
	s := newIkpStore(t, true)
	ikpRefused(t, s, ikfRollover(k, 5, iktIndexKey(1)), "could not be read")
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.blobs) != 0 || len(s.refs) != 0 {
		t.Fatalf("a refused publish left %d blob(s) and %d ref(s)", len(s.blobs), len(s.refs))
	}
}

func TestIndexKeyCheckRefuses(t *testing.T) {
	k := iktUseKey(t)
	good := ikfRollover(k, 2, iktIndexKey(1))
	obj, env, err := indexKeyCheckFile(ikpFile(t, good), iktNow)
	if err != nil || obj == nil || obj.Seq != 2 || !bytes.Equal(env, good) {
		t.Fatalf("a good file: %+v, %v", obj, err)
	}
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{8}, 32))
	schema2 := iktFields()
	schema2["schema"] = 2
	empty := iktFields()
	delete(empty, "key")
	delete(empty, "revoked")
	pad := append(append([]byte(nil), good...), bytes.Repeat([]byte(" "), indexKeyEnvMax+1-len(good))...)
	for _, c := range []struct {
		name string
		env  []byte
		want string
	}{
		{"bad signature", ikfRollover(other, 2, iktIndexKey(1)), "signature"},
		{"schema 2", ikfEnv(k, schema2), "unsupported schema"},
		{"neither key nor revoked", ikfEnv(k, empty), "names no key"},
		{"over the cap", pad, "cap"},
	} {
		obj, env, err := indexKeyCheckFile(ikpFile(t, c.env), iktNow)
		if err == nil || obj != nil || env != nil {
			t.Errorf("%s: accepted", c.name)
		} else if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: error %q does not name %q", c.name, err, c.want)
		}
	}
}

// TestIndexKeyCheckVector pins the bytes the offline signer must write. The literals are not built from the package's
// constants, and nowhere-cloud's signer pins the same ones: a mismatch means the code is wrong, so never re-pin them.
func TestIndexKeyCheckVector(t *testing.T) {
	k := iktUseKey(t)
	if want := "_RckOFqgx1tk-3jNYC-h2ZH96_drE8WO1wLqyDXp9hg"; indexKeyObjectKey != want {
		t.Fatalf("the seed-9 release key's public half is %q, want %q", indexKeyObjectKey, want)
	}
	const body = `{"schema":1,"seq":3,"issued":1767308400,"key":"iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=","revoked":["gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q="]}`
	const sig = "SFyptVarwlRTNfTb3ghLlNeMcmEPOGkgS3OcCH4vI4nbYjBUq62GfYns6X0bTnXUbCjvh3GYf9C5nGwDcuEAAQ"
	if got := base64.RawURLEncoding.EncodeToString(ed25519.Sign(k, []byte("nowhere-index-key-v1\x00"+body))); got != sig {
		t.Errorf("the signature computed here is %q, want %q", got, sig)
	}
	want := []byte("nowhere-index-key 1\n" + sig + "\n" + body)
	obj, env, err := indexKeyCheckFile(ikpFile(t, want), 1767312000)
	if err != nil {
		t.Fatalf("the vector is refused: %v", err)
	}
	if !bytes.Equal(env, want) {
		t.Errorf("the returned bytes are not the file: %q", env)
	}
	if obj.Seq != 3 || obj.Key != iktIndexKey(1) || !reflect.DeepEqual(obj.Revoked, []string{iktIndexKey(2)}) {
		t.Errorf("the vector reads as %+v, want seq 3, key %s, revoked [%s]", obj, iktIndexKey(1), iktIndexKey(2))
	}
}
