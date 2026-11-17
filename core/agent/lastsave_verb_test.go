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

// NWP-20261205-01: GET-LASTSAVE (lastsave_verb.go). The fixture is the agent slice's (NWP-20261204-01) file line.
const lastSaveVerbFix = "v=1 unsaved=de=unreachable t=1763100000\n"

// lastSaveVerbAt is a valid line of exactly n bytes, LF included.
func lastSaveVerbAt(t *testing.T, n int) string {
	t.Helper()
	head, tail := "v=1 unsaved=de=", " t=1\n"
	s := head + strings.Repeat("a", n-len(head)-len(tail)) + tail
	if len(s) != n {
		t.Fatalf("fixture is %d bytes, want %d", len(s), n)
	}
	return s
}

func TestLastSaveVerbWire(t *testing.T) {
	at256 := lastSaveVerbAt(t, 256)
	cases := []struct {
		name, body, uid, want string
		write                 bool
	}{
		{"fixture", lastSaveVerbFix, "10", "LASTSAVE v=1 unsaved=de=unreachable t=1763100000", true},
		{"256 bytes", at256, "10", "LASTSAVE " + strings.TrimSuffix(at256, "\n"), true},
		{"missing file", "", "10", "NONE", false},
		{"257 bytes", lastSaveVerbAt(t, 257), "10", "NONE", true},
		{"no LF", strings.TrimSuffix(lastSaveVerbFix, "\n"), "10", "NONE", true},
		{"two lines", "v=1 unsaved=de=a t=1\nv=1 unsaved=de=b t=2\n", "10", "NONE", true},
		{"a CR", "v=1 unsaved=de=a\r t=1\n", "10", "NONE", true},
		{"v=2", "v=2 unsaved=de=a t=1\n", "10", "NONE", true},
		{"uid 1a", lastSaveVerbFix, "1a", "NONE", true},
		{"uid empty", lastSaveVerbFix, "", "NONE", true},
	}
	for _, c := range cases {
		dir := t.TempDir()
		if c.write {
			if err := os.WriteFile(filepath.Join(dir, "lastsave."+c.uid), []byte(c.body), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if got := lastSaveWire(dir, c.uid); got != c.want {
			t.Errorf("%s: lastSaveWire = %q, want %q", c.name, got, c.want)
		}
	}
}

// lastSaveVerbDrive runs handleGetLastSave over a pipe and returns the raw reply.
func lastSaveVerbDrive(t *testing.T, dest string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go func() { handleGetLastSave(srv, dest); srv.Close() }()
	reply := make(chan string, 1)
	go func() { b, _ := io.ReadAll(cli); reply <- string(b) }()
	select {
	case got := <-reply:
		cli.Close()
		return got
	case <-time.After(20 * time.Second):
		cli.Close()
		t.Fatal("no reply to GET-LASTSAVE")
		return ""
	}
}

func TestLastSaveVerbScoped(t *testing.T) {
	oldPeer := sessionPeerUID
	t.Cleanup(func() { sessionPeerUID = oldPeer })
	asUser := func(u int) { sessionPeerUID = func(net.Conn) int { return u*100000 + 10123 } }

	setup := func(t *testing.T, profile string, file bool) string {
		t.Helper()
		dest := t.TempDir()
		if profile != "" {
			if err := writeRoamSession(dest, profile, "pw", "10", "", true); err != nil {
				t.Fatal(err)
			}
		}
		if file {
			if err := os.WriteFile(filepath.Join(dest, "lastsave.10"), []byte(lastSaveVerbFix), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		return dest
	}

	dest := setup(t, "lsv-s1", true)
	asUser(10)
	if got := lastSaveVerbDrive(t, dest); got != "LASTSAVE v=1 unsaved=de=unreachable t=1763100000\n" {
		t.Errorf("own user: reply %q, want the LASTSAVE line", got)
	}

	dest = setup(t, "lsv-s2", true)
	asUser(11)
	if got := lastSaveVerbDrive(t, dest); got != "NONE\n" {
		t.Errorf("caller in user 11: reply %q, want NONE", got)
	}

	dest = setup(t, "", true)
	asUser(10)
	if got := lastSaveVerbDrive(t, dest); got != "NONE\n" {
		t.Errorf("no session marker: reply %q, want NONE", got)
	}

	dest = setup(t, "lsv-s4", true)
	markOfflineSession(dest)
	asUser(10)
	if got := lastSaveVerbDrive(t, dest); got != "NONE\n" {
		t.Errorf("offline session: reply %q, want NONE", got)
	}

	dest = setup(t, "lsv-s5", false)
	asUser(10)
	if got := lastSaveVerbDrive(t, dest); got != "NONE\n" {
		t.Errorf("no file: reply %q, want NONE", got)
	}
}

func TestLastSaveVerbLockFree(t *testing.T) {
	if !concurrentSafeCmd("GET-LASTSAVE") {
		t.Error("GET-LASTSAVE is not in concurrentSafeCmd: a seal holding sessionMu would delay the landing's read")
	}
}

func TestLastSaveVerbHasALoginArm(t *testing.T) {
	if !parseLoginArms(t).has("GET-LASTSAVE") {
		t.Error("handleLogin has no GET-LASTSAVE arm: the verb falls through to the legacy login, which wipes the state dir")
	}
}
