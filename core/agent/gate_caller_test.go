package main

import (
	"bufio"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261023-05: GET-RELOGIN, GET-WIFI-MIRROR, WIFI-ADOPT and TEL-LIVE-OWNED serve only a peer in user 0. The accept
// loop admits the chooser's appId in ANY user, so a roamed session's chooser reaches all four and gateCallerOK is what
// keeps it out. These cases present the peer through the ownerPeerUID seam (a socketpair can only show the runner's own
// uid). The seam is package-global, so no case here is parallel.

const (
	gateRoamedA = 10*100000 + 10123
	gateRoamedB = 11*100000 + 1000
)

// gatePeer makes every conn look like it came from uid, restoring the seam when the test ends.
func gatePeer(t *testing.T, uid int) {
	t.Helper()
	old := ownerPeerUID
	ownerPeerUID = func(net.Conn) int { return uid }
	t.Cleanup(func() { ownerPeerUID = old })
}

// gateAsk runs one handler over a net.Pipe and returns everything it wrote.
func gateAsk(t *testing.T, h func(c net.Conn)) string {
	t.Helper()
	cli, srv := net.Pipe()
	go func() { h(srv); srv.Close() }()
	b, err := io.ReadAll(cli)
	if err != nil {
		t.Fatalf("read reply: %v", err)
	}
	return string(b)
}

func TestGateCaller_Rule(t *testing.T) {
	for _, c := range []struct {
		uid  int
		want bool
	}{{-1, false}, {0, true}, {1000, true}, {10123, true}, {99999, true}, {100000, false}, {1010123, false}} {
		if got := gateCallerOK(c.uid); got != c.want {
			t.Errorf("gateCallerOK(%d) = %v, want %v", c.uid, got, c.want)
		}
	}
}

func TestGateCaller_GetReloginRefusesRoamedPeer(t *testing.T) {
	for _, uid := range []int{gateRoamedA, gateRoamedB, -1} {
		gatePeer(t, uid)
		dest := t.TempDir()
		if err := writeQueuedRelogin(dest, "carol", "pw-carol"); err != nil {
			t.Fatal(err)
		}
		if got := gateAsk(t, func(c net.Conn) { handleGetRelogin(c, dest) }); got != "NONE\n" {
			t.Errorf("peer %d: got %q, want NONE", uid, got)
		}
		b, err := os.ReadFile(filepath.Join(dest, ".relogin"))
		if err != nil || string(b) != "carol\npw-carol\n" {
			t.Errorf("peer %d: .relogin = %q, %v; want it untouched", uid, b, err)
		}
		if _, err := os.Stat(filepath.Join(dest, reloginTakenFile)); !os.IsNotExist(err) {
			t.Errorf("peer %d: %s exists (err %v); the refused caller must not take the file", uid, reloginTakenFile, err)
		}
	}
}

func TestGateCaller_GetReloginServesUser0(t *testing.T) {
	for _, uid := range []int{10123, 0} {
		gatePeer(t, uid)
		dest := t.TempDir()
		if err := writeQueuedRelogin(dest, "carol", "pw-carol"); err != nil {
			t.Fatal(err)
		}
		if got, want := gateAsk(t, func(c net.Conn) { handleGetRelogin(c, dest) }), "OK\ncarol\npw-carol\n"; got != want {
			t.Errorf("peer %d: got %q, want %q", uid, got, want)
		}
	}
}

func TestGateCaller_GetWifiMirrorRefusesRoamedPeer(t *testing.T) {
	const mirror = "Oviya\thunter2 pass\nCafe Open\t\n"
	for _, uid := range []int{gateRoamedA, gateRoamedB, -1} {
		gatePeer(t, uid)
		dest := t.TempDir()
		p := filepath.Join(dest, ".wifimirror")
		if err := os.WriteFile(p, []byte(mirror), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := gateAsk(t, func(c net.Conn) { handleGetWifiMirror(c, dest) }); got != "NONE\n" {
			t.Errorf("peer %d: got %q, want NONE", uid, got)
		}
		b, err := os.ReadFile(p)
		if err != nil || string(b) != mirror {
			t.Errorf("peer %d: .wifimirror = %q, %v; want it untouched", uid, b, err)
		}
	}
}

func TestGateCaller_GetWifiMirrorServesUser0(t *testing.T) {
	const mirror = "Oviya\thunter2 pass\n"
	for _, uid := range []int{10123, 0} {
		gatePeer(t, uid)
		dest := t.TempDir()
		if err := os.WriteFile(filepath.Join(dest, ".wifimirror"), []byte(mirror), 0o600); err != nil {
			t.Fatal(err)
		}
		if got, want := gateAsk(t, func(c net.Conn) { handleGetWifiMirror(c, dest) }), "OK\n"+mirror; got != want {
			t.Errorf("peer %d: got %q, want %q", uid, got, want)
		}
	}
}

func gateAdopt(t *testing.T) (reply, logged string) {
	t.Helper()
	logged = captureStderr(t, func() {
		reply = gateAsk(t, func(c net.Conn) {
			handleWifiAdopt(c, bufio.NewReader(strings.NewReader("1\n2\n0\n1\n")))
		})
	})
	return
}

func TestGateCaller_WifiAdoptRefusesRoamedPeer(t *testing.T) {
	for _, uid := range []int{gateRoamedA, gateRoamedB, -1} {
		gatePeer(t, uid)
		reply, logged := gateAdopt(t)
		if reply != "ERR\n" {
			t.Errorf("peer %d: reply %q, want ERR", uid, reply)
		}
		if logged != "" {
			t.Errorf("peer %d: logged %q, want nothing", uid, logged)
		}
	}
}

func TestGateCaller_WifiAdoptServesUser0(t *testing.T) {
	for _, uid := range []int{10123, 0} {
		gatePeer(t, uid)
		reply, logged := gateAdopt(t)
		if reply != "OK\n" {
			t.Errorf("peer %d: reply %q, want OK", uid, reply)
		}
		if want := "[logind] wifi-adopt pass 1: 2 added, 0 already saved, 1 FAILED\n"; logged != want {
			t.Errorf("peer %d: logged %q, want %q", uid, logged, want)
		}
	}
}

// gateLiveSession is TestTelLiveOwnedReply's fixture: a live session that owns one SIM.
func gateLiveSession(t *testing.T) string {
	t.Helper()
	useTempBindings(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	me := profileRefV2("alice", "pw")
	if err := writeBindings([]simBinding{
		{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{me, "pub"}}},
	}, nil); err != nil {
		t.Fatal(err)
	}
	return dest
}

func TestGateCaller_TelLiveOwnedRefusesRoamedPeer(t *testing.T) {
	dest := gateLiveSession(t)
	for _, uid := range []int{gateRoamedA, gateRoamedB, -1} {
		gatePeer(t, uid)
		if got := gateAsk(t, func(c net.Conn) { handleTelLiveOwned(c, dest) }); got != "NONE\n" {
			t.Errorf("peer %d: got %q, want NONE", uid, got)
		}
	}
}

func TestGateCaller_TelLiveOwnedServesUser0(t *testing.T) {
	dest := gateLiveSession(t)
	for _, uid := range []int{10123, 0} {
		gatePeer(t, uid)
		if got, want := gateAsk(t, func(c net.Conn) { handleTelLiveOwned(c, dest) }), "OK 10\n"+iccidX+"\n"; got != want {
			t.Errorf("peer %d: got %q, want %q", uid, got, want)
		}
	}
}
