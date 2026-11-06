package main

// NWP-20261118-06 (h48 #6): the session's kept storage count. Every test replaces storageCountRun, so the default
// hook never runs and no count reaches the RO lane. Ordering comes only from channels the hook controls.

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// scHook is one test's replacement count: every call is counted, announces itself on entered, waits on gate, then
// returns result(n) for the n-th call (1-based).
type scHook struct {
	calls   atomic.Int32
	entered chan struct{}
	gate    chan struct{}
	once    sync.Once
}

func (h *scHook) release() { h.once.Do(func() { close(h.gate) }) }

// scFixture signs in a test-only profile in a fresh dest and installs the hook. The cleanup restores both hooks,
// releases the gate (so no count goroutine is left blocked) and resets the count state.
func scFixture(t *testing.T, profile string, result func(n int32) string) (string, *scHook) {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, profile, "sc-pass", "41", ""); err != nil {
		t.Fatal(err)
	}
	h := &scHook{entered: make(chan struct{}, 8), gate: make(chan struct{})}
	prevRun, prevJoined := storageCountRun, storageCountJoinedHook
	resetStorageCount()
	storageCountRun = func(string) string {
		n := h.calls.Add(1)
		h.entered <- struct{}{}
		<-h.gate
		return result(n)
	}
	t.Cleanup(func() {
		h.release()
		storageCountRun, storageCountJoinedHook = prevRun, prevJoined
		resetStorageCount()
	})
	return dest, h
}

// scSend runs one handler over a pipe and returns its whole reply.
func scSend(t *testing.T, dest string, fn func(net.Conn, string)) string {
	t.Helper()
	a, b := net.Pipe()
	go func() {
		defer b.Close()
		fn(b, dest)
	}()
	out, err := io.ReadAll(a)
	if err != nil {
		t.Error(err) // t.Error, not t.Fatal: a test may call this from its own goroutine
	}
	return string(out)
}

// scCurrent is the running job, nil when none.
func scCurrent() *storageCountJob {
	storageCount.mu.Lock()
	defer storageCount.mu.Unlock()
	return storageCount.cur
}

// scCached parses an OK reply of GET-STORAGE-BREAKDOWN-CACHED into its header fields and its body.
func scCached(t *testing.T, reply string) (nbytes int, at int64, running, lastErr, body string) {
	t.Helper()
	head, body, ok := strings.Cut(reply, "\n")
	f := strings.Fields(head)
	if !ok || len(f) != 5 || f[0] != "OK" {
		t.Fatalf("CACHED reply = %q, want OK <nbytes> <countedAt> <running> <lastErr>\\n<json>", reply)
	}
	nbytes, _ = strconv.Atoi(f[1])
	at, _ = strconv.ParseInt(f[2], 10, 64)
	return nbytes, at, f[3], f[4], body
}

func TestStorageCountStartRunsOneCountAndCachedServesIt(t *testing.T) {
	const js = `{"apps":[{"pkg":"com.sc.one","bytes":7}],"total_bytes":7}`
	dest, h := scFixture(t, "sctest-one", func(int32) string { return js })

	if got := scSend(t, dest, handleGetStorageBreakdownCached); got != "PENDING 0 none\n" {
		t.Fatalf("CACHED before any count = %q, want PENDING 0 none", got)
	}
	if got := scSend(t, dest, handleStorageCountStart); got != "OK STARTED\n" {
		t.Fatalf("first START = %q, want OK STARTED", got)
	}
	<-h.entered
	j := scCurrent()
	if j == nil {
		t.Fatal("START left no running count")
	}
	if got := scSend(t, dest, handleStorageCountStart); got != "OK RUNNING\n" {
		t.Fatalf("second START while a count runs = %q, want OK RUNNING", got)
	}
	if got := scSend(t, dest, handleGetStorageBreakdownCached); got != "PENDING 1 none\n" {
		t.Fatalf("CACHED while the first count runs = %q, want PENDING 1 none", got)
	}
	h.release()
	<-j.done
	if n := h.calls.Load(); n != 1 {
		t.Fatalf("the count ran %d times, want exactly 1: a START while one runs must join it", n)
	}
	nbytes, at, running, lastErr, body := scCached(t, scSend(t, dest, handleGetStorageBreakdownCached))
	if body != js || nbytes != len(js) {
		t.Fatalf("CACHED body = %q (%d bytes), want the count's JSON byte for byte %q", body, nbytes, js)
	}
	if running != "0" || lastErr != "none" {
		t.Fatalf("CACHED running=%s lastErr=%s, want 0 none", running, lastErr)
	}
	storageCount.mu.Lock()
	countedAt := storageCount.countedAt
	storageCount.mu.Unlock()
	if countedAt.IsZero() || at <= 0 || at != countedAt.Unix() {
		t.Fatalf("countedAt = %v, header says %d: want a set time the header carries", countedAt, at)
	}
}

func TestStorageCountFailedRefreshKeepsTheOldFigure(t *testing.T) {
	const js = `{"apps":[],"total_bytes":42}`
	dest, h := scFixture(t, "sctest-two", func(n int32) string {
		if n == 1 {
			return js
		}
		return "ERR-WORKER-BUSY"
	})
	h.release()
	j, _ := startStorageCount(dest)
	<-j.done
	j, started := startStorageCount(dest)
	if !started {
		t.Fatal("a second count did not start after the first landed")
	}
	<-j.done
	if j.out != "ERR-WORKER-BUSY" {
		t.Fatalf("the refresh's result = %q, want ERR-WORKER-BUSY", j.out)
	}
	nbytes, _, running, lastErr, body := scCached(t, scSend(t, dest, handleGetStorageBreakdownCached))
	if body != js || nbytes != len(js) {
		t.Fatalf("after a failed refresh CACHED body = %q, want the old figure %q kept", body, js)
	}
	if running != "0" || lastErr != "ERR-WORKER-BUSY" {
		t.Fatalf("after a failed refresh running=%s lastErr=%s, want 0 ERR-WORKER-BUSY", running, lastErr)
	}
}

func TestStorageCountResetDropsTheCache(t *testing.T) {
	for _, tc := range []struct {
		what  string
		reset func()
	}{
		{"resetSealSignals (every sign-in)", resetSealSignals},
		{"forgetSessionKeys (every session end)", func() { forgetSessionKeys("test") }},
	} {
		t.Run(tc.what, func(t *testing.T) {
			dest, h := scFixture(t, "sctest-three", func(int32) string { return `{"total_bytes":3}` })
			h.release()
			j, _ := startStorageCount(dest)
			<-j.done
			if got := scSend(t, dest, handleGetStorageBreakdownCached); !strings.HasPrefix(got, "OK ") {
				t.Fatalf("CACHED after a count = %q, want OK", got)
			}
			tc.reset()
			if got := scSend(t, dest, handleGetStorageBreakdownCached); got != "PENDING 0 none\n" {
				t.Fatalf("CACHED after %s = %q, want PENDING 0 none: the count is RAM only, per session", tc.what, got)
			}
		})
	}
}

func TestStorageCountResetBeforePublishPublishesNothing(t *testing.T) {
	dest, h := scFixture(t, "sctest-four", func(int32) string { return `{"total_bytes":4}` })
	j, started := startStorageCount(dest)
	if !started {
		t.Fatal("no count started")
	}
	<-h.entered
	resetStorageCount()
	h.release()
	<-j.done
	if got := scSend(t, dest, handleGetStorageBreakdownCached); got != "PENDING 0 none\n" {
		t.Fatalf("CACHED after a count released past a reset = %q, want PENDING 0 none", got)
	}
}

func TestStorageCountBreakdownJoinsTheRunningCount(t *testing.T) {
	const js = `{"apps":[{"pkg":"com.sc.five","bytes":5}],"total_bytes":5}`
	dest, h := scFixture(t, "sctest-five", func(int32) string { return js })
	if got := scSend(t, dest, handleStorageCountStart); got != "OK STARTED\n" {
		t.Fatalf("START = %q, want OK STARTED", got)
	}
	<-h.entered
	joined := make(chan struct{}, 1)
	storageCountJoinedHook = func() { joined <- struct{}{} }
	reply := make(chan string, 1)
	go func() { reply <- scSend(t, dest, handleGetStorageBreakdown) }()
	select {
	case <-joined:
	case <-h.entered:
		t.Fatal("GET-STORAGE-BREAKDOWN made its own count while one ran")
	}
	h.release()
	if got, want := <-reply, fmt.Sprintf("OK %d\n%s", len(js), js); got != want {
		t.Fatalf("GET-STORAGE-BREAKDOWN = %q, want the running count's reply %q", got, want)
	}
	if n := h.calls.Load(); n != 1 {
		t.Fatalf("the count ran %d times, want 1", n)
	}
}

func TestStorageCountBreakdownReplyIsUnchanged(t *testing.T) {
	dest, h := scFixture(t, "sctest-six", func(int32) string { return "ERR-TIMEOUT" })
	h.release()
	if got := scSend(t, dest, handleGetStorageBreakdown); got != "ERR-TIMEOUT\n" {
		t.Fatalf("GET-STORAGE-BREAKDOWN on a failed count = %q, want ERR-TIMEOUT", got)
	}
	nobody := t.TempDir()
	for _, fn := range []func(net.Conn, string){handleGetStorageBreakdown, handleStorageCountStart, handleGetStorageBreakdownCached} {
		if got := scSend(t, nobody, fn); got != "NONE\n" {
			t.Fatalf("a verb with nobody signed in = %q, want NONE", got)
		}
	}
	if n := h.calls.Load(); n != 1 {
		t.Fatalf("the count ran %d times, want 1: nobody signed in starts no count", n)
	}
}

func TestStorageCountWalkWritesProgress(t *testing.T) {
	root := t.TempDir()
	files := filepath.Join(root, "data", "user", "7", "com.sc.example", "files")
	if err := os.MkdirAll(files, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4500; i++ {
		if err := os.WriteFile(filepath.Join(files, fmt.Sprintf("f%04d", i)), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("set", func(t *testing.T) {
		pdir := t.TempDir()
		p := filepath.Join(pdir, "p")
		t.Setenv("NOWHERE_PROGRESS", p)
		collectStorageBreakdownAt(root, "7", nil)
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("the walk wrote no progress line: %v", err)
		}
		line := strings.TrimSpace(string(b))
		var n int
		if _, err := fmt.Sscanf(line, "counting %d", &n); err != nil || n < 4000 {
			t.Fatalf("last progress line = %q, want counting <n> with n >= 4000 after 4500 files", line)
		}
		if strings.ContainsAny(line, "/.") {
			t.Fatalf("progress line %q holds a path", line)
		}
		ents, _ := os.ReadDir(pdir)
		if len(ents) != 1 {
			t.Fatalf("progress dir holds %d entries, want only p (no temp left)", len(ents))
		}
	})
	t.Run("unset", func(t *testing.T) {
		t.Setenv("NOWHERE_PROGRESS", "")
		wd := t.TempDir()
		t.Chdir(wd)
		collectStorageBreakdownAt(root, "7", nil)
		if ents, _ := os.ReadDir(wd); len(ents) != 0 {
			t.Fatalf("with NOWHERE_PROGRESS unset the walk wrote %d entries", len(ents))
		}
	})
}
