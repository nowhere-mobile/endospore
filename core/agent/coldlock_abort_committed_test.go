package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261124-04: COLD-LOCK-ABORT after the point of no return. The commit writes .coldlock and removes
// .roamsession, so armColdLockAbort refuses; the arm answers COMMITTED when .coldlock names the abort's uid, and OK
// for every other rejection. Driven through the REAL dispatcher, so the test also proves the verb is wired.

// abortCommittedConn sends one request through handleLogin over a net.Pipe and returns the reply line.
func abortCommittedConn(t *testing.T, dest, req string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go cli.Write([]byte(req))
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- string(b)
	}()
	handleLogin(srv, dest) // closes srv itself
	select {
	case s := <-reply:
		cli.Close()
		return strings.TrimRight(s, "\r\n")
	case <-time.After(5 * time.Second):
		t.Fatalf("%q: no reply within 5s", req)
		return ""
	}
}

// abortCommittedSetup gives the test its own dest, plants .coldlock naming coldUID ("" plants none), and saves and
// zeroes lastPresentAt, restoring it when the test ends.
func abortCommittedSetup(t *testing.T, coldUID string) string {
	t.Helper()
	dest := t.TempDir()
	if coldUID != "" {
		body := "p1475\n" + coldUID + "\n\n\n\n\n\n"
		if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	prev := lastPresentAt.Load()
	lastPresentAt.Store(0)
	t.Cleanup(func() { lastPresentAt.Store(prev) })
	return dest
}

// (a) The lock this user's teardown committed: no live session, .coldlock names uid 12.
func TestColdLockAbortAfterCommitAnswersCommitted(t *testing.T) {
	dest := abortCommittedSetup(t, "12")
	if got := abortCommittedConn(t, dest, "COLD-LOCK-ABORT\n12\n5000\n"); got != "COMMITTED" {
		t.Fatalf("abort after the commit answered %q, want COMMITTED", got)
	}
	if got := lastPresentAt.Load(); got != 0 {
		t.Fatalf("abort after the commit moved lastPresentAt to %d: nothing may be armed", got)
	}
}

// (b) A stale abort for another session: .coldlock names uid 13, the abort is for 12.
func TestColdLockAbortOtherUidAnswersOK(t *testing.T) {
	dest := abortCommittedSetup(t, "13")
	if got := abortCommittedConn(t, dest, "COLD-LOCK-ABORT\n12\n5000\n"); got != "OK" {
		t.Fatalf("abort for another uid answered %q, want OK", got)
	}
	if got := lastPresentAt.Load(); got != 0 {
		t.Fatalf("abort for another uid moved lastPresentAt to %d: nothing may be armed", got)
	}
}

// (c) A live session for 12: the abort arms as before and answers OK.
func TestColdLockAbortLiveSessionArms(t *testing.T) {
	dest := abortCommittedSetup(t, "")
	if err := writeRoamSession(dest, "p1475", "pw1475", "12", "", true); err != nil {
		t.Fatal(err)
	}
	if got := abortCommittedConn(t, dest, "COLD-LOCK-ABORT\n12\n5000\n"); got != "OK" {
		t.Fatalf("abort of the live session answered %q, want OK", got)
	}
	if got := lastPresentAt.Load(); got != 5000 {
		t.Fatalf("abort of the live session left lastPresentAt at %d, want 5000", got)
	}
}

// (d) A malformed stamp is a rejection, even when .coldlock names the uid.
func TestColdLockAbortMalformedStampAnswersOK(t *testing.T) {
	dest := abortCommittedSetup(t, "12")
	if got := abortCommittedConn(t, dest, "COLD-LOCK-ABORT\n12\nxyz\n"); got != "OK" {
		t.Fatalf("abort with a malformed stamp answered %q, want OK", got)
	}
}

// (e) An empty uid with no marker is a rejection.
func TestColdLockAbortEmptyUIDAnswersOK(t *testing.T) {
	dest := abortCommittedSetup(t, "")
	if got := abortCommittedConn(t, dest, "COLD-LOCK-ABORT\n\n5000\n"); got != "OK" {
		t.Fatalf("abort with an empty uid answered %q, want OK", got)
	}
}

// (f) Another session is live: a .coldlock naming 12 is not this abort's commit while user 14's session runs.
func TestColdLockAbortOtherLiveSessionAnswersOK(t *testing.T) {
	dest := abortCommittedSetup(t, "12")
	if err := writeRoamSession(dest, "p1475f", "pw1475f", "14", "", true); err != nil {
		t.Fatal(err)
	}
	if got := abortCommittedConn(t, dest, "COLD-LOCK-ABORT\n12\n5000\n"); got != "OK" {
		t.Fatalf("abort for 12 with user 14 live answered %q, want OK", got)
	}
	if got := lastPresentAt.Load(); got != 0 {
		t.Fatalf("abort for 12 with user 14 live moved lastPresentAt to %d: nothing may be armed", got)
	}
}
