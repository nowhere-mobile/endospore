package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261013-05: NWP-20261006-21 marked a store read that fails in transport unreachable, so a sign-in that
// cannot reach the store exits exitStoreUnreachable and the gate offers a retry, never the rollback. Its device
// proof FAILED on lynx 2026101302: Wi-Fi was cut during a sign-in's CHUNK download, and the restore exited 1
// (`ERR: fetch chunk 178: Post ...: dial tcp: lookup ... network is unreachable`), because cdcRestore's fetcher
// rebuilt the recovered storeReadErr with %v and the chain was gone before it reached exitStatus. These tests cut
// the network on a CHUNK (the head reads all succeed) and follow the error the whole way: fetcher -> ordered
// writer -> pipe -> untar -> main's recover -> exitStatus. And the control: a chunk that arrives but is damaged
// still exits 1, so the rollback stays on offer for real damage.

// faultyStore fronts a newHTTPStore: a GET of a blob in cut has its connection closed with no response (a
// transport failure), a GET of a blob in damage gets 200 with the wrong bytes; everything else is proxied.
func faultyStore(t *testing.T, inner string, cut, damage map[string]bool) string {
	t.Helper()
	u, err := url.Parse(inner)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := strings.TrimPrefix(r.URL.Path, "/blob/")
		switch {
		case r.Method == "GET" && h != r.URL.Path && cut[h]:
			c, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				c.Close()
			}
		case r.Method == "GET" && h != r.URL.Path && damage[h]:
			w.Write([]byte("not the bytes this content address names"))
		default:
			proxy.ServeHTTP(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// sealedForCut seals a profile whose data spans several chunks into a fresh store and returns that store, the
// profile's data key and its manifest. The large file comes first, so a middle chunk lies inside its body.
func sealedForCut(t *testing.T, name, pass string) (string, []byte, chunkManifest) {
	t.Helper()
	oc, rb := chunkCacheDir, s3RetryBase
	chunkCacheDir, s3RetryBase = "", time.Millisecond // every chunk from the store; corrupt refetches fast
	t.Cleanup(func() { chunkCacheDir, s3RetryBase = oc, rb })
	base := newHTTPStore(t)
	createVault(base, name, pass)
	src := t.TempDir()
	big := make([]byte, 6<<20)
	if _, err := rand.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "a-big.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "b-small.txt"), []byte("after the big one"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	key, mb, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("resolveKey failed after the push")
	}
	pt := unseal(key, mb)
	if !bytes.HasPrefix(pt, cdcMagic) {
		t.Fatal("head is not a CDC manifest")
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		t.Fatal(err)
	}
	if len(m.Chunks) < 3 {
		t.Fatalf("need at least 3 chunks so one can fail mid-file, got %d", len(m.Chunks))
	}
	return base, key, m
}

func TestAChunkCutInTransportExitsStoreUnreachable(t *testing.T) {
	base, key, m := sealedForCut(t, "chunkcut", "chunk cut horse battery staple")
	for what, i := range map[string]int{
		"the first chunk (the untar's first header read)":     0,
		"a middle chunk (inside a file the untar is copying)": len(m.Chunks) / 2,
		"the last chunk": len(m.Chunks) - 1,
	} {
		front := faultyStore(t, base, map[string]bool{m.Chunks[i]: true}, nil)
		r := panicOf(func() { cdcRestore(front, key, m, t.TempDir()) })
		if r == nil {
			t.Fatalf("%s: a restore whose chunk could not be fetched did not fail", what)
		}
		if e, _ := r.(error); !errors.Is(e, errStoreUnreachable) {
			t.Errorf("%s: the restore failed with %v (%T), which is not errStoreUnreachable: the gate would offer the rollback for a network error", what, r, r)
		}
		if got := exitStatus(r); got != exitStoreUnreachable {
			t.Errorf("%s: exits %d, want exitStoreUnreachable (%d)", what, got, exitStoreUnreachable)
		}
	}
}

// The control. A chunk that ARRIVES and is wrong -- corrupt in the store, unsealing under the wrong key, or failing
// to decompress -- is the stored copy failing, and must keep exit 1 so the gate still offers the rollback.
func TestADamagedChunkIsNotUnreachable(t *testing.T) {
	base, key, m := sealedForCut(t, "chunkdmg", "chunk damage horse battery staple")
	mid := len(m.Chunks) / 2
	wrongKey := make([]byte, len(key))
	copy(wrongKey, key)
	wrongKey[0] ^= 0xff
	t.Setenv("NOWHERE_COMPRESS", "0")
	v1base, v1key, v1 := sealedForCut(t, "chunkraw", "chunk raw horse battery staple")
	v1.Version = 2 // the chunks are raw tar: zstd refuses them
	for what, f := range map[string]func(){
		"a chunk corrupt in the store": func() {
			cdcRestore(faultyStore(t, base, nil, map[string]bool{m.Chunks[mid]: true}), key, m, t.TempDir())
		},
		"a chunk that does not unseal":     func() { cdcRestore(base, wrongKey, m, t.TempDir()) },
		"a chunk that does not decompress": func() { cdcRestore(v1base, v1key, v1, t.TempDir()) },
	} {
		r := panicOf(f)
		if r == nil {
			t.Fatalf("control: %s did not fail the restore", what)
		}
		if e, _ := r.(error); errors.Is(e, errStoreUnreachable) {
			t.Errorf("%s was marked unreachable (%v): the gate would hide the rollback from a damaged save", what, r)
		}
		if got := exitStatus(r); got != 1 {
			t.Errorf("%s exits %d, want 1", what, got)
		}
	}
}

// TestRestoreVerbHelperProcess is not a test: it is the agent, re-executed from the test binary by
// TestTheRestoreVerbExitsStoreUnreachableOnAChunkCut, running the real `restore` verb through main() so the exit
// code is the one roamd reads.
func TestRestoreVerbHelperProcess(t *testing.T) {
	a := os.Getenv("NOWHERE_RESTORE_VERB_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent", "restore"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

// The whole path, in the process roamd runs: `restore` against a store whose head reads all succeed and one chunk
// GET loses its connection. The exit code is what roamd turns into BLANK NET (5) or BLANK (anything else).
func TestTheRestoreVerbExitsStoreUnreachableOnAChunkCut(t *testing.T) {
	name, pass := "chunkverb", "chunk verb horse battery staple"
	base, _, m := sealedForCut(t, name, pass)
	mid := len(m.Chunks) / 2
	run := func(store string) (int, string) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestRestoreVerbHelperProcess$", "-test.count=1")
		env := []string{"NOWHERE_RESTORE_VERB_HELPER=" + strings.Join([]string{store, name, pass, t.TempDir()}, "\n")}
		for _, kv := range os.Environ() {
			k := kv[:strings.IndexByte(kv+"=", '=')]
			switch k {
			case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS":
				continue // a plain-HTTP store, no cache, no session state
			}
			env = append(env, kv)
		}
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		if err == nil {
			return 0, string(out)
		}
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("running the agent: %v", err)
		}
		return ee.ExitCode(), string(out)
	}
	if code, out := run(faultyStore(t, base, map[string]bool{m.Chunks[mid]: true}, nil)); code != exitStoreUnreachable {
		t.Errorf("restore with a chunk cut in transport exited %d, want exitStoreUnreachable (%d): roamd answers BLANK and the gate offers the rollback\n%s", code, exitStoreUnreachable, out)
	} else if !strings.Contains(out, "ERR: fetch chunk") {
		t.Errorf("control: the failure was not the chunk fetch\n%s", out)
	}
	if code, out := run(faultyStore(t, base, nil, map[string]bool{m.Chunks[mid]: true})); code != 1 {
		t.Errorf("control: restore with a chunk corrupt in the store exited %d, want 1\n%s", code, out)
	}
	if code, out := run(base); code != 0 {
		t.Errorf("control: restore from a healthy store exited %d, want 0\n%s", code, out)
	}
}

// The other recovers that wrap a store read in a goroutine keep the chain too: the deferred-file heal and the
// on-demand app fetch (healFetchOrdered), and mediad's two fetches. None of their callers classifies on
// errStoreUnreachable today (the heal never fails the restore; restore-app exits 1 on any error; mediad splits
// corrupt from transient by MESSAGE, isCorruptErr). %w leaves that message byte-identical, so the split is unchanged.
func TestRecoveredStoreReadsKeepTheirChain(t *testing.T) {
	oc := chunkCacheDir
	chunkCacheDir = ""
	t.Cleanup(func() { chunkCacheDir = oc })
	dead := deadStore(t)
	h := strings.Repeat("ab", 32)
	key := make([]byte, 32)
	wantUnreachable := func(what string, err error) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s against a refused dial did not fail", what)
		}
		if !errors.Is(err, errStoreUnreachable) {
			t.Errorf("%s: %v lost errStoreUnreachable", what, err)
		}
		if isCorruptErr(err) {
			t.Errorf("%s: a transport failure reads as corrupt to mediad: %v", what, err)
		}
	}
	wantUnreachable("healFetchOrdered", healFetchOrdered(dead, key, 2, []string{h}, func([]byte) error { return nil }))
	d := deferredFile{Chunks: []string{h}, Pz: []int64{1}, Size: 1}
	s := &mediaServer{base: dead, dk: key, version: 2, cacheDir: t.TempDir()}
	wantUnreachable("mediad fetchToCache", s.fetchToCache("x/y.bin", d, filepath.Join(t.TempDir(), "y")))
	wantUnreachable("mediad fetchChunkAt", s.fetchChunkAt(filepath.Join(t.TempDir(), "y.part"), d, []int64{0}, 0))

	// recoveredErr itself: an error keeps its chain and its text; anything else keeps %v.
	in := storeReadErr{errors.New("dial tcp: network is unreachable")}
	if e := recoveredErr("fetch chunk 7", in); !errors.Is(e, errStoreUnreachable) || e.Error() != "fetch chunk 7: dial tcp: network is unreachable" {
		t.Errorf("recoveredErr(error) = %q, chain kept %v", e, errors.Is(e, errStoreUnreachable))
	}
	if e := recoveredErr("fetch chunk 7", "corrupt chunk in store: blob/x"); e.Error() != "fetch chunk 7: corrupt chunk in store: blob/x" || errors.Is(e, errStoreUnreachable) {
		t.Errorf("recoveredErr(string) = %q", e)
	}
}
