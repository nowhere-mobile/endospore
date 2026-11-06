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

// NWP-20261119-29: ROLLBACK read a missing or malformed version as 0, which rollbackHead takes as the newest
// snapshot, and REMOVE-FIDO2-KEY read a missing credID line as "" ("remove every key"). A request whose argument line
// never arrived rolled the head back and ended the session unsaved, or stripped every security key. These tests pin
// the refusals; test-strict-arg-line.sh re-runs them against main.go with each refusal removed.

// strictArgDrive sends req to handleLogin over a REAL unix socket (net.Pipe cannot half-close), closes the client's
// write side so the daemon's next ReadString returns io.EOF at once, and returns the trimmed reply. The socket dir
// is short (os.MkdirTemp("", "sa")): a t.TempDir() path can pass the 108-byte sun_path limit. The 20s is a hang
// guard, not a timing claim.
func strictArgDrive(t *testing.T, dest, req string) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "sa")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	l, err := net.Listen("unix", filepath.Join(dir, "s"))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		c, err := l.Accept()
		if err != nil {
			return
		}
		handleLogin(c, dest) // closes c itself
	}()
	cli, err := net.Dial("unix", filepath.Join(dir, "s"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	if _, err := cli.Write([]byte(req)); err != nil {
		t.Fatal(err)
	}
	if err := cli.(*net.UnixConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- string(b)
	}()
	select {
	case got := <-reply:
		<-done
		return strings.TrimSpace(got)
	case <-time.After(20 * time.Second):
		t.Fatalf("%q: handleLogin did not answer within 20s", req)
		return ""
	}
}

// strictArgNothingChanged fails unless the rollback left the session as it was: the head never rolled, .roamsession
// and the keystore-push stash are still there, and no switch or reap was queued.
func strictArgNothingChanged(t *testing.T, f *rbFixture, what string) {
	t.Helper()
	if f.called != 0 {
		t.Errorf("%s: the head was rolled %d time(s)", what, f.called)
	}
	if n, _, _ := readRoamSession(f.dest); n != "alice" {
		t.Errorf("%s: .roamsession was dropped", what)
	}
	if _, err := os.Stat(filepath.Join(f.dest, ksLogoffCredsFile)); err != nil {
		t.Errorf("%s: the keystore-push stash was removed: %v", what, err)
	}
	pendingReapMu.Lock()
	sw, rp := pendingSwitchUID, pendingReapUID
	pendingReapMu.Unlock()
	if sw != "" || rp != "" {
		t.Errorf("%s: a teardown was queued (%q, %q)", what, sw, rp)
	}
}

// rollWith is rbFixture.roll with the version string given.
func (f *rbFixture) rollWith(ver string) string {
	a, b := net.Pipe()
	defer a.Close()
	done := make(chan string)
	go func() {
		buf := make([]byte, 256)
		n, _ := b.Read(buf)
		done <- string(buf[:n])
	}()
	handleRollback(a, f.dest, ver)
	a.Close()
	return strings.TrimSpace(<-done)
}

func TestStrictArgLine_RollbackRefusesABadVersion(t *testing.T) {
	for _, v := range []string{"", "0", "-1", "abc", "3x"} {
		f := rbSetup(t)
		if got := f.rollWith(v); got != "ERR" {
			t.Errorf("version %q: got %q, want ERR", v, got)
		}
		strictArgNothingChanged(t, f, "version "+`"`+v+`"`)
	}
	f := rbSetup(t)
	if got := f.rollWith("3"); got != "OK 7" || f.called != 1 {
		t.Errorf("version \"3\": got %q (head rolled %d times), want OK 7 and one roll", got, f.called)
	}
}

func TestStrictArgLine_RollbackMissingLine(t *testing.T) {
	f := rbSetup(t)
	if got := strictArgDrive(t, f.dest, "ROLLBACK\n"); got != "ERR" {
		t.Errorf("ROLLBACK with no version line: got %q, want ERR", got)
	}
	strictArgNothingChanged(t, f, "ROLLBACK with no version line")
}

func TestStrictArgLine_RollbackUnterminatedLine(t *testing.T) {
	f := rbSetup(t)
	if got := strictArgDrive(t, f.dest, "ROLLBACK\n3"); got != "ERR" {
		t.Errorf("ROLLBACK with an unterminated version line: got %q, want ERR", got)
	}
	strictArgNothingChanged(t, f, "ROLLBACK with an unterminated version line")
}

func TestStrictArgLine_RemoveKeyMissingLine(t *testing.T) {
	dest := t.TempDir() // no .roamsession: a request that reaches the arm's session check answers ERR-NOSESSION
	t.Setenv("NOWHERE_STATE", dest)
	for _, c := range []struct{ req, want string }{
		{"REMOVE-FIDO2-KEY\n", "ERR"},
		{"REMOVE-FIDO2-KEY\nAAAA", "ERR"},
		{"REMOVE-FIDO2-KEY\nAAAA\n", "ERR-NOSESSION"}, // control: a whole line still reaches the session check
	} {
		if got := strictArgDrive(t, dest, c.req); got != c.want {
			t.Errorf("%q: got %q, want %q", c.req, got, c.want)
		}
	}
	// NWP-20261127-02: the arm also needs the session's uid (the tap runs as roamd's fido2adopt for that user). A
	// marker that lost its uid line is damaged; readRoamSession reads it as no session, so the arm answers
	// ERR-NOSESSION and never reaches the worker.
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte("sa-nouid\npw-sa-nouid\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := strictArgDrive(t, dest, "REMOVE-FIDO2-KEY\nAAAA\n"); got != "ERR-NOSESSION" {
		t.Errorf("a marker with no uid: got %q, want ERR-NOSESSION", got)
	}
}
