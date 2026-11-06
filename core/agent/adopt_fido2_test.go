package main

// ADOPT-FIDO2 (NWP-20261111-04, Q016): the stranded phone's "Use your security key". The verb is scoped to the
// session's own Android user and runs roamd's fido2adopt through adoptFido2Worker; on OK the daemon adopts the stash
// roamd wrote. The worker and the peer-uid read are stubbed, so no test here reaches the real triggerRoamWorker.

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const avfHMAC = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

type avfCall struct{ dest, op, name, pass, uid string }

type avfFixture struct {
	dest  string
	reply string // what the stubbed worker answers
	calls []avfCall
}

// avfSetup marks a stored session of name (each test its own profile) whose caller is the session's own user, and
// stubs the worker: an "OK" reply writes the hmac stash first, as roamd's fido2adopt does.
func avfSetup(t *testing.T, name string, session bool) *avfFixture {
	t.Helper()
	f := &avfFixture{dest: t.TempDir(), reply: "OK"}
	t.Setenv("NOWHERE_STATE", f.dest)
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	if session {
		if err := markRoamSession(f.dest, name, "pw-"+name, euUID, ""); err != nil {
			t.Fatal(err)
		}
	}
	oldWorker, oldPeer := adoptFido2Worker, sessionPeerUID
	t.Cleanup(func() { adoptFido2Worker, sessionPeerUID = oldWorker, oldPeer })
	sessionPeerUID = func(net.Conn) int { return 10*100000 + 10123 }
	adoptFido2Worker = func(dest, op, name, pass, uid, se string, onProg func(string)) string {
		f.calls = append(f.calls, avfCall{dest, op, name, pass, uid})
		if f.reply == "OK" {
			if err := os.WriteFile(filepath.Join(dest, ".fido2hmac"), []byte(avfHMAC), 0o600); err != nil {
				t.Error(err)
			}
		}
		return f.reply
	}
	return f
}

func avfSend(t *testing.T, dest string) string {
	t.Helper()
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { handleLogin(srv, dest); close(done) }()
	cli.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := cli.Write([]byte("ADOPT-FIDO2\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	line, err := bufio.NewReader(cli).ReadString('\n')
	cli.Close()
	<-done
	if err != nil {
		t.Fatalf("ADOPT-FIDO2: no reply line (%v), got %q", err, line)
	}
	return strings.TrimSpace(line)
}

func TestAdoptFido2Verb_OwnCallerAdoptsTheKey(t *testing.T) {
	f := avfSetup(t, "avf-own", true)
	if got := avfSend(t, f.dest); got != "OK" {
		t.Fatalf("reply %q, want OK", got)
	}
	if len(f.calls) != 1 {
		t.Fatalf("worker ran %d times, want 1", len(f.calls))
	}
	if c := f.calls[0]; c != (avfCall{f.dest, "fido2adopt", "avf-own", "pw-avf-own", euUID}) {
		t.Errorf("worker called with %+v, want op fido2adopt with the session's name, pass and uid", c)
	}
	if got := os.Getenv("NOWHERE_FIDO2_HMAC"); got != avfHMAC {
		t.Errorf("NOWHERE_FIDO2_HMAC = %q after OK, want the adopted stash: the daemon's own seals would not open", got)
	}
}

func TestAdoptFido2Verb_AnotherUsersCallerIsDenied(t *testing.T) {
	for _, puid := range []int{11*100000 + 10123, 0, -1} {
		f := avfSetup(t, "avf-other", true)
		sessionPeerUID = func(net.Conn) int { return puid }
		if got := avfSend(t, f.dest); got != "ERR-DENIED" {
			t.Errorf("peer uid %d: reply %q, want ERR-DENIED", puid, got)
		}
		if len(f.calls) != 0 {
			t.Errorf("peer uid %d: the worker ran %d times for a caller outside the session's user", puid, len(f.calls))
		}
		if got := os.Getenv("NOWHERE_FIDO2_HMAC"); got != "" {
			t.Errorf("peer uid %d: NOWHERE_FIDO2_HMAC = %q", puid, got)
		}
	}
}

func TestAdoptFido2Verb_NoSession(t *testing.T) {
	f := avfSetup(t, "avf-none", false)
	if got := avfSend(t, f.dest); got != "ERR-NOSESSION" {
		t.Errorf("reply %q, want ERR-NOSESSION", got)
	}
	if len(f.calls) != 0 {
		t.Errorf("the worker ran %d times with no session", len(f.calls))
	}
}

func TestAdoptFido2Verb_NoKey(t *testing.T) {
	f := avfSetup(t, "avf-nokey", true)
	f.reply = "ERR-NOKEY"
	if got := avfSend(t, f.dest); got != "ERR-NOKEY" {
		t.Errorf("reply %q, want ERR-NOKEY", got)
	}
	if len(f.calls) != 1 {
		t.Errorf("worker ran %d times, want 1", len(f.calls))
	}
	if got := os.Getenv("NOWHERE_FIDO2_HMAC"); got != "" {
		t.Errorf("NOWHERE_FIDO2_HMAC = %q after a failed adopt", got)
	}
}

func TestAdoptFido2Verb_NotStoredAndWorkerError(t *testing.T) {
	for _, mark := range []func(string){markLocalSession, markOfflineSession} {
		f := avfSetup(t, "avf-local", true)
		mark(f.dest)
		if got := avfSend(t, f.dest); got != "ERR-NOTSTORED" {
			t.Errorf("reply %q, want ERR-NOTSTORED", got)
		}
		if len(f.calls) != 0 {
			t.Errorf("the worker ran %d times for a session with no stored profile", len(f.calls))
		}
	}
	f := avfSetup(t, "avf-timeout", true)
	f.reply = "ERR-TIMEOUT"
	if got := avfSend(t, f.dest); got != "ERR" {
		t.Errorf("worker ERR-TIMEOUT: reply %q, want ERR", got)
	}
}
