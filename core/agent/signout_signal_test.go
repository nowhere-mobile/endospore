package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// signOutSignalIsOpen reports whether the current signOutWaiting() channel is still open.
func signOutSignalIsOpen() bool {
	select {
	case <-signOutWaiting():
		return false
	default:
		return true
	}
}

// signOutReset puts the signal in its lowered state directly, not through signOutLower, and removes dest/od-cancel:
// each test starts from, and leaves behind, a fresh open channel even when the code under test is broken (a mutant
// that never replaces the channel must fail its own assertions, not panic the next test on a double close).
func signOutReset(t *testing.T, dest string) {
	t.Helper()
	reset := func() {
		signOutMu.Lock()
		signOutC = make(chan struct{})
		signOutRaised = false
		signOutMu.Unlock()
		os.Remove(filepath.Join(dest, odCancelFile))
	}
	reset()
	t.Cleanup(reset)
}

// signOutCall runs f and turns a panic into a test failure, so a broken raise or lower fails here with its cause.
func signOutCall(t *testing.T, what string, f func()) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("%s panicked: %v", what, r)
		}
	}()
	f()
}

// signOutMarkerExists Lstats dest/od-cancel, as odCancelRequested does.
func signOutMarkerExists(t *testing.T, dest string) bool {
	t.Helper()
	_, err := os.Lstat(filepath.Join(dest, odCancelFile))
	if err == nil {
		return true
	}
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("lstat od-cancel: %v", err)
	}
	return false
}

// S1: Q116's cancel producer. While LOGOUT waits for a held sessionMu, the marker the materialise worker reads
// (NWP-20261109-11) exists and signOutWaiting() is closed; once LOGOUT holds the lock both are lowered.
func TestSignOutSignal_S1_RaisedWhileLogoutWaits(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, time.Second, 50*time.Millisecond)
	dest := t.TempDir()
	signOutReset(t, dest)
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	c := driveLoginAsync(t, dest, "LOGOUT\n")
	deadline := time.Now().Add(2 * time.Second)
	for !signOutMarkerExists(t, dest) {
		if time.Now().After(deadline) {
			t.Fatal("LOGOUT waiting for sessionMu never raised dest/od-cancel (Q116)")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if signOutSignalIsOpen() {
		t.Fatal("signOutWaiting() is open while LOGOUT waits for sessionMu, want closed (Q116)")
	}
	sessionMu.Unlock()
	held = false
	select {
	case got := <-c:
		lines := strings.Split(got, "\n")
		if lines[len(lines)-1] != "OK" {
			t.Fatalf("LOGOUT answered %q, want OK last", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no reply 5 s after sessionMu was released")
	}
	if signOutMarkerExists(t, dest) {
		t.Fatal("dest/od-cancel left behind after LOGOUT took the lock: the next session's download would be cancelled")
	}
	if !signOutSignalIsOpen() {
		t.Fatal("signOutWaiting() still closed after LOGOUT took the lock, want a fresh open channel")
	}
}

// S2: a LOGOUT that finds sessionMu free asks nothing of anyone.
func TestSignOutSignal_S2_FreeLockRaisesNothing(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, time.Second, 50*time.Millisecond)
	dest := t.TempDir()
	signOutReset(t, dest)
	n0 := signOutRaises.Load()
	if got := driveLogin(t, dest, "LOGOUT\n"); got != "OK" {
		t.Fatalf("LOGOUT on a free lock answered %q, want OK", got)
	}
	if n := signOutRaises.Load(); n != n0 {
		t.Fatalf("LOGOUT on a free lock raised the sign-out signal %d time(s), want 0", n-n0)
	}
	if signOutMarkerExists(t, dest) {
		t.Fatal("LOGOUT on a free lock left dest/od-cancel")
	}
	if !signOutSignalIsOpen() {
		t.Fatal("signOutWaiting() closed after a LOGOUT on a free lock")
	}
}

// S3: raise and lower are idempotent -- a second raise must not double-close, and each lower installs an open channel.
func TestSignOutSignal_S3_RaiseLowerTwice(t *testing.T) {
	dest := t.TempDir()
	signOutReset(t, dest)
	raise := func() { signOutCall(t, "signOutRaise", func() { signOutRaise(dest) }) }
	lower := func() { signOutCall(t, "signOutLower", func() { signOutLower(dest) }) }
	lower() // nothing raised, no file: must not panic
	for i := 0; i < 2; i++ {
		raise()
		raise()
		if !signOutMarkerExists(t, dest) {
			t.Fatalf("round %d: no dest/od-cancel after a raise", i)
		}
		if signOutSignalIsOpen() {
			t.Fatalf("round %d: signOutWaiting() open after a raise", i)
		}
		lower()
		if signOutMarkerExists(t, dest) {
			t.Fatalf("round %d: dest/od-cancel left after a lower", i)
		}
		if !signOutSignalIsOpen() {
			t.Fatalf("round %d: signOutWaiting() closed after a lower", i)
		}
	}
}

// S4 (source): loginDaemon clears a marker a dead daemon left before it serves the socket.
func TestSignOutSignal_S4_DaemonStartClearsMarker(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\nfunc loginDaemon() {")
	if i < 0 {
		t.Fatal("main.go has no func loginDaemon()")
	}
	body := src[i+1:]
	if j := strings.Index(body, "\nfunc "); j >= 0 {
		body = body[:j]
	}
	rm := strings.Index(body, "os.Remove(filepath.Join(dest, odCancelFile))")
	acc := strings.Index(body, "syscall.Accept(fd)")
	if acc < 0 {
		t.Fatal("loginDaemon has no syscall.Accept(fd) accept loop")
	}
	if rm < 0 || rm > acc {
		t.Fatal("loginDaemon does not remove dest/od-cancel before it serves the socket: a stale marker would cancel the next session's first download (Q116)")
	}
}
