package main

// NWP-20261128-02: the store client's lazy setup returns what it read under its lock. Before this slice every caller of
// s3Init read s3client and s3bucket after s3Init had dropped s3InitMu, inside a retry closure, while applyStoreConf and
// applyManagedStore set s3client to nil under that lock (and wrote the S3_* environment outside it). A store switch
// during a store call was an unsynchronised read, a nil *minio.Client dereference, or one store's client paired with
// the other store's bucket.
//
// R1 (TestS3InitRace_StoreSwitchDuringStoreCalls) runs store calls against concurrent SET-STORE switches between two
// fake stores; run it with -race (test-race.sh, test-s3-init-race.sh). R2 (TestS3InitGlobalsOnlyInSetupAndResets) is
// the deterministic half: a go/ast scan that keeps the two globals inside s3Init and the two resets.

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
)

// s3irStore is a fake S3 store with one bucket. It answers HEAD of its bucket, HEAD/GET of an object (404 for one it
// does not hold) and PUT (200 with an ETag), and records "METHOD /path" of every request. It does not refuse a
// request for another bucket: the test reads the recorded paths, so a cross-store request is a named failure.
type s3irStore struct {
	name   string
	bucket string
	mu     sync.Mutex
	objs   map[string][]byte
	paths  []string
	srv    *httptest.Server
}

func newS3irStore(t *testing.T, name, bucket string) *s3irStore {
	t.Helper()
	s := &s3irStore{name: name, bucket: bucket, objs: map[string][]byte{}}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *s3irStore) serve(w http.ResponseWriter, r *http.Request) {
	var body []byte
	if r.Method == http.MethodPut {
		body, _ = io.ReadAll(r.Body)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.paths = append(s.paths, r.Method+" "+r.URL.Path)
	p := strings.TrimPrefix(r.URL.Path, "/")
	bk, key, _ := strings.Cut(p, "/")
	if key == "" { // the bucket itself
		if r.Method == http.MethodHead && bk == s.bucket {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
		return
	}
	switch r.Method {
	case http.MethodPut:
		s.objs[key] = body
		sum := md5.Sum(body)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.WriteHeader(http.StatusOK)
	case http.MethodHead, http.MethodGet:
		data, ok := s.objs[key]
		if !ok {
			if r.Method == http.MethodHead {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprintf(w, "<Error><Code>NoSuchKey</Code><Message>no such key</Message><Key>%s</Key><BucketName>%s</BucketName></Error>", key, bk)
			return
		}
		sum := md5.Sum(data)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		w.Header().Set("Last-Modified", time.Unix(1700000000, 0).UTC().Format(http.TimeFormat))
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodGet {
			w.Write(data)
		}
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *s3irStore) seen() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.paths...)
}

func (s *s3irStore) hold(key string, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.objs[key] = data
}

func (s *s3irStore) apply() error {
	return applyStoreConf(s.srv.URL, "us-east-1", s.bucket, "nwtest-ak-"+s.name, "nwtest-sk-"+s.name)
}

// checkOwnBucket: every request the store got names its own bucket, as /<bucket> or /<bucket>/<key>.
func (s *s3irStore) checkOwnBucket(t *testing.T) int {
	t.Helper()
	paths := s.seen()
	for _, p := range paths {
		_, path, _ := strings.Cut(p, " ")
		if path != "/"+s.bucket && !strings.HasPrefix(path, "/"+s.bucket+"/") {
			t.Errorf("store %s (bucket %s) got a request for another bucket: %q", s.name, s.bucket, p)
		}
	}
	return len(paths)
}

// TestS3InitRace_StoreSwitchDuringStoreCalls is R1. Workers call s3Exists, s3GetMax and s3PutGuarded in a loop while
// one more goroutine switches the store between A and B with applyStoreConf. PASS: no panic, no DATA RACE under -race,
// and every request each store got names that store's own bucket.
//
// applyManagedStore is NOT in the concurrent loop. It unsets every S3_* variable, so a store call made after it
// builds a client against an empty endpoint, and check() panics in s3Init by design (a managed daemon makes no
// direct-S3 call). That panic would fail the fixed code too. Its reset is the same guarded write; R2 holds it as one of
// the only writers, and the sequential phase below runs it with no store call in flight.
func TestS3InitRace_StoreSwitchDuringStoreCalls(t *testing.T) {
	a := newS3irStore(t, "a", "nwtest-s3ir-a")
	b := newS3irStore(t, "b", "nwtest-s3ir-b")
	for _, s := range []*s3irStore{a, b} {
		s.hold("k-held", []byte("held"))
	}

	oldConf, oldBase, oldRetry := storeConfPath, s3RetryBase, minio.MaxRetry
	oldClient, oldBucket := s3client, s3bucket
	storeConfPath = filepath.Join(t.TempDir(), "nowhere.conf")
	s3RetryBase, minio.MaxRetry = time.Millisecond, 1
	t.Cleanup(func() {
		storeConfPath, s3RetryBase, minio.MaxRetry = oldConf, oldBase, oldRetry
		s3client, s3bucket = oldClient, oldBucket
	})
	// t.Setenv restores each variable after the test, also after applyStoreConf/applyManagedStore wrote it.
	t.Setenv("S3_ENDPOINT", a.srv.URL)
	t.Setenv("S3_REGION", "us-east-1")
	t.Setenv("S3_BUCKET", a.bucket)
	t.Setenv("S3_ACCESS_KEY", "nwtest-ak-a")
	t.Setenv("S3_SECRET_KEY", "nwtest-sk-a")
	t.Setenv("GATEWAY_URL", "")
	s3client = nil

	const workers, iters, switches = 4, 150, 80
	var wg sync.WaitGroup
	call := func(w int) {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("worker %d panicked in a store call: %v\n%s", w, r, debug.Stack())
			}
		}()
		for i := 0; i < iters; i++ {
			s3Exists("k-held")
			s3Exists("k-miss")
			s3GetMax("k-held", 0)
			s3GetMax("k-miss", 0)
			if err := s3PutGuarded(fmt.Sprintf("k-put-%d-%d", w, i), []byte("put"), nil); err != nil {
				t.Errorf("worker %d: s3PutGuarded: %v", w, err)
				return
			}
		}
	}
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go call(w)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("the store switcher panicked: %v\n%s", r, debug.Stack())
			}
		}()
		for i := 0; i < switches; i++ {
			s := a
			if i%2 == 0 {
				s = b
			}
			if err := s.apply(); err != nil {
				t.Errorf("applyStoreConf(%s): %v", s.name, err)
				return
			}
		}
	}()
	wg.Wait()

	// Positive control: the switch really moved calls between the two stores.
	for _, s := range []*s3irStore{a, b} {
		if n := s.checkOwnBucket(t); n == 0 {
			t.Errorf("store %s got no request: the switch did not move a store call there", s.name)
		}
	}

	// Sequential managed phase: no store call is in flight.
	if err := applyManagedStore("http://127.0.0.1:1"); err != nil {
		t.Fatalf("applyManagedStore: %v", err)
	}
	if ep, gw := os.Getenv("S3_ENDPOINT"), os.Getenv("GATEWAY_URL"); ep != "" || gw == "" {
		t.Errorf("after applyManagedStore: S3_ENDPOINT=%q GATEWAY_URL=%q, want empty and set", ep, gw)
	}
	if s3client != nil {
		t.Errorf("applyManagedStore left the store client in place")
	}
	before := len(a.seen())
	if err := a.apply(); err != nil {
		t.Fatalf("applyStoreConf(a): %v", err)
	}
	t.Setenv("GATEWAY_URL", "")
	if !s3Exists("k-held") {
		t.Errorf("after the switch back to store a, s3Exists(k-held) = false")
	}
	if len(a.seen()) == before {
		t.Errorf("after the switch back to store a, store a got no request")
	}
	a.checkOwnBucket(t)
	b.checkOwnBucket(t)
}

// TestS3InitGlobalsOnlyInSetupAndResets is R2: in the package's non-test .go files, the identifiers s3client and
// s3bucket appear only inside s3Init, applyManagedStore and applyStoreConf, and in their own var declarations. Every
// other function must use the client and bucket that s3Init returns.
func TestS3InitGlobalsOnlyInSetupAndResets(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{"s3Init": true, "applyManagedStore": true, "applyStoreConf": true}
	globals := map[string]bool{"s3client": true, "s3bucket": true}
	named := map[string]map[string]bool{} // allowed function -> globals it names
	declared := map[string]bool{}
	fset := token.NewFileSet()
	scanned := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		scanned++
		for _, d := range af.Decls {
			switch d := d.(type) {
			case *ast.FuncDecl:
				fn := d.Name.Name
				hits := map[string]token.Pos{}
				ast.Inspect(d, func(n ast.Node) bool {
					if id, ok := n.(*ast.Ident); ok && globals[id.Name] {
						if _, seen := hits[id.Name]; !seen {
							hits[id.Name] = id.Pos()
						}
					}
					return true
				})
				if allowed[fn] && d.Recv == nil {
					if named[fn] == nil {
						named[fn] = map[string]bool{}
					}
					for g := range hits {
						named[fn][g] = true
					}
					continue
				}
				var gs []string
				for g := range hits {
					gs = append(gs, g)
				}
				sort.Strings(gs)
				for _, g := range gs {
					t.Errorf("%s: %s names %s; product code must use the client and bucket s3Init returns", fset.Position(hits[g]), fn, g)
				}
			case *ast.GenDecl:
				for _, sp := range d.Specs {
					ast.Inspect(sp, func(n ast.Node) bool {
						if vs, ok := n.(*ast.ValueSpec); ok && d.Tok == token.VAR {
							for _, nm := range vs.Names {
								if globals[nm.Name] {
									declared[nm.Name] = true
								}
							}
							for _, v := range vs.Values {
								ast.Inspect(v, func(m ast.Node) bool {
									if id, ok := m.(*ast.Ident); ok && globals[id.Name] {
										t.Errorf("%s: a top-level declaration names %s", fset.Position(id.Pos()), id.Name)
									}
									return true
								})
							}
							return false
						}
						if id, ok := n.(*ast.Ident); ok && globals[id.Name] {
							t.Errorf("%s: a top-level declaration names %s", fset.Position(id.Pos()), id.Name)
						}
						return true
					})
				}
			}
		}
	}
	// Positive controls: without them a scan of the wrong directory would pass with nothing found.
	if scanned == 0 {
		t.Fatal("no non-test .go file was scanned")
	}
	for g := range globals {
		if !declared[g] {
			t.Errorf("no top-level var declares %s: the scan read the wrong package", g)
		}
		if !named["s3Init"][g] {
			t.Errorf("s3Init does not name %s: the scan did not find the store client's setup", g)
		}
	}
	for _, fn := range []string{"applyManagedStore", "applyStoreConf"} {
		if !named[fn]["s3client"] {
			t.Errorf("%s does not name s3client: the scan did not find its reset", fn)
		}
	}
}
