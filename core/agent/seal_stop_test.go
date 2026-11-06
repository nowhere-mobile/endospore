package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// h47 #1 part 1 (NWP-20261117-01, seal_stop.go): a push that may stop ends at its next chunk boundary when
// $NOWHERE_STATE/.sealstop exists, never once its pointer pass has begun. test-seal-stop.sh --mutate breaks each
// check point in turn.

// sealStopSetup makes this test's push stoppable (or not) and restores the process globals after it.
func sealStopSetup(t *testing.T, stoppable bool) {
	t.Helper()
	t.Setenv("NOWHERE_SEAL_UPLOAD_WORKERS", "1")
	was := sealStoppable
	sealStoppable = stoppable
	sealStopped.Store(false)
	t.Cleanup(func() {
		sealStoppable = was
		sealStopped.Store(false)
		sealChunkDispatchHook = nil
	})
}

func raiseSealStop(t *testing.T, state string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(state, sealStopFile), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

// sealStopWalkStore is newHTTPStore behind a proxy that counts POST /blob, a direct-mode vault for name/pass in it,
// and a source tree of several files.
func sealStopWalkStore(t *testing.T, name, pass string) (base, src string, posts *atomic.Int64) {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	blobCache, contentCache = nil, nil
	inner := newHTTPStore(t)
	u, err := url.Parse(inner)
	if err != nil {
		t.Fatal(err)
	}
	posts = new(atomic.Int64)
	rp := httputil.NewSingleHostReverseProxy(u)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/blob" {
			posts.Add(1)
		}
		rp.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	base = srv.URL
	createVault(base, name, pass)
	src = t.TempDir()
	for i, body := range []string{"one file of a session", "a second file", "and a third one"} {
		if err := os.WriteFile(filepath.Join(src, string(rune('a'+i))+".txt"), []byte(strings.Repeat(body, 64)), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return base, src, posts
}

// sealStopSummary is in both of pushProfile's summary lines and in nothing a stopped push prints.
const sealStopSummary = " chunks ("

func TestSealStopWalkBeforeTheFirstChunk(t *testing.T) {
	name, pass := "sealstopwalk", "seal stop walk horse battery staple"
	sealStopSetup(t, true)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	base, src, posts := sealStopWalkStore(t, name, pass)
	before := getRef(base, headKey(base, name, pass))
	posts.Store(0)
	var dispatched atomic.Int64
	sealChunkDispatchHook = func() { dispatched.Add(1) }
	raiseSealStop(t, state)
	out := captureStdout(t, func() { pushProfile(base, name, pass, src) })
	if n := dispatched.Load(); n > 1 {
		t.Errorf("the walk dispatched %d chunks after a stop was requested, want at most 1", n)
	}
	if n := posts.Load(); n != 0 {
		t.Errorf("%d blob(s) were written after a stop was requested, want none", n)
	}
	if after := getRef(base, headKey(base, name, pass)); after != before {
		t.Errorf("the head moved on a stopped seal: %q -> %q", before, after)
	}
	if !sealStopped.Load() {
		t.Error("sealStopped is false after a walk-phase stop")
	}
	if !strings.Contains(out, "seal STOPPED at a chunk boundary -- a stop was requested; no head published (h47 #1)") {
		t.Errorf("no STOPPED line in the push's output:\n%s", out)
	}
	if strings.Contains(out, sealStopSummary) {
		t.Errorf("a stopped push printed its summary:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(state, sealStopFile)); err != nil {
		t.Errorf("the agent removed the request file: %v", err)
	}
}

// Control: the same file in a push that may not stop (cleanstorage's #keys push) changes nothing.
func TestSealStopNotStoppableIgnoresTheFile(t *testing.T) {
	name, pass := "sealstopnot", "seal stop not stoppable horse battery"
	sealStopSetup(t, false)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	base, src, posts := sealStopWalkStore(t, name, pass)
	before := getRef(base, headKey(base, name, pass))
	posts.Store(0)
	raiseSealStop(t, state)
	out := captureStdout(t, func() { pushProfile(base, name, pass, src) })
	if after := getRef(base, headKey(base, name, pass)); after == before {
		t.Error("a push that may not stop did not publish a new head")
	}
	if posts.Load() == 0 {
		t.Error("a push that may not stop wrote no blob")
	}
	if !strings.Contains(out, sealStopSummary) {
		t.Errorf("a push that may not stop printed no summary:\n%s", out)
	}
	if sealStopped.Load() || strings.Contains(out, "STOPPED") {
		t.Errorf("a push that may not stop reported a stop:\n%s", out)
	}
}

// sealStopGateway is newBatchGateway with hook run (under no lock) before each request reaches it.
func sealStopGateway(t *testing.T, hook func(r *http.Request)) *batchGateway {
	t.Helper()
	sealStopSetup(t, true)
	g := newBatchGateway(t)
	h := g.srv.Config.Handler
	g.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hook(r)
		h.ServeHTTP(w, r)
	})
	batchFixture(t, g, 1, 0, 0)
	return g
}

func objKey(r *http.Request) string {
	if r.Method != http.MethodPut || r.URL.Path != "/obj" {
		return ""
	}
	return r.URL.Query().Get("k")
}

func countPrefix(keys []string, p string) int {
	n := 0
	for _, k := range keys {
		if strings.HasPrefix(k, p) {
			n++
		}
	}
	return n
}

func TestSealStopQuoteRaisesIt(t *testing.T) {
	var g *batchGateway
	g = sealStopGateway(t, func(r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/quote" {
			raiseSealStop(t, os.Getenv("NOWHERE_STATE"))
		}
	})
	if rec := batchSeal(t, "sealstopquote", "seal stop at the quote horse", 4, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	leases, puts := g.snapshot()
	if n := len(leases) + len(g.freeSnapshot()); n != 0 {
		t.Errorf("%d /lease request(s) after a stop raised at the /quote, want none", n)
	}
	if len(puts) != 0 {
		t.Errorf("PUTs after a stop raised at the /quote: %v", puts)
	}
	if !sealStopped.Load() {
		t.Error("sealStopped is false")
	}
}

func TestSealStopSecondBlobPut(t *testing.T) {
	name, pass := "sealstopblob", "seal stop at the second blob horse"
	var mu sync.Mutex
	blobs := 0
	arm := true
	g := sealStopGateway(t, func(r *http.Request) {
		if !strings.HasPrefix(objKey(r), "blob/") {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if blobs++; blobs == 2 && arm {
			raiseSealStop(t, os.Getenv("NOWHERE_STATE"))
		}
	})
	if rec := batchSeal(t, name, pass, 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	_, puts := g.snapshot()
	if n := countPrefix(puts, "blob/"); n != 2 {
		t.Errorf("%d blob PUT(s) began, want 2 (no further PUT after the stop): %v", n, puts)
	}
	if n := countPrefix(puts, "ref/"); n != 0 {
		t.Errorf("%d ref PUT(s) on a stopped flush, want none: %v", n, puts)
	}
	if !sealStopped.Load() {
		t.Error("sealStopped is false")
	}
	first := append([]string(nil), puts...)
	// The next flush, with the request gone, completes and does not send the two blobs again.
	mu.Lock()
	arm = false
	mu.Unlock()
	if err := os.Remove(filepath.Join(os.Getenv("NOWHERE_STATE"), sealStopFile)); err != nil {
		t.Fatal(err)
	}
	sealStopped.Store(false)
	if rec := batchSeal(t, name, pass, 5, nil, nil); rec != nil {
		t.Fatalf("the second flush failed: %v", rec)
	}
	_, puts = g.snapshot()
	again := puts[len(first):]
	if countPrefix(again, "ref/") == 0 {
		t.Errorf("the second flush PUT no pointer: %v", again)
	}
	for _, k := range first {
		for _, a := range again {
			if a == k {
				t.Errorf("the second flush sent %s again", k)
			}
		}
	}
	if sealStopped.Load() {
		t.Error("the second flush reported a stop")
	}
}

func TestSealStopIgnoredInThePointerPass(t *testing.T) {
	var once sync.Once
	g := sealStopGateway(t, func(r *http.Request) {
		if strings.HasPrefix(objKey(r), "ref/") {
			once.Do(func() { raiseSealStop(t, os.Getenv("NOWHERE_STATE")) })
		}
	})
	if rec := batchSeal(t, "sealstopptr", "seal stop in the pointer pass horse", 3, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	leases, puts := g.snapshot()
	put := map[string]bool{}
	for _, k := range puts {
		put[k] = true
	}
	refs := 0
	for _, l := range leases {
		for k := range l.Refs {
			if strings.HasPrefix(k, "ref/") {
				refs++
				if !put[k] {
					t.Errorf("pointer %s was leased but not PUT: a stop inside the pointer pass was honoured", k)
				}
			}
		}
	}
	if refs < 2 {
		t.Fatalf("the flush leased %d pointer(s), want at least 2 so a stop could fall between them", refs)
	}
	if sealStopped.Load() {
		t.Error("sealStopped is true: a stop raised in the pointer pass must be ignored")
	}
}

// The parallel upload path: the dispatcher and each worker ask before a PUT, so only PUTs in flight finish.
func TestSealStopParallelUpload(t *testing.T) {
	var once sync.Once
	g := sealStopGateway(t, func(r *http.Request) {
		if strings.HasPrefix(objKey(r), "blob/") {
			once.Do(func() { raiseSealStop(t, os.Getenv("NOWHERE_STATE")) })
		}
	})
	t.Setenv("NOWHERE_SEAL_UPLOAD_WORKERS", "4")
	const n = 40
	if rec := batchSeal(t, "sealstoppar", "seal stop parallel upload horse", n, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	_, puts := g.snapshot()
	if c := countPrefix(puts, "blob/"); c >= n {
		t.Errorf("%d blob PUT(s) of %d began after a stop at the first: the parallel path did not stop", c, n)
	}
	if c := countPrefix(puts, "ref/"); c != 0 {
		t.Errorf("%d ref PUT(s) on a stopped parallel flush, want none", c)
	}
}

// Through the real verb: exit 7 and no head with NOWHERE_SEAL_STOPPABLE=1; without it, exit 0 and a new head.
func TestSealStopPushVerbExits7(t *testing.T) {
	name, pass := "sealstopverb", "seal stop push verb horse battery"
	t.Setenv("GATEWAY_URL", "")
	live := newHTTPStore(t)
	createVault(live, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("a session's data, standing in"), 0o600); err != nil {
		t.Fatal(err)
	}
	state := t.TempDir()
	raiseSealStop(t, state)
	run := func(stoppable bool) (int, string) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestPushVerbHelperProcess$", "-test.count=1")
		env := []string{"NOWHERE_PUSH_VERB_HELPER=" + strings.Join([]string{live, name, pass, src}, "\n")}
		for _, kv := range os.Environ() {
			k := kv[:strings.IndexByte(kv+"=", '=')]
			switch k {
			case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS", "NOWHERE_SEAL_STOPPABLE":
				continue
			}
			env = append(env, kv)
		}
		env = append(env, "NOWHERE_STATE="+state)
		if stoppable {
			env = append(env, "NOWHERE_SEAL_STOPPABLE=1")
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
	before := getRef(live, headKey(live, name, pass))
	if code, out := run(true); code != exitSealStopped {
		t.Errorf("a stoppable push with the request present exited %d, want exitSealStopped (%d)\n%s", code, exitSealStopped, out)
	}
	if after := getRef(live, headKey(live, name, pass)); after != before {
		t.Errorf("a stopped push moved the head: %q -> %q", before, after)
	}
	if code, out := run(false); code != 0 {
		t.Errorf("a push without NOWHERE_SEAL_STOPPABLE exited %d, want 0\n%s", code, out)
	}
	if after := getRef(live, headKey(live, name, pass)); after == before {
		t.Error("a push without NOWHERE_SEAL_STOPPABLE did not publish a new head")
	}
}
