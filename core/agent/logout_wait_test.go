package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// logoutWaitVars shrinks the three pacing vars for one test (NWP-20261106-04).
func logoutWaitVars(t *testing.T, deadline, first, every time.Duration) {
	t.Helper()
	d, f, e := loginConnDeadline, logoutWaitFirst, logoutWaitEvery
	t.Cleanup(func() { loginConnDeadline, logoutWaitFirst, logoutWaitEvery = d, f, e })
	loginConnDeadline, logoutWaitFirst, logoutWaitEvery = deadline, first, every
}

// logoutWaitReply sends req while the test holds sessionMu for hold, and returns the whole reply. The lock is
// released on every exit path, as replyWhileHeld does.
func logoutWaitReply(t *testing.T, dest, req string, hold time.Duration) string {
	t.Helper()
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	c := driveLoginAsync(t, dest, req)
	time.Sleep(hold)
	sessionMu.Unlock()
	held = false
	select {
	case got := <-c:
		return got
	case <-time.After(5 * time.Second):
		t.Fatal("no reply 5 s after sessionMu was released")
	}
	return ""
}

// W1: Q116's window 1. The entry deadline (300 ms) expires before the first WAIT is due (400 ms), so only the
// per-tick re-arm keeps the WAIT lines and the OK writable.
func TestLogoutWait_W1_WaitLinesKeepTheReplyAlive(t *testing.T) {
	logoutWaitVars(t, 300*time.Millisecond, 400*time.Millisecond, 50*time.Millisecond)
	got := logoutWaitReply(t, t.TempDir(), "LOGOUT\n", 1200*time.Millisecond)
	lines := strings.Split(got, "\n")
	if lines[len(lines)-1] != "OK" {
		t.Fatalf("LOGOUT held past its deadline answered %q, want WAIT lines then OK (Q116)", got)
	}
	waits := lines[:len(lines)-1]
	if len(waits) < 2 {
		t.Fatalf("LOGOUT held past its deadline wrote %d WAIT lines in %q, want 2 or more (Q116)", len(waits), got)
	}
	re := regexp.MustCompile(`^WAIT [0-9]+$`)
	for _, l := range waits {
		if !re.MatchString(l) {
			t.Fatalf("line %q is not `WAIT <seconds>` in %q", l, got)
		}
	}
}

// W2: no WAIT line before logoutWaitFirst.
func TestLogoutWait_W2_NoWaitLineBeforeFirst(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, 200*time.Millisecond, 10*time.Millisecond)
	if got := logoutWaitReply(t, t.TempDir(), "LOGOUT\n", 50*time.Millisecond); got != "OK" {
		t.Fatalf("a wait shorter than logoutWaitFirst answered %q, want exactly OK", got)
	}
}

// W3: a free lock answers at once.
func TestLogoutWait_W3_FreeLockAnswersAtOnce(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, 400*time.Millisecond, 50*time.Millisecond)
	if got := driveLogin(t, t.TempDir(), "LOGOUT\n"); got != "OK" {
		t.Fatalf("LOGOUT with a free lock answered %q, want exactly OK", got)
	}
}

// W4: every other serialized verb takes its first line as the answer, so it never gets a WAIT line.
func TestLogoutWait_W4_OtherVerbsGetNoWaitLine(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, 100*time.Millisecond, 100*time.Millisecond)
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, "apps.out"), []byte("com.example.app\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := logoutWaitReply(t, dest, "GET-APPS\n", 250*time.Millisecond); got != "com.example.app" {
		t.Fatalf("GET-APPS held 250 ms answered %q, want exactly com.example.app", got)
	}
}
