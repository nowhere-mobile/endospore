package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// NWP-20260922-05: GET-SESSION-NAME must name the profile to its OWN session and to nobody else.
//
// ⚠ EVERY NEGATIVE CASE MUST BE THE SAME ANSWER. The verb exists because the profile name leaked through
// the Android user record; a verb that distinguished "no session" from "wrong user" would reintroduce a
// weaker form of the same leak, by confirming that SOME session is live. So the assertion is not merely
// "it refused" -- it is that all three refusals are byte-identical.
//
// The peer identity is real, not stubbed: these use an actual unix socket so peerUID's SO_PEERCRED
// getsockopt runs. A net.Pipe would return -1 and only ever exercise the fail-closed branch, which would
// make the positive case untestable and the whole suite vacuous.
func sessionNameConn(t *testing.T) (server net.Conn, client net.Conn) {
	t.Helper()
	dir := t.TempDir()
	sock := filepath.Join(dir, "s")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skipf("unix sockets unavailable here (%v) -- this test needs SO_PEERCRED", err)
	}
	t.Cleanup(func() { ln.Close() })
	done := make(chan net.Conn, 1)
	go func() {
		c, _ := ln.Accept()
		done <- c
	}()
	client, err = net.Dial("unix", sock)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server = <-done
	if server == nil {
		t.Fatal("accept returned nil")
	}
	t.Cleanup(func() { client.Close(); server.Close() })
	return server, client
}

func askSessionName(t *testing.T, dest string) string {
	t.Helper()
	server, client := sessionNameConn(t)
	go func() { handleGetSessionName(server, dest); server.Close() }()
	line, err := bufio.NewReader(client).ReadString('\n')
	if err != nil && line == "" {
		t.Fatalf("read: %v", err)
	}
	return strings.TrimRight(line, "\n")
}

// ourUserID is the Android userId the test process would present over SO_PEERCRED. On a build host this is
// 0 for an ordinary uid, which is exactly what makes the OWNER case reachable without faking credentials.
func ourUserID() string { return strconv.Itoa(os.Getuid() / 100000) }

func TestGetSessionNameServesOnlyTheOwningSession(t *testing.T) {
	const want = "alice"

	t.Run("no live session -> NONE", func(t *testing.T) {
		if got := askSessionName(t, t.TempDir()); got != "NONE" {
			t.Errorf("got %q, want NONE -- with no marker there is no name to give", got)
		}
	})

	t.Run("the session's own user gets the name", func(t *testing.T) {
		dest := t.TempDir()
		if err := markRoamSession(dest, want, "pw", ourUserID(), ""); err != nil {
			t.Fatal(err)
		}
		if got := askSessionName(t, dest); got != want {
			t.Errorf("got %q, want %q -- the Profile screen cannot render who it is", got, want)
		}
	})

	t.Run("a DIFFERENT user gets NONE, not the name", func(t *testing.T) {
		dest := t.TempDir()
		// A uid this process cannot be. If this ever equals ourUserID the test proves nothing, so pin it.
		other := "77"
		if other == ourUserID() {
			t.Fatalf("fixture uid %q collides with the test process's own -- the case is vacuous", other)
		}
		if err := markRoamSession(dest, want, "pw", other, ""); err != nil {
			t.Fatal(err)
		}
		if got := askSessionName(t, dest); got != "NONE" {
			t.Errorf("got %q, want NONE -- a name was served to a user that does not own the session", got)
		}
	})

	t.Run("all refusals are byte-identical", func(t *testing.T) {
		noSession := askSessionName(t, t.TempDir())
		other := t.TempDir()
		if err := markRoamSession(other, want, "pw", "77", ""); err != nil {
			t.Fatal(err)
		}
		wrongUser := askSessionName(t, other)
		if noSession != wrongUser {
			t.Errorf("refusals differ: no-session=%q wrong-user=%q. A caller could tell the two apart and "+
				"learn that SOME session is live -- a weaker form of the leak this verb exists to close",
				noSession, wrongUser)
		}
	})
}

// The fail-closed branch on its own: a connection whose peer cannot be identified must be refused, not
// served. net.Pipe is not a *net.UnixConn, so peerUID returns -1 -- the "cannot tell who is asking" case.
func TestGetSessionNameFailsClosedOnAnUnidentifiablePeer(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", ourUserID(), ""); err != nil {
		t.Fatal(err)
	}
	server, client := net.Pipe()
	go func() { handleGetSessionName(server, dest); server.Close() }()
	line, _ := bufio.NewReader(client).ReadString('\n')
	client.Close()
	if line != "NONE\n" {
		t.Errorf("got %q, want \"NONE\\n\" -- an unidentifiable caller must never be told the profile name", line)
	}
}
