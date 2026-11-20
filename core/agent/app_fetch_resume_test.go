package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func resumeFixture(t *testing.T, base, name string) odFetchFixture {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	t.Setenv("NOWHERE_PROGRESS", "")
	f := odFetchFixture{base: base, name: name, pass: "resume horse battery staple",
		files: map[string][]byte{"base.apk": odSeedBytes(10<<20, 71), "split_config.apk": odSeedBytes(2<<20, 72)}}
	createVault(base, f.name, f.pass)
	src := t.TempDir()
	for _, d := range []string{"com.big/_meta", "com.other/_meta"} {
		if err := os.MkdirAll(filepath.Join(src, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(p string, b []byte) {
		if err := os.WriteFile(filepath.Join(src, p), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for rel, b := range f.files {
		write("com.big/"+rel, b)
	}
	write("com.other/base.apk", odSeedBytes(3<<20, 73))
	write("com.big/_meta/meta", []byte("vc\t1\n"))
	write("com.other/_meta/meta", []byte("vc\t1\n"))
	write("manifest.tsv", []byte("com.big\t1\t1\tondemand\tbase.apk\tsplit_config.apk\ncom.other\t1\t1\tondemand\tbase.apk\n"))
	deferPath := filepath.Join(t.TempDir(), "defer")
	if err := os.WriteFile(deferPath, []byte("com.big/base.apk\ncom.big/split_config.apk\ncom.other/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)
	pushProfile(base, f.name+"#apps", f.pass, src)
	key, mb, ok := resolveKey(base, f.name+"#apps", f.pass)
	if !ok {
		t.Fatal("fixture has no app-code head")
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"com.big/base.apk", "com.big/split_config.apk"} {
		f.chunks = append(f.chunks, m.Deferred[rel].Chunks...)
	}
	f.other = m.Deferred["com.other/base.apk"].Chunks
	return f
}

func TestAppFetchResumeKeepsLandedChunks(t *testing.T) {
	store := newHTTPStore(t)
	f := resumeFixture(t, store, "resume-keeps")
	dest := t.TempDir()
	dir := appFetchResumeDir(dest)
	relDir, relErr := filepath.Rel(dest, dir)
	if relErr != nil || relDir == ".." || strings.HasPrefix(relDir, ".."+string(filepath.Separator)) {
		t.Fatalf("resume directory %q is outside app-code staging %q", dir, dest)
	}
	// One window holds every chunk, so try 1 dispatches all of them before the victim's failure stops it.
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "1024")
	oldDir, oldFetch := chunkCacheDir, healFetchChunk
	chunkCacheDir = dir
	var pending sync.WaitGroup
	var finished int64
	healFetchChunk = func(base string, key []byte, v int, h string) ([]byte, error) {
		pending.Add(1)
		defer pending.Done()
		defer atomic.AddInt64(&finished, 1)
		return oldFetch(base, key, v, h)
	}
	t.Cleanup(func() { pending.Wait(); healFetchChunk = oldFetch; chunkCacheDir = oldDir })
	victim := f.chunks[len(f.chunks)/2]
	badBase, _ := corruptingStore(t, store, victim, -1)
	if _, err := restoreAppCode(badBase, f.name+"#apps", f.pass, "com.big", dest); err == nil {
		t.Fatal("corrupt chunk unexpectedly succeeded")
	}
	// A failed fetch returns while started fetches still run and still cacheWrite: wait for every one.
	for deadline := time.Now().Add(30 * time.Second); atomic.LoadInt64(&finished) < int64(len(f.chunks)); {
		if time.Now().After(deadline) {
			t.Fatalf("try 1 finished %d of %d chunk fetches", atomic.LoadInt64(&finished), len(f.chunks))
		}
		time.Sleep(10 * time.Millisecond)
	}
	pending.Wait()
	got := cacheNames(t, dir)
	if len(got) == 0 || got[victim] {
		t.Fatalf("failed try retained %d chunks; victim present=%v", len(got), got[victim])
	}
	for _, h := range f.chunks {
		if h != victim && !got[h] {
			t.Errorf("landed chunk %s missing", h)
		}
	}
	counts := map[string]int32{}
	var countsMu sync.Mutex
	counting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			countsMu.Lock()
			counts[strings.TrimPrefix(r.URL.Path, "/blob/")]++
			countsMu.Unlock()
		}
		req, _ := http.NewRequest(r.Method, store+r.URL.Path, r.Body)
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			w.WriteHeader(502)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	defer counting.Close()
	atomic.StoreInt64(&chunkHits, 0)
	atomic.StoreInt64(&chunkMiss, 0)
	n, err := restoreAppCode(counting.URL, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
	for _, h := range f.chunks {
		want := int32(0)
		if h == victim {
			want = 1
		}
		countsMu.Lock()
		got := counts[h]
		countsMu.Unlock()
		if got != want {
			t.Errorf("blob %s GETs=%d, want %d", h, got, want)
		}
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("resume directory remains after success: %v", err)
	}
}

func TestAppFetchResumeClearsOnSuccess(t *testing.T) {
	store := newHTTPStore(t)
	f := resumeFixture(t, store, "resume-clears")
	dest := t.TempDir()
	old := chunkCacheDir
	chunkCacheDir = appFetchResumeDir(dest)
	t.Cleanup(func() { chunkCacheDir = old })
	n, err := restoreAppCode(store, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
	if _, err := os.Stat(appFetchResumeDir(dest)); !os.IsNotExist(err) {
		t.Fatalf("resume directory remains: %v", err)
	}
}

func TestAppFetchResumePrunes(t *testing.T) {
	store := newHTTPStore(t)
	f := resumeFixture(t, store, "resume-prunes")
	dest := t.TempDir()
	dir := appFetchResumeDir(dest)
	old := chunkCacheDir
	chunkCacheDir = dir
	t.Cleanup(func() { chunkCacheDir = old })
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	stale := strings.Repeat("f", 64)
	if err := os.WriteFile(filepath.Join(dir, stale), []byte("stale"), 0600); err != nil {
		t.Fatal(err)
	}
	other := f.other[0]
	if err := os.WriteFile(filepath.Join(dir, other), []byte("bad"), 0600); err != nil {
		t.Fatal(err)
	}
	_, _ = restoreAppCode(store, f.name+"#apps", f.pass, "com.big", dest)
	if _, err := os.Stat(filepath.Join(dir, stale)); !os.IsNotExist(err) {
		t.Errorf("stale entry survived pruning: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, other)); err != nil {
		t.Errorf("another deferred package's chunk was pruned: %v", err)
	}
}

func TestAppFetchResumeOffByDefault(t *testing.T) {
	old := chunkCacheDir
	chunkCacheDir = ""
	defer func() { chunkCacheDir = old }()
	store := newHTTPStore(t)
	f := resumeFixture(t, store, "resume-off")
	dest := t.TempDir()
	n, e := restoreAppCode(store, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, e)
	if _, e = os.Stat(appFetchResumeDir(dest)); !os.IsNotExist(e) {
		t.Fatalf("direct restore made resume directory: %v", e)
	}
}

func TestAppFetchResumeVerbSetsTheDir(t *testing.T) {
	src := agentSources(t)["main.go"]
	body := strings.Join(funcBody(t, src, "main"), "\n")
	start := strings.Index(body, "case \"restore-app\"")
	if start < 0 {
		t.Fatal("restore-app case missing")
	}
	body = body[start:]
	set := strings.Index(body, "if chunkCacheDir == \"\" {\n\t\t\tchunkCacheDir = appFetchResumeDir(dest)\n\t\t}")
	call := strings.Index(body, "restoreAppCode(base, scope, pass, pkg, dest)")
	if set < 0 || call < 0 || set > call {
		t.Fatal("restore-app must set the default resume dir before restoreAppCode")
	}
	if strings.Contains(body, "chunkCacheDir = appFetchResumeDir(dest)") && !strings.Contains(body, "if chunkCacheDir == \"\"") {
		t.Fatal("restore-app overrides explicit cache")
	}
}

func TestAppFetchResumeNeverSealed(t *testing.T) {
	dest := filepath.Join("/data", appCodeStageRel)
	resumeDir := appFetchResumeDir(dest)
	rel, err := filepath.Rel(dest, resumeDir)
	if err != nil || filepath.Base(resumeDir) != appFetchResumeDirName || !isAppCodeStagePath(filepath.ToSlash(filepath.Clean(appCodeStageRel+"/"+rel+"/"+strings.Repeat("a", 64)))) {
		t.Fatal("resume chunks are not excluded from sealing")
	}
}

func TestAppFetchResumeLogLine(t *testing.T) {
	store := newHTTPStore(t)
	f := resumeFixture(t, store, "resume-log")
	dest := t.TempDir()
	dir := appFetchResumeDir(dest)
	old := chunkCacheDir
	chunkCacheDir = dir
	t.Cleanup(func() { chunkCacheDir = old })
	for _, h := range f.chunks {
		r, e := http.Get(store + "/blob/" + h)
		if e != nil {
			t.Fatal(e)
		}
		b, e := io.ReadAll(r.Body)
		r.Body.Close()
		if e != nil {
			t.Fatal(e)
		}
		cacheWrite(dir, h, b)
	}
	r, w, e := os.Pipe()
	if e != nil {
		t.Fatal(e)
	}
	oldOut := os.Stdout
	os.Stdout = w
	n, err := restoreAppCode(store, f.name+"#apps", f.pass, "com.big", dest)
	w.Close()
	os.Stdout = oldOut
	logged, e := io.ReadAll(r)
	r.Close()
	if e != nil {
		t.Fatal(e)
	}
	f.check(t, dest, n, err)
	line := string(logged)
	if !regexp.MustCompile(`^restore-app: [0-9]+ of [0-9]+ chunk\(s\) were already here from an earlier try \(NWP-20261210-10\)\n$`).MatchString(line) {
		t.Fatalf("resume log is not fixed, numeric, and private: %q", line)
	}
}
