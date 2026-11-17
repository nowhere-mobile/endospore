package main

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// NWP-20261205-07: copy-export copies an export folder into a store the user runs. These tests pin its order
// (preflight, folder check, blobs, refs, the manifest LAST, verify) and its refusals against a fake S3 store.

// cxeStore is a fake S3 store with one bucket, modeled on s3irStore (s3_init_race_test.go). It records
// "METHOD /bucket/key" of every request in order. dropKey answers that key's PUT 200 and keeps nothing; failPuts
// answers every PUT 503.
type cxeStore struct {
	bucket   string
	mu       sync.Mutex
	objs     map[string][]byte
	log      []string
	dropKey  string
	failPuts bool
	srv      *httptest.Server
}

func newCxeStore(t *testing.T, bucket string) *cxeStore {
	t.Helper()
	s := &cxeStore{bucket: bucket, objs: map[string][]byte{}}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *cxeStore) serve(w http.ResponseWriter, r *http.Request) {
	var body []byte
	if r.Method == http.MethodPut {
		body, _ = io.ReadAll(r.Body)
		if strings.HasPrefix(r.Header.Get("X-Amz-Content-Sha256"), "STREAMING-") {
			body = cxeUnchunk(body)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.log = append(s.log, r.Method+" "+r.URL.Path)
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
		if s.failPuts {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if key != s.dropKey {
			s.objs[key] = body
		}
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

// cxeUnchunk decodes an aws-chunked body ("<hex size>;chunk-signature=...\r\n<data>\r\n", ending in a 0-size
// chunk): minio-go streams a signed PUT that way over plain HTTP, and the store keeps only the data.
func cxeUnchunk(b []byte) []byte {
	var out []byte
	for len(b) > 0 {
		line, rest, ok := bytes.Cut(b, []byte("\r\n"))
		if !ok {
			break
		}
		hexSize, _, _ := bytes.Cut(line, []byte(";"))
		var n int
		if _, err := fmt.Sscanf(string(hexSize), "%x", &n); err != nil || n == 0 || n > len(rest) {
			break
		}
		out = append(out, rest[:n]...)
		b = bytes.TrimPrefix(rest[n:], []byte("\r\n"))
	}
	return out
}

func (s *cxeStore) hold(key string, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.objs[key] = data
}

func (s *cxeStore) obj(key string) ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.objs[key]
	return b, ok
}

func (s *cxeStore) seen() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.log...)
}

func (s *cxeStore) puts() []string {
	var out []string
	for _, l := range s.seen() {
		if strings.HasPrefix(l, "PUT ") {
			out = append(out, l)
		}
	}
	return out
}

// cxeEnv points the S3_* environment at s with the given keys and resets the store client for this test.
func cxeEnv(t *testing.T, s *cxeStore, ak, sk string) {
	t.Helper()
	oldBase, oldRetry := s3RetryBase, minio.MaxRetry
	s3InitMu.Lock()
	oldClient, oldBucket := s3client, s3bucket
	s3client = nil
	s3InitMu.Unlock()
	s3RetryBase, minio.MaxRetry = time.Millisecond, 1
	t.Cleanup(func() {
		s3RetryBase, minio.MaxRetry = oldBase, oldRetry
		s3InitMu.Lock()
		s3client, s3bucket = oldClient, oldBucket
		s3InitMu.Unlock()
	})
	t.Setenv("S3_ENDPOINT", s.srv.URL)
	t.Setenv("S3_REGION", "us-east-1")
	t.Setenv("S3_BUCKET", s.bucket)
	t.Setenv("S3_ACCESS_KEY", ak)
	t.Setenv("S3_SECRET_KEY", sk)
	t.Setenv("GATEWAY_URL", "")
}

func cxeHead(version uint64) []byte {
	return serializeVault(&vault{V: 1, Version: version, Slots: []keyslot{{Kind: "pass", Wrapped: "cxe"}}})
}

func cxeHash(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// cxeFolder writes an export folder in exportwalk.mjs writeFolder's layout: blob/<sha256>, ref/<name> holding the
// value (plus a trailing newline, as an exporter may write it) and manifest.json.
func cxeFolder(t *testing.T, blobs [][]byte, refs map[string]string) (string, *ExportManifest) {
	t.Helper()
	dir := t.TempDir()
	m := &ExportManifest{Version: exportManifestVersion}
	for _, b := range blobs {
		key := "blob/" + cxeHash(b)
		cxeWrite(t, filepath.Join(dir, filepath.FromSlash(key)), b)
		m.Blobs = append(m.Blobs, ManifestBlob{Key: key, Size: int64(len(b))})
	}
	var names []string
	for n := range refs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		cxeWrite(t, filepath.Join(dir, "ref", n), []byte(refs[n]+"\n"))
		m.Refs = append(m.Refs, ManifestRef{Key: "ref/" + n, Value: refs[n]})
	}
	cxeWriteManifest(t, dir, m)
	return dir, m
}

func cxeWrite(t *testing.T, p string, b []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func cxeWriteManifest(t *testing.T, dir string, m *ExportManifest) {
	t.Helper()
	mb, err := m.encode()
	if err != nil {
		t.Fatal(err)
	}
	cxeWrite(t, filepath.Join(dir, "manifest.json"), mb)
}

// cxeData is a 4 KiB data blob distinct per tag.
func cxeData(tag string) []byte {
	return bytes.Repeat([]byte("cxe-data-"+tag+"-"), 4096/len("cxe-data-"+tag+"-")+1)[:4096]
}

func cxeRun(t *testing.T, folder string, deep bool) (rc int, stdout, stderr string) {
	t.Helper()
	stderr = captureStderr(t, func() {
		stdout = captureStdout(t, func() { rc = runCopyExport("s3", folder, deep) })
	})
	return rc, stdout, stderr
}

// cxeStandardFolder is T3's folder: a v3 head and one 4 KiB data blob, under two refs.
func cxeStandardFolder(t *testing.T, tag string) (string, *ExportManifest, string) {
	t.Helper()
	head, data := cxeHead(3), cxeData(tag)
	dir, m := cxeFolder(t, [][]byte{head, data}, map[string]string{
		"cxe-" + tag + "-head": cxeHash(head),
		"cxe-" + tag + "-meta": cxeHash(head),
	})
	return dir, m, "blob/" + cxeHash(data)
}

func TestCopyExportRefusesANewerDestination(t *testing.T) {
	s := newCxeStore(t, "cxe-t1")
	cxeEnv(t, s, "cxe-ak", "cxe-sk")
	h9 := cxeHead(9)
	s.hold("blob/"+cxeHash(h9), h9)
	s.hold("ref/cxe-t1-head", []byte(cxeHash(h9)))
	h4 := cxeHead(4)
	dir, _ := cxeFolder(t, [][]byte{h4}, map[string]string{"cxe-t1-head": cxeHash(h4)})

	rc, out, errOut := cxeRun(t, dir, false)
	if rc != 2 {
		t.Fatalf("rc = %d, want 2 (a newer destination must be refused)\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	if !strings.Contains(out, "ROLL THE PROFILE BACK by 5") {
		t.Errorf("stdout does not name the rollback by 5 versions:\n%s", out)
	}
	if p := s.puts(); len(p) != 0 {
		t.Errorf("a refused copy wrote to the store: %v", p)
	}
}

func TestCopyExportRefusesAnOlderDestination(t *testing.T) {
	s := newCxeStore(t, "cxe-t2")
	cxeEnv(t, s, "cxe-ak", "cxe-sk")
	h2 := cxeHead(2)
	s.hold("blob/"+cxeHash(h2), h2)
	s.hold("ref/cxe-t2-head", []byte(cxeHash(h2)))
	h7 := cxeHead(7)
	dir, _ := cxeFolder(t, [][]byte{h7}, map[string]string{"cxe-t2-head": cxeHash(h7)})

	rc, out, errOut := cxeRun(t, dir, false)
	if rc != 2 {
		t.Fatalf("rc = %d, want 2 (an older destination must be refused)\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	if !strings.Contains(out, "STALE") {
		t.Errorf("stdout does not name the destination STALE:\n%s", out)
	}
	if p := s.puts(); len(p) != 0 {
		t.Errorf("a refused copy wrote to the store: %v", p)
	}
}

func TestCopyExportWritesTheManifestLast(t *testing.T) {
	s := newCxeStore(t, "cxe-t3")
	cxeEnv(t, s, "cxe-ak", "cxe-sk")
	dir, m, _ := cxeStandardFolder(t, "t3")

	rc, out, errOut := cxeRun(t, dir, false)
	if rc != 0 {
		t.Fatalf("rc = %d, want 0\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	if !strings.Contains(out, "copy-export: COMPLETE") {
		t.Errorf("stdout has no COMPLETE line:\n%s", out)
	}
	puts := s.puts()
	lastBlob, firstRef := -1, len(puts)
	manifestAt, manifests := -1, 0
	for i, p := range puts {
		switch {
		case strings.HasPrefix(p, "PUT /cxe-t3/blob/"):
			lastBlob = i
		case strings.HasPrefix(p, "PUT /cxe-t3/ref/"):
			if i < firstRef {
				firstRef = i
			}
		case p == "PUT /cxe-t3/manifest.json":
			manifestAt = i
			manifests++
		}
	}
	if lastBlob < 0 || firstRef == len(puts) || lastBlob > firstRef {
		t.Errorf("every blob PUT must come before every ref PUT: %v", puts)
	}
	if manifests != 1 || manifestAt != len(puts)-1 {
		t.Errorf("want exactly one manifest.json PUT, and it the last PUT: %v", puts)
	}
	log := s.seen()
	mIdx := -1
	for i, l := range log {
		if l == "PUT /cxe-t3/manifest.json" {
			mIdx = i
		}
	}
	verified := false
	for _, l := range log[mIdx+1:] {
		if strings.HasPrefix(l, "HEAD /cxe-t3/") || strings.HasPrefix(l, "GET /cxe-t3/") {
			verified = true
		}
	}
	if mIdx < 0 || !verified {
		t.Errorf("no read of the destination after the manifest PUT (verify-manifest did not run): %v", log)
	}
	for _, b := range m.Blobs {
		want, _ := os.ReadFile(filepath.Join(dir, filepath.FromSlash(b.Key)))
		if got, ok := s.obj(b.Key); !ok || !bytes.Equal(got, want) {
			t.Errorf("%s is not byte-equal to the folder's file", b.Key)
		}
	}
	for _, r := range m.Refs {
		if got, ok := s.obj(r.Key); !ok || string(got) != r.Value {
			t.Errorf("%s = %q, want %q", r.Key, got, r.Value)
		}
	}
	wantM, _ := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if got, ok := s.obj("manifest.json"); !ok || !bytes.Equal(got, wantM) {
		t.Errorf("manifest.json is not the folder's bytes verbatim")
	}
}

func TestCopyExportFailsWhenVerifyFails(t *testing.T) {
	s := newCxeStore(t, "cxe-t4")
	cxeEnv(t, s, "cxe-ak", "cxe-sk")
	dir, _, dataKey := cxeStandardFolder(t, "t4")
	s.dropKey = dataKey

	rc, out, errOut := cxeRun(t, dir, false)
	if rc != 2 {
		t.Fatalf("rc = %d, want 2 (verify must fail on a dropped blob)\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	if !strings.Contains(errOut, "INCOMPLETE") {
		t.Errorf("stderr has no INCOMPLETE line:\n%s", errOut)
	}
	i := strings.Index(out, "MISSING blobs")
	if i < 0 || !strings.Contains(out[i:], dataKey) {
		t.Errorf("stdout does not list %s under MISSING blobs:\n%s", dataKey, out)
	}
}

func TestCopyExportRerunIsRepeatable(t *testing.T) {
	s := newCxeStore(t, "cxe-t5")
	cxeEnv(t, s, "cxe-ak", "cxe-sk")
	dir, _, _ := cxeStandardFolder(t, "t5")

	if rc, out, errOut := cxeRun(t, dir, false); rc != 0 {
		t.Fatalf("first run rc = %d, want 0\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	n := len(s.seen())
	rc, out, errOut := cxeRun(t, dir, false)
	if rc != 0 {
		t.Fatalf("second run rc = %d, want 0 (a re-run must stay repeatable)\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	for _, l := range s.seen()[n:] {
		if strings.HasPrefix(l, "PUT /cxe-t5/blob/") {
			t.Errorf("the second run wrote a blob already present at its full length: %s", l)
		}
	}
}

func TestCopyExportReplacesATruncatedObject(t *testing.T) {
	s := newCxeStore(t, "cxe-t6")
	cxeEnv(t, s, "cxe-ak", "cxe-sk")
	dir, _, dataKey := cxeStandardFolder(t, "t6")
	want, _ := os.ReadFile(filepath.Join(dir, filepath.FromSlash(dataKey)))
	s.hold(dataKey, want[:len(want)-3])

	rc, out, errOut := cxeRun(t, dir, false)
	if rc != 0 {
		t.Fatalf("rc = %d, want 0\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
	}
	put := false
	for _, p := range s.puts() {
		if p == "PUT /cxe-t6/"+dataKey {
			put = true
		}
	}
	if !put {
		t.Errorf("the truncated %s was not written again: %v", dataKey, s.puts())
	}
	if got, _ := s.obj(dataKey); !bytes.Equal(got, want) {
		t.Errorf("%s holds %d bytes, want the folder's %d", dataKey, len(got), len(want))
	}
}

func TestCopyExportRefusesAShortFolder(t *testing.T) {
	cases := []struct {
		name  string
		spoil func(t *testing.T, dir string, m *ExportManifest, dataKey string)
	}{
		{"a blob file missing", func(t *testing.T, dir string, m *ExportManifest, dataKey string) {
			if err := os.Remove(filepath.Join(dir, filepath.FromSlash(dataKey))); err != nil {
				t.Fatal(err)
			}
		}},
		{"a blob byte changed", func(t *testing.T, dir string, m *ExportManifest, dataKey string) {
			p := filepath.Join(dir, filepath.FromSlash(dataKey))
			b, _ := os.ReadFile(p)
			b[100] ^= 0x01
			cxeWrite(t, p, b)
		}},
		{"a manifest size off by one", func(t *testing.T, dir string, m *ExportManifest, dataKey string) {
			for i := range m.Blobs {
				if m.Blobs[i].Key == dataKey {
					m.Blobs[i].Size++
				}
			}
			cxeWriteManifest(t, dir, m)
		}},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newCxeStore(t, fmt.Sprintf("cxe-t7-%d", i))
			cxeEnv(t, s, "cxe-ak", "cxe-sk")
			dir, m, dataKey := cxeStandardFolder(t, fmt.Sprintf("t7%d", i))
			c.spoil(t, dir, m, dataKey)
			rc, out, errOut := cxeRun(t, dir, false)
			if rc != 2 {
				t.Fatalf("rc = %d, want 2\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
			}
			if p := s.puts(); len(p) != 0 {
				t.Errorf("a short folder was written to the store: %v", p)
			}
			if !strings.Contains(errOut, dataKey) {
				t.Errorf("stderr does not name %s:\n%s", dataKey, errOut)
			}
		})
	}
}

func TestCopyExportRefusesWithoutTheUsersKeys(t *testing.T) {
	var gwHits int64
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&gwHits, 1)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(gw.Close)

	t.Run("our gateway, no access key", func(t *testing.T) {
		s := newCxeStore(t, "cxe-t8a")
		cxeEnv(t, s, "", "cxe-sk")
		t.Setenv("GATEWAY_URL", gw.URL)
		dir, _, _ := cxeStandardFolder(t, "t8a")
		rc, out, errOut := cxeRun(t, dir, false)
		if rc != 2 {
			t.Fatalf("rc = %d, want 2\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
		}
		if !strings.Contains(errOut, "GATEWAY_URL") {
			t.Errorf("stderr does not name the gateway refusal:\n%s", errOut)
		}
		if l := s.seen(); len(l) != 0 {
			t.Errorf("the store got requests: %v", l)
		}
	})
	t.Run("a base that is not s3", func(t *testing.T) {
		s := newCxeStore(t, "cxe-t8b")
		cxeEnv(t, s, "cxe-ak", "cxe-sk")
		dir, _, _ := cxeStandardFolder(t, "t8b")
		var rc int
		errOut := captureStderr(t, func() {
			captureStdout(t, func() { rc = runCopyExport(s.srv.URL, dir, false) })
		})
		if rc != 2 {
			t.Fatalf("rc = %d, want 2\nstderr:\n%s", rc, errOut)
		}
		if l := s.seen(); len(l) != 0 {
			t.Errorf("the store got requests: %v", l)
		}
	})
	if n := atomic.LoadInt64(&gwHits); n != 0 {
		t.Errorf("the gateway got %d request(s)", n)
	}
}

func TestCopyExportRefusesAKeyOutsideTheFolder(t *testing.T) {
	cases := []struct {
		name string
		m    func(head string) *ExportManifest
		key  string
	}{
		{"a blob key with ..", func(head string) *ExportManifest {
			return &ExportManifest{Version: exportManifestVersion,
				Blobs: []ManifestBlob{{Key: "blob/../x", Size: 1}},
				Refs:  []ManifestRef{{Key: "ref/cxe-t9a-head", Value: head}}}
		}, "blob/../x"},
		{"a ref key with ..", func(head string) *ExportManifest {
			return &ExportManifest{Version: exportManifestVersion,
				Refs: []ManifestRef{{Key: "ref/cxe-t9b-head", Value: head}, {Key: "ref/../../etc/x", Value: head}}}
		}, "ref/../../etc/x"},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newCxeStore(t, fmt.Sprintf("cxe-t9-%d", i))
			cxeEnv(t, s, "cxe-ak", "cxe-sk")
			dir := t.TempDir()
			cxeWriteManifest(t, dir, c.m(cxeHash(cxeHead(1))))
			rc, out, errOut := cxeRun(t, dir, false)
			if rc != 2 {
				t.Fatalf("rc = %d, want 2\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
			}
			if l := s.seen(); len(l) != 0 {
				t.Errorf("the store got requests: %v", l)
			}
			if !strings.Contains(errOut, fmt.Sprintf("%q", c.key)) {
				t.Errorf("stderr does not name the key %q:\n%s", c.key, errOut)
			}
		})
	}
}

func TestCopyExportNeverPrintsTheStoreKeys(t *testing.T) {
	const ak, sk = "cxe-ak-7f3a91d2", "cxe-sk-91c2e8b4"
	check := func(t *testing.T, outs ...string) {
		t.Helper()
		for _, o := range outs {
			if strings.Contains(o, ak) || strings.Contains(o, sk) {
				t.Errorf("a store key value was printed:\n%s", o)
			}
		}
	}
	t.Run("a passing run", func(t *testing.T) {
		s := newCxeStore(t, "cxe-t10a")
		cxeEnv(t, s, ak, sk)
		dir, _, _ := cxeStandardFolder(t, "t10a")
		rc, out, errOut := cxeRun(t, dir, false)
		if rc != 0 {
			t.Fatalf("rc = %d, want 0\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
		}
		check(t, out, errOut)
	})
	t.Run("every PUT refused", func(t *testing.T) {
		s := newCxeStore(t, "cxe-t10b")
		s.failPuts = true
		cxeEnv(t, s, ak, sk)
		dir, _, _ := cxeStandardFolder(t, "t10b")
		rc, out, errOut := cxeRun(t, dir, false)
		if rc != 2 {
			t.Fatalf("rc = %d, want 2\nstdout:\n%s\nstderr:\n%s", rc, out, errOut)
		}
		if !strings.Contains(errOut, "the store refused or did not answer the blob write of blob/") {
			t.Errorf("stderr has no fixed write-failure line:\n%s", errOut)
		}
		check(t, out, errOut)
	})
}

// cxeFailRT passes a request through to the fake store unless fail says otherwise; then it fails in transport
// with an error that carries the request URL, the endpoint and the access key, as a real transport error may.
type cxeFailRT struct {
	ak      string
	mu      sync.Mutex
	sawMfst bool
	fail    func(r *http.Request, afterManifest bool) bool
}

func (rt *cxeFailRT) RoundTrip(r *http.Request) (*http.Response, error) {
	rt.mu.Lock()
	after := rt.sawMfst
	if r.Method == http.MethodPut && strings.HasSuffix(r.URL.Path, "/manifest.json") {
		rt.sawMfst = true
	}
	rt.mu.Unlock()
	if rt.fail(r, after) {
		return nil, fmt.Errorf("dial %s: connection refused (credential %s/us-east-1/s3)", r.URL.String(), rt.ak)
	}
	return http.DefaultTransport.RoundTrip(r)
}

// TestCopyExportNeverPrintsAStoreDiagnostic pins RF-001: the store path's own retry lines print a store error with
// its endpoint and anything else the error carries. Every store call the verb makes -- the preflight reads, the
// size STAT, the writes, the verify reads -- must print only the verb's fixed lines.
func TestCopyExportNeverPrintsAStoreDiagnostic(t *testing.T) {
	const ak, sk = "cxe-ak-5b0e27c4", "cxe-sk-d61f0a93"
	cases := []struct {
		name   string
		wantRC int
		fail   func(r *http.Request, afterManifest bool) bool
	}{
		{"the preflight reads", 2, func(r *http.Request, _ bool) bool { return true }},
		{"the size STAT", 0, func(r *http.Request, after bool) bool {
			return !after && r.Method == http.MethodHead && strings.Contains(r.URL.Path, "/blob/")
		}},
		{"the writes", 2, func(r *http.Request, _ bool) bool { return r.Method == http.MethodPut }},
		{"the verify reads", 2, func(r *http.Request, after bool) bool { return after && r.Method != http.MethodPut }},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newCxeStore(t, fmt.Sprintf("cxe-t11-%d", i))
			cxeEnv(t, s, ak, sk)
			host := strings.TrimPrefix(s.srv.URL, "http://")
			cl, err := minio.New(host, &minio.Options{
				Creds:     credentials.NewStaticV4(ak, sk, ""),
				Region:    "us-east-1",
				Transport: &cxeFailRT{ak: ak, fail: c.fail},
			})
			if err != nil {
				t.Fatal(err)
			}
			s3InitMu.Lock()
			s3client, s3bucket = cl, s.bucket
			s3InitMu.Unlock()
			dir, _, _ := cxeStandardFolder(t, fmt.Sprintf("t11%d", i))
			rc, out, errOut := cxeRun(t, dir, false)
			if rc != c.wantRC {
				t.Fatalf("rc = %d, want %d\nstdout:\n%s\nstderr:\n%s", rc, c.wantRC, out, errOut)
			}
			for _, o := range []string{out, errOut} {
				for _, secret := range []string{ak, sk, host, "connection refused"} {
					if strings.Contains(o, secret) {
						t.Errorf("a store diagnostic (%q) was printed:\n%s", secret, o)
					}
				}
			}
		})
	}
}
