package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// unixRoundTrip runs handler on the server end of a REAL unix socketpair (so SO_PEERCRED works -- net.Pipe
// conns are not unix sockets and peerUID correctly fails closed on them) and returns everything the handler
// wrote. The in-process peer uid is our own uid, which is < 100000 in any sane test env -> passes the user-0
// gate check the daemon applies on-device.
func unixRoundTrip(t *testing.T, handler func(net.Conn)) string {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "s")
	l, err := net.Listen("unix", sock)
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
		handler(c)
		c.Close()
	}()
	cli, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(cli)
	cli.Close()
	<-done
	return string(b)
}

// #97: RELOGIN (from the roamed offline session) queues the creds one-shot + runs the no-seal local logoff;
// GET-RELOGIN (user-0 gate) collects them exactly once. A non-offline session is refused.
func TestReloginFlow(t *testing.T) {
	dest := t.TempDir()

	// No session at all -> NONE, nothing queued.
	if got := strings.TrimSpace(unixRoundTrip(t, func(c net.Conn) { handleRelogin(c, dest) })); got != "NONE" {
		t.Fatalf("no session: got %q want NONE", got)
	}

	// A live ONLINE (non-offline) session must be refused -- RELOGIN only discards offline scratch sessions.
	markRoamSession(dest, "carol", "correct horse", "13", "")
	if got := strings.TrimSpace(unixRoundTrip(t, func(c net.Conn) { handleRelogin(c, dest) })); got != "NONE" {
		t.Fatalf("online session: got %q want NONE", got)
	}
	if _, err := os.Stat(filepath.Join(dest, ".relogin")); !os.IsNotExist(err) {
		t.Fatal("refused RELOGIN must not queue creds")
	}

	// The store holds carol's head, so the OK arm below means a stored profile (NWP-20261103-02).
	base := newHTTPStore(t)
	oldBase := reloginStoreBase
	reloginStoreBase = base
	t.Cleanup(func() { reloginStoreBase = oldBase })
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	if createVault(base, "carol", "correct horse") == "" {
		t.Fatal("createVault returned no recovery code")
	}

	// A live OFFLINE session: RELOGIN queues creds + runs the local logoff (OK; markers cleared; reap queued).
	markLocalSession(dest)
	markOfflineSession(dest)
	if got := strings.TrimSpace(unixRoundTrip(t, func(c net.Conn) { handleRelogin(c, dest) })); got != "OK" {
		t.Fatalf("offline RELOGIN: got %q want OK", got)
	}
	if isOfflineSession(dest) {
		t.Error("offline marker must be cleared by RELOGIN")
	}
	if n, _, _ := readRoamSession(dest); n != "" {
		t.Error("roam session must be cleared by the logoff")
	}
	pendingReapMu.Lock()
	if pendingReapUID != "13" || pendingSwitchUID != "13" {
		t.Errorf("reap not queued: reap=%q switch=%q", pendingReapUID, pendingSwitchUID)
	}
	pendingReapUID, pendingSwitchUID = "", "" // reset shared state for other tests
	pendingReapMu.Unlock()

	// GET-RELOGIN hands the creds back exactly once.
	got := unixRoundTrip(t, func(c net.Conn) { handleGetRelogin(c, dest) })
	if want := "OK\ncarol\ncorrect horse\n"; got != want {
		t.Fatalf("GET-RELOGIN: got %q want %q", got, want)
	}
	if got := strings.TrimSpace(unixRoundTrip(t, func(c net.Conn) { handleGetRelogin(c, dest) })); got != "NONE" {
		t.Fatalf("second GET-RELOGIN: got %q want NONE (one-shot)", got)
	}
}

// GET-RELOGIN must fail CLOSED for a caller whose peer uid can't be read -- net.Pipe is not a unix socket,
// standing in for any conn where SO_PEERCRED is unavailable. (On-device the real check is uid<100000: user-0
// gate/system only, never an app inside a roamed session.)
func TestGetReloginFailsClosedWithoutPeerCred(t *testing.T) {
	dest := t.TempDir()
	os.WriteFile(filepath.Join(dest, ".relogin"), []byte("carol\npw\n"), 0o600)
	cli, srv := net.Pipe()
	go func() { handleGetRelogin(srv, dest); srv.Close() }()
	b, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(b)); got != "NONE" {
		t.Fatalf("pipe caller: got %q want NONE", got)
	}
}
