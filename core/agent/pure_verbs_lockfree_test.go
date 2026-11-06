package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261019-11: CHECK-PASSPHRASE, GEN-PASSPHRASE, GET-SYNC-INTERVAL and SET-SYNC-INTERVAL never wait for sessionMu,
// and SET-SYNC-INTERVAL answers ERR when the cadence was not saved.

// useTempSyncInterval points syncIntervalPath at a file inside a temp dir and returns the path.
func useTempSyncInterval(t *testing.T) string {
	t.Helper()
	t.Setenv("NOWHERE_SYNC_INTERVAL", "")
	old := syncIntervalPath
	p := filepath.Join(t.TempDir(), "sync-interval")
	syncIntervalPath = p
	t.Cleanup(func() { syncIntervalPath = old })
	return p
}

func heldReply(t *testing.T, req, what string) string {
	t.Helper()
	sessionMu.Lock()
	defer sessionMu.Unlock()
	return replyWhileHeld(t, 5*time.Second, req, what)
}

func TestPureVerbsAnswerWhileSessionMuIsHeld(t *testing.T) {
	useTempSyncInterval(t)
	if got := heldReply(t, "CHECK-PASSPHRASE\nalice\nhunter2\n", "CHECK-PASSPHRASE"); got != "OK" && !strings.HasPrefix(got, "WEAK ") {
		t.Fatalf("CHECK-PASSPHRASE replied %q, want OK or WEAK <reason>", got)
	}
	if got := heldReply(t, "GEN-PASSPHRASE\n", "GEN-PASSPHRASE"); !strings.HasPrefix(got, "OK ") || len(got) <= len("OK ") {
		t.Fatalf("GEN-PASSPHRASE replied %q, want OK <words>", got)
	}
	if got := heldReply(t, "GET-SYNC-INTERVAL\n", "GET-SYNC-INTERVAL"); got != "120" {
		t.Fatalf("GET-SYNC-INTERVAL replied %q, want the 120 default", got)
	}
}

func TestSetSyncIntervalWhileSessionMuIsHeld(t *testing.T) {
	gatePeer(t, 10123)
	p := useTempSyncInterval(t)
	if got := heldReply(t, "SET-SYNC-INTERVAL\n300\n", "SET-SYNC-INTERVAL"); got != "OK" {
		t.Fatalf("SET-SYNC-INTERVAL replied %q, want OK", got)
	}
	if got := heldReply(t, "GET-SYNC-INTERVAL\n", "GET-SYNC-INTERVAL"); got != "300" {
		t.Fatalf("GET-SYNC-INTERVAL after SET 300 replied %q", got)
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("a successful SET left %s.tmp behind (stat err %v)", p, err)
	}
}

// A write that fails keeps the previous value and says ERR.
func TestSetSyncIntervalFailedWriteKeepsPreviousValue(t *testing.T) {
	gatePeer(t, 10123)
	p := useTempSyncInterval(t)
	if got := driveLogin(t, t.TempDir(), "SET-SYNC-INTERVAL\n300\n"); got != "OK" {
		t.Fatalf("SET 300 replied %q", got)
	}
	if err := os.MkdirAll(p+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p+".tmp", "x"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), "SET-SYNC-INTERVAL\n60\n"); got != "ERR" {
		t.Fatalf("SET 60 with an unwritable temp path replied %q, want ERR", got)
	}
	if got := driveLogin(t, t.TempDir(), "GET-SYNC-INTERVAL\n"); got != "300" {
		t.Fatalf("GET after a failed SET replied %q, want the previous 300", got)
	}
}

// A rename that fails answers ERR and leaves no temp file.
func TestSetSyncIntervalFailedRenameLeavesNoTemp(t *testing.T) {
	gatePeer(t, 10123)
	p := useTempSyncInterval(t)
	if err := os.MkdirAll(p, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), "SET-SYNC-INTERVAL\n60\n"); got != "ERR" {
		t.Fatalf("SET 60 with a directory at the path replied %q, want ERR", got)
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("a failed SET left %s.tmp behind (stat err %v)", p, err)
	}
	if got := driveLogin(t, t.TempDir(), "GET-SYNC-INTERVAL\n"); got != "120" {
		t.Fatalf("GET with a directory at the path replied %q, want the 120 default", got)
	}
}
