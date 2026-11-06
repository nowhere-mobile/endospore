package main

import (
	"bufio"
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261006-23: a store read that fails is not an answer. LIST-FIDO2 turned it into "OK 0" and PIN-STATUS into
// "NONE", so the Profile app told a profile that has a security key, or a PIN, that it has none.

func firstLine(t *testing.T, h func(net.Conn)) string {
	t.Helper()
	server, client := net.Pipe()
	defer client.Close()
	go func() { h(server); server.Close() }()
	client.SetDeadline(time.Now().Add(30 * time.Second))
	l, _ := bufio.NewReader(client).ReadString('\n')
	return strings.TrimSpace(l)
}

func sessionFor(t *testing.T, name, pass string) string {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, name, pass, "12", ""); err != nil {
		t.Fatal(err)
	}
	return dest
}

func TestListFido2SaysERRWhenTheStoreFails(t *testing.T) {
	dest := sessionFor(t, "alice", "pw one two")
	dead := deadStore(t)
	if got := firstLine(t, func(c net.Conn) { handleListFido2(c, dest, dead) }); got != "ERR" {
		t.Errorf("a dead store answered %q, want ERR", got)
	}
	base := newHTTPStore(t)
	if got := firstLine(t, func(c net.Conn) { handleListFido2(c, dest, base) }); got != "OK 0" {
		t.Errorf("control: a profile with no head yet answered %q, want OK 0 (nothing sealed, nothing enrolled)", got)
	}
	createVault(base, "alice", "pw one two")
	if got := firstLine(t, func(c net.Conn) { handleListFido2(c, dest, base) }); got != "OK 0" {
		t.Errorf("control: a vault with no keys answered %q, want OK 0", got)
	}
}

func TestPinStatusSaysERRWhenTheStoreFails(t *testing.T) {
	dest := sessionFor(t, "bob", "pw three four")
	if got := firstLine(t, func(c net.Conn) { handlePinStatus(c, dest, deadStore(t)) }); got != "ERR" {
		t.Errorf("a dead store answered %q, want ERR", got)
	}
	base := newHTTPStore(t)
	createVault(base, "bob", "pw three four")
	if got := firstLine(t, func(c net.Conn) { handlePinStatus(c, dest, base) }); got != "NONE" {
		t.Errorf("control: a vault with no PIN answered %q, want NONE", got)
	}
}

func TestGetSnapshotsSaysERRWhenTheStoreFails(t *testing.T) {
	dest := sessionFor(t, "carol", "pw five six")
	if got := firstLine(t, func(c net.Conn) { handleGetSnapshots(c, dest, deadStore(t)) }); got != "ERR" {
		t.Errorf("a dead store answered %q, want ERR (it used to read as EMPTY: \"No earlier versions yet\")", got)
	}
	base := newHTTPStore(t)
	createVault(base, "carol", "pw five six")
	if got := firstLine(t, func(c net.Conn) { handleGetSnapshots(c, dest, base) }); got != "EMPTY" {
		t.Errorf("control: a fresh vault answered %q, want EMPTY", got)
	}
}
