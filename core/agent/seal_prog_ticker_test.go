package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// TestSealProgTickerEndsOnARefusal: a seal that refuses after pushProfile started its progress ticker must stop
// that ticker before it returns. The mounts-unread refusal returned with the ticker still running, and the ticker
// kept writing "save 0 <total> <scope>" every 400 ms into whatever $NOWHERE_PROGRESS named next: in CI it overwrote
// TestStorageCountWalkWritesProgress's "counting <n>" line (NWP-20261119-03).
func TestSealProgTickerEndsOnARefusal(t *testing.T) {
	name, pass := "progticker-a", "prog ticker lamp gravel"
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_PROGRESS", "")
	resetSealCaches()
	rs := newRecordingStore(t)
	createVault(rs.URL, name, pass)
	h := newHandset(t, rs.URL, name, pass)

	prev := mediaUndersFn
	t.Cleanup(func() { mediaUndersFn = prev })
	mediaUndersFn = func(string) (map[string]string, error) { return nil, nil }
	h.put("keep.txt", "first")
	if msg := h.seal(""); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}

	mediaUndersFn = func(string) (map[string]string, error) {
		return nil, &fs.PathError{Op: "open", Path: "/proc/self/mounts", Err: syscall.EMFILE}
	}
	h.put("more.txt", "second")
	sealRefused, sealRefusedWhy = false, ""
	captureStdout(t, func() { h.seal("") })
	if !sealRefused || sealRefusedWhy != "mounts-unread" {
		t.Fatalf("sealRefused=%v why=%q, want a mounts-unread refusal", sealRefused, sealRefusedWhy)
	}

	p := filepath.Join(t.TempDir(), "p")
	t.Setenv("NOWHERE_PROGRESS", p)
	time.Sleep(1200 * time.Millisecond) // three ticker periods
	if b, err := os.ReadFile(p); err == nil {
		t.Fatalf("a progress frame %q was written after the refused seal returned: its ticker still runs", b)
	}
}
