package main

// NWP-20261210-02 (backlog §B, "A large app's fetch fails on a slow link: one chunk with no data for 30 s ends the
// whole fetch, and each retry starts again from chunk 1"). A chunk GET cut by storeXferStall while the link carried
// bytes is retried past the retry window, at most storeStallRetries times (retryStoreWithinGuarded), and a body byte
// counts as the store answering for the give-up clock (noteStoreBytes, called by storeXferBody.Read). A dead store
// moves no byte, so it keeps the 15 s stop of docs/product-decisions.md 2026-10-19, item 5. The tests share
// process-global state (storeGiveUp, storeXferByteAt, s3RetryBase, storeXferStall, os.Stderr), so none runs in
// parallel. test-store-stall-retry.sh --mutate re-runs them against broken overlays of the production files.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// stallRetryLine is the fixed part of the exemption line.
const stallRetryLine = "stalled while the link carried bytes -- retried past the"

// stallRetrySetup resets the byte stamps and the give-up state on the real clock and keeps the backoff short.
func stallRetrySetup(t *testing.T) {
	t.Helper()
	oldNow, oldBase := storeGiveUpNow, s3RetryBase
	storeGiveUpNow, s3RetryBase = time.Now, time.Millisecond
	resetStoreGiveUpForTest()
	t.Cleanup(func() {
		storeGiveUpNow, s3RetryBase = oldNow, oldBase
		resetStoreGiveUpForTest()
	})
}

// stallingOp is an attempt that outlives a 10 ms window: it notes a body byte when withByte, spends 20 ms and fails
// with failWith on every call listed in fail, else succeeds.
func stallingOp(calls *int, withByte bool, failWith error, fail func(call int) bool) func() error {
	return func() error {
		*calls++
		if withByte {
			noteStoreBytes()
		}
		time.Sleep(20 * time.Millisecond)
		if fail(*calls) {
			return failWith
		}
		return nil
	}
}

var errStallForTest = fmt.Errorf("cap GET blob/x: %w", errStoreXferStall)

func TestStallRetryWhileLinkCarriesBytes(t *testing.T) {
	stallRetrySetup(t)
	calls := 0
	var err error
	out := captureStderr(t, func() {
		err = retryStoreWithin("cap GET blob/x", 10*time.Millisecond,
			stallingOp(&calls, true, errStallForTest, func(c int) bool { return c == 1 }))
	})
	if calls != 2 || err != nil {
		t.Errorf("a stall while the link carried bytes made %d call(s) and returned %v, want 2 calls and nil: "+
			"the stalled attempt must be retried past the window\n%s", calls, err, out)
	}
	if n := strings.Count(out, stallRetryLine); n != 1 {
		t.Errorf("the exemption line %q was printed %d time(s), want 1\n%s", stallRetryLine, n, out)
	}
}

func TestStallRetryDeadLinkKeepsTheWindow(t *testing.T) {
	stallRetrySetup(t)
	calls := 0
	var err error
	out := captureStderr(t, func() {
		err = retryStoreWithin("cap GET blob/x", 10*time.Millisecond,
			stallingOp(&calls, false, errStallForTest, func(int) bool { return true }))
	})
	if calls != 1 || !errors.Is(err, errStoreXferStall) {
		t.Errorf("a stall on a dead link made %d call(s) and returned %v, want 1 call and the stall error", calls, err)
	}
	if !strings.Contains(out, "stopped at 1/5: the 10ms retry window is spent") || strings.Contains(out, stallRetryLine) {
		t.Errorf("a dead link did not print today's stop line alone\n%s", out)
	}
}

func TestStallRetryStaleBytesDoNotCount(t *testing.T) {
	stallRetrySetup(t)
	noteStoreBytes() // a byte BEFORE the attempt began
	time.Sleep(5 * time.Millisecond)
	calls := 0
	err := retryStoreWithin("cap GET blob/x", 10*time.Millisecond,
		stallingOp(&calls, false, errStallForTest, func(int) bool { return true }))
	if calls != 1 || !errors.Is(err, errStoreXferStall) {
		t.Errorf("a byte from before the attempt made %d call(s) (%v), want 1: only a byte since the attempt "+
			"began shows the link carries bytes", calls, err)
	}
}

func TestStallRetryOnlyForStall(t *testing.T) {
	stallRetrySetup(t)
	calls := 0
	err := retryStoreWithin("cap GET blob/x", 10*time.Millisecond,
		stallingOp(&calls, true, errors.New("dial tcp: i/o timeout"), func(int) bool { return true }))
	if calls != 1 || err == nil {
		t.Errorf("an i/o timeout with bytes made %d call(s) (%v), want 1: only a stall is exempt from the window",
			calls, err)
	}
}

func TestStallRetryIsBounded(t *testing.T) {
	stallRetrySetup(t)
	calls := 0
	var err error
	out := captureStderr(t, func() {
		err = retryStoreWithin("cap GET blob/x", 10*time.Millisecond,
			stallingOp(&calls, true, errStallForTest, func(int) bool { return true }))
	})
	if want := 1 + storeStallRetries; calls != want || !errors.Is(err, errStoreXferStall) {
		t.Errorf("every attempt stalling with bytes made %d call(s) (%v), want exactly %d (1 + storeStallRetries)\n%s",
			calls, err, want, out)
	}
}

func TestStoreGiveUpBytesAreAnswers(t *testing.T) {
	for _, byteAt19 := range []bool{true, false} {
		clock := setupStoreGiveUp(t)
		disarm := armStoreGiveUp("test")
		t0 := *clock
		if byteAt19 {
			*clock = t0.Add(19 * time.Second)
			noteStoreBytes()
		}
		*clock = t0.Add(20 * time.Second)
		noteStoreAttemptFrom(t0, errStallForTest)
		got := storeGivenUp()
		disarm()
		resetStoreGiveUpForTest()
		if byteAt19 && got {
			t.Errorf("a stall at 20 s with a body byte at 19 s was given up: a byte is the store answering")
		}
		if !byteAt19 && !got {
			t.Errorf("a stall at 20 s with no byte since 0 s was not given up: a dead store must still stop at 15 s")
		}
	}
}

// stallErrReader returns no bytes and an error.
type stallErrReader struct{}

func (stallErrReader) Read([]byte) (int, error) { return 0, errors.New("connection reset by peer") }
func (stallErrReader) Close() error             { return nil }

func TestStoreXferBodyNotesBytes(t *testing.T) {
	stallRetrySetup(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("some body bytes"))
	}))
	t.Cleanup(srv.Close)
	req, err := http.NewRequest(http.MethodGet, srv.URL+"/o", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := storeXfer(req, 1<<10)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil || string(b) != "some body bytes" {
		t.Fatalf("read %q, %v", b, err)
	}
	storeGiveUp.mu.Lock()
	answered := storeGiveUp.answeredAt
	storeGiveUp.mu.Unlock()
	if storeXferByteAt.Load() == 0 || answered.IsZero() {
		t.Errorf("a GET body read moved storeXferByteAt to %d and answeredAt to %v: both must move", storeXferByteAt.Load(), answered)
	}

	resetStoreGiveUpForTest()
	body := &storeXferBody{rc: stallErrReader{}, st: time.NewTimer(time.Hour), ctx: context.Background(), release: func() {}}
	defer body.st.Stop()
	if n, err := body.Read(make([]byte, 8)); n != 0 || err == nil {
		t.Fatalf("the error reader returned %d, %v", n, err)
	}
	storeGiveUp.mu.Lock()
	answered = storeGiveUp.answeredAt
	storeGiveUp.mu.Unlock()
	if storeXferByteAt.Load() != 0 || !answered.IsZero() {
		t.Errorf("a Read that returned 0 bytes and an error moved storeXferByteAt to %d or answeredAt to %v: "+
			"no byte is no answer", storeXferByteAt.Load(), answered)
	}
}

// stallFront stands in front of the whole mockCapStore. Every GET of a chunk in chunks is answered from objs by the
// front itself: the victim's FIRST GET sends its headers and one body byte and then goes silent until the client
// cuts it, and its second GET is answered at once; every other chunk GET trickles its body in 90 pieces 200 ms
// apart, so it takes about 18 s. Everything else is proxied to inner. gets counts the chunk GETs by key.
func stallFront(t *testing.T, inner *httptest.Server, objs map[string][]byte, mu *sync.Mutex, chunks map[string]bool, victim string) (string, func() map[string]int) {
	t.Helper()
	u, err := url.Parse(inner.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	stop := make(chan struct{})
	var gmu sync.Mutex
	gets := map[string]int{}
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		if r.URL.Path != "/obj" || r.Method != http.MethodGet || !chunks[strings.TrimPrefix(k, "blob/")] {
			proxy.ServeHTTP(w, r)
			return
		}
		gmu.Lock()
		gets[k]++
		n := gets[k]
		gmu.Unlock()
		mu.Lock()
		b := objs[k]
		mu.Unlock()
		w.Header().Set("Content-Length", fmt.Sprint(len(b)))
		w.WriteHeader(http.StatusOK)
		f := w.(http.Flusher)
		if k == "blob/"+victim {
			if n > 1 {
				_, _ = w.Write(b) // the retry lands at once
				return
			}
			_, _ = w.Write(b[:1])
			f.Flush()
			select {
			case <-r.Context().Done():
			case <-stop:
			}
			return
		}
		const pieces = 90
		step := (len(b) + pieces - 1) / pieces
		for off := 0; off < len(b); off += step {
			_, _ = w.Write(b[off:min(off+step, len(b))])
			f.Flush()
			select {
			case <-time.After(200 * time.Millisecond):
			case <-r.Context().Done():
				return
			case <-stop:
				return
			}
		}
	}))
	t.Cleanup(front.Close)
	t.Cleanup(func() { close(stop) })
	return front.URL, func() map[string]int {
		gmu.Lock()
		defer gmu.Unlock()
		c := map[string]int{}
		for k, v := range gets {
			c[k] = v
		}
		return c
	}
}

// TestSignInRestoreSurvivesAStallPastTheGiveUpWindow is the row's sign-in test: a cap-mode restore, armed as a
// sign-in is, whose one chunk GET stalls for 16 s (past the 15 s window and past capGetRetryWindow) while the other
// chunk GETs flow but none finishes, lands every file byte-identical, re-fetching only the stalled chunk.
func TestSignInRestoreSurvivesAStallPastTheGiveUpWindow(t *testing.T) {
	giveUpTimingReset(t)
	stallRetrySetup(t)
	oldStall, oldCache := storeXferStall, chunkCacheDir
	storeXferStall, chunkCacheDir = 16*time.Second, ""
	t.Cleanup(func() { storeXferStall, chunkCacheDir = oldStall, oldCache })
	inner, objs, mu := mockCapStore(t)
	const name, pass = "stallretrysignin", "stall retry sign in horse staple"
	giveUpTimingVault(t, inner, name, pass)
	src := t.TempDir()
	// More than three cdcMax (4 MiB) chunks of data: cdcMax forces a boundary at 4 MiB at the latest, so 13 MiB
	// spans at least four chunks whatever the random bytes are (8 MiB could end in three).
	big := make([]byte, 13<<20)
	if _, err := rand.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "a-big.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "b-small.txt"), []byte("after the big one"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, src)
	key, mb, ok := resolveKey("s3", name, pass)
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
	if len(m.Chunks) < 4 {
		t.Fatalf("need at least 4 chunks, got %d", len(m.Chunks))
	}
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", fmt.Sprint(len(m.Chunks)+8))
	chunks := map[string]bool{}
	for _, h := range m.Chunks {
		chunks[h] = true
	}
	victim := m.Chunks[len(m.Chunks)/2]
	front, gets := stallFront(t, inner, objs, mu, chunks, victim)
	t.Setenv("GATEWAY_URL", front)
	capReadCache = map[string]capEntry{}
	resetStoreGiveUpForTest()
	defer armStoreGiveUp("sign-in restore")()

	dest := t.TempDir()
	start := time.Now()
	var r any
	out := captureStderr(t, func() { r = panicOf(func() { cdcRestore("s3", key, m, dest) }) })
	t.Logf("restore of %d chunks with one stalled for %v: %v after %v", len(m.Chunks), storeXferStall, r, time.Since(start))
	if r != nil {
		e, _ := r.(error)
		t.Fatalf("the restore failed (%v; errStoreUnreachable=%v): one chunk stalling while the others flow must "+
			"not end a sign-in\n%s", r, errors.Is(e, errStoreUnreachable), out)
	}
	for _, f := range []string{"a-big.bin", "b-small.txt"} {
		want, _ := os.ReadFile(filepath.Join(src, f))
		got, err := os.ReadFile(filepath.Join(dest, f))
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s restored as %d bytes (%v), want %d byte-identical", f, len(got), err, len(want))
		}
	}
	g := gets()
	for _, h := range m.Chunks {
		want := 1
		if h == victim {
			want = 2
		}
		if g["blob/"+h] != want {
			t.Errorf("chunk %s was GET %d time(s), want %d", h[:12], g["blob/"+h], want)
		}
	}
}
