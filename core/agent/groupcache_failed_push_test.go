package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261123-05: the row "A vault push that failed on the network leaves the small-file group cache unusable".
// These tests run whole cap-mode vault pushes against mockCapStore, behind a front that can reset the connection of
// a blob PUT (a transport error, not an HTTP status). F proves a push whose flush fails on a reset blob PUT
// leaves every unchanged group reusable at the next seal; G proves the every-Nth-seal full re-hash, which also reads
// "0 of <m> group(s) reused", is named in the group-cache line; H proves a chunk whose PUT failed is never known.
// The names avoid "GroupCache": test-seal-group-cache.sh runs -run 'TestGroupCache' and would pull these in.

const fpgPass = "group cache test phrase"

// fpgReset is the front fpgEnv puts before mockCapStore: while on is set, it resets the connection of every blob
// PUT, as a network loss does, and records the key; the store never sees that PUT. Everything else is proxied.
var fpgReset struct {
	mu      sync.Mutex
	on      bool
	refused []string
}

// fpgEnv is a cap-mode mock store holding a created vault for name, with every list that changes a walk off. The
// gateway is a front that proxies to mockCapStore; the caps it mints name the front's host, so every object PUT
// passes the front too.
func fpgEnv(t *testing.T, name string) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	target, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		fpgReset.mu.Lock()
		reset := fpgReset.on && r.Method == http.MethodPut && r.URL.Path == "/obj" && strings.HasPrefix(k, "blob/")
		if reset {
			fpgReset.refused = append(fpgReset.refused, k)
		}
		fpgReset.mu.Unlock()
		if reset {
			if c, _, err := w.(http.Hijacker).Hijack(); err == nil {
				c.Close() // no status line: the client's PUT ends in a transport error
			}
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	fpgReset.mu.Lock()
	fpgReset.on, fpgReset.refused = false, nil
	fpgReset.mu.Unlock()
	t.Cleanup(func() { fpgReset.mu.Lock(); fpgReset.on = false; fpgReset.mu.Unlock() })
	t.Setenv("GATEWAY_URL", front.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	t.Setenv("NOWHERE_SPILL", t.TempDir())
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "0")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	t.Setenv("NOWHERE_DROP_LIST", "")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(front.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	if createVault("s3", name, fpgPass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
}

// fpgPush runs one vault push and returns its group-cache line and whether the push failed.
func fpgPush(t *testing.T, name, src string) (line string, panicked bool) {
	t.Helper()
	line, why := fpgPushWhy(t, name, src)
	return line, why != ""
}

// fpgPushWhy runs one vault push and returns its group-cache line and, when the push failed, why ("" when it landed).
func fpgPushWhy(t *testing.T, name, src string) (line, why string) {
	t.Helper()
	out := captureStdout(t, func() {
		defer func() {
			if r := recover(); r != nil {
				why = fmt.Sprint(r)
				if why == "" {
					why = "panic with an empty value"
				}
			}
		}()
		pushProfile("s3", name, fpgPass, src)
	})
	pushFenceSeq, pushFenceSampled = 0, false // see sealDEInSession
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, " group cache: ") {
			lines = append(lines, l)
		}
	}
	if len(lines) != 1 {
		t.Fatalf("want exactly one group-cache line, got %d in:\n%s", len(lines), out)
	}
	return lines[0], why
}

var fpgCountRE = regexp.MustCompile(`group cache: (\d+) of (\d+) group\(s\) reused`)

// fpgCounts parses the reused and total group counts of a group-cache line.
func fpgCounts(t *testing.T, line string) (hits, total int) {
	t.Helper()
	m := fpgCountRE.FindStringSubmatch(line)
	if m == nil {
		t.Fatalf("no group counts in %q", line)
	}
	hits, _ = strconv.Atoi(m[1])
	total, _ = strconv.Atoi(m[2])
	return hits, total
}

// fpgChangeOne rewrites one file in d2 with bytes of a new length and a new mtime; the dir mtimes stay as gcTree set
// them, so only d2's group key changes.
func fpgChangeOne(t *testing.T, src string) {
	t.Helper()
	p := filepath.Join(src, "d2", "f", "003.txt")
	if err := os.WriteFile(p, []byte(strings.Repeat("changed after the first push; ", 13)), 0o600); err != nil {
		t.Fatal(err)
	}
	mt := gcBase.Add(77 * time.Hour)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"d2/f", "d2"} {
		if err := os.Chtimes(filepath.Join(src, rel), gcBase, gcBase); err != nil {
			t.Fatal(err)
		}
	}
}

// fpgFailBlobs makes the front reset the connection of every blob PUT, as a network loss does, and returns a func
// that stops the resets and returns the reset keys.
func fpgFailBlobs() func() []string {
	fpgReset.mu.Lock()
	fpgReset.on, fpgReset.refused = true, nil
	fpgReset.mu.Unlock()
	return func() []string {
		fpgReset.mu.Lock()
		defer fpgReset.mu.Unlock()
		fpgReset.on = false
		return append([]string(nil), fpgReset.refused...)
	}
}

// fpgNewProcess drops the in-memory caches, so the next push reloads them from the files, as the next agent run does.
func fpgNewProcess() {
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	capReadCache = map[string]capEntry{}
}

// fpgFailedSecondPush runs push 1 over a gcTree, changes one file in d2 and runs push 2 with every blob PUT failing.
// It returns the tree, push 1's group total and the refused keys.
func fpgFailedSecondPush(t *testing.T, name string) (src string, total1 int, refused []string) {
	t.Helper()
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "0") // forceFull pinned off
	fpgEnv(t, name)
	src = gcTree(t, 6, 8)
	line1, p1 := fpgPush(t, name, src)
	if p1 {
		t.Fatalf("push 1 failed: %s", line1)
	}
	_, total1 = fpgCounts(t, line1)
	if total1 < 6 {
		t.Fatalf("push 1 counted %d group(s), want at least one per top-level dir: %s", total1, line1)
	}
	fpgChangeOne(t, src)
	stopResets := fpgFailBlobs()
	line2, why2 := fpgPushWhy(t, name, src)
	refused = stopResets()
	if why2 == "" || len(refused) == 0 {
		t.Fatalf("precondition: push 2's flush must fail on a reset blob PUT (failure=%q, reset=%d): %s", why2, len(refused), line2)
	}
	// The failure must be the transport error of a reset connection, not an HTTP status from the store.
	if !strings.HasPrefix(why2, "Put ") || !strings.Contains(why2, "/obj?k=blob%2F") ||
		!(strings.HasSuffix(why2, ": EOF") || strings.Contains(why2, "connection reset")) {
		t.Fatalf("precondition: push 2 must fail on a transport error of a blob PUT, got: %s", why2)
	}
	if hits2, total2 := fpgCounts(t, line2); total2 != total1 || hits2 != total1-1 {
		t.Fatalf("push 2 reused %d of %d group(s), want %d of %d (only d2 re-read): %s", hits2, total2, total1-1, total1, line2)
	}
	return src, total1, refused
}

// F: a push whose flush failed on a reset blob PUT leaves every unchanged group reusable at the next seal.
func TestFailedPush_GroupsStayReusable(t *testing.T) {
	name := "fpgreuse"
	src, total1, _ := fpgFailedSecondPush(t, name)
	fpgNewProcess()
	line3, p3 := fpgPush(t, name, src)
	if p3 {
		t.Fatalf("push 3 failed: %s", line3)
	}
	hits3, total3 := fpgCounts(t, line3)
	if total3 != total1 {
		t.Fatalf("push 3 counted %d group(s), push 1 %d: %s", total3, total1, line3)
	}
	if hits3 != total3-1 {
		t.Fatalf("a failed push left %d unchanged group(s) unusable: push 3 reused %d of %d, want %d (only d2, whose new "+
			"chunks the store never confirmed, re-read): %s", total3-1-hits3, hits3, total3, total3-1, line3)
	}
	if strings.Contains(line3, "full re-hash") {
		t.Fatalf("forceFull is pinned off, but the line names a full re-hash: %s", line3)
	}
}

// G: the every-Nth-seal full re-hash is named in the group-cache line, and only on that seal.
func TestFailedPush_ForcedRehashIsNamed(t *testing.T) {
	name := "fpgforced"
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "2")
	fpgEnv(t, name)
	src := gcTree(t, 6, 8)
	line1, p1 := fpgPush(t, name, src)
	if p1 {
		t.Fatalf("push 1 failed: %s", line1)
	}
	if strings.Contains(line1, "full re-hash") {
		t.Fatalf("push 1 is not a forced re-hash, but its line names one: %s", line1)
	}
	line2, p2 := fpgPush(t, name, src)
	if p2 {
		t.Fatalf("push 2 failed: %s", line2)
	}
	if want := " (full re-hash: every 2th seal)"; !strings.Contains(line2, want) {
		t.Fatalf("push 2 is the forced re-hash, but its line does not carry %q: %s", want, line2)
	}
	if hits, total := fpgCounts(t, line2); hits != 0 || total == 0 {
		t.Fatalf("push 2 is a forced re-hash: want 0 of >0 group(s) reused, got %d of %d: %s", hits, total, line2)
	}
}

// H: a chunk whose PUT was reset is never known present, in memory or after a reload from the blob-cache file.
func TestFailedPush_UnputChunkNotKnown(t *testing.T) {
	_, _, refused := fpgFailedSecondPush(t, "fpgunput")
	for _, pass := range []string{"in memory", "after a reload"} {
		if pass == "after a reload" {
			fpgNewProcess()
		}
		for _, k := range refused {
			if blobCacheKnown(strings.TrimPrefix(k, "blob/")) {
				t.Fatalf("%s: the PUT of %s was reset, so the store never held it, but it is known present", pass, k)
			}
		}
	}
	t.Logf("%d reset blob(s) checked", len(refused))
}
