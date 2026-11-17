package main

import (
	"net"
	"os"
	"testing"
	"time"
)

// Tests for the emergency-callback window verbs (NWP-20261206-02, Q047). They drive the real handleLogin, so on a
// main.go with no arm the request falls into the legacy login and every assertion fails.

const emwApp = 10123

const (
	emwMark   = "EMERGENCY-MARK\n"
	emwRecent = "EMERGENCY-RECENT\n"
)

// emwFixture pins the chooser, drives the peer and the boot clock, clears the mark, and shortens the connection
// deadline, so that on a main.go with no arm the legacy login fails in seconds.
func emwFixture(t *testing.T) (peer *int, now *int64) {
	t.Helper()
	oldPin, oldPeer, oldNow, oldDeadline := pinnedChooserApp, emergencyPeerUID, emergencyNowMs, loginConnDeadline
	p, n := emwApp, int64(1_000_000)
	pinnedChooserApp = emwApp
	emergencyPeerUID = func(net.Conn) int { return p }
	emergencyNowMs = func() int64 { return n }
	loginConnDeadline = 2 * time.Second
	t.Setenv("NOWHERE_STATE", t.TempDir())
	emergencyMarkedAtMs.Store(0)
	t.Cleanup(func() {
		pinnedChooserApp, emergencyPeerUID, emergencyNowMs, loginConnDeadline = oldPin, oldPeer, oldNow, oldDeadline
		emergencyMarkedAtMs.Store(0)
	})
	return &p, &n
}

func emwExpect(t *testing.T, dest, req, want string) {
	t.Helper()
	if got := driveLogin(t, dest, req); got != want {
		t.Fatalf("%q replied %q, want %q", req, got, want)
	}
}

// TestEmergencyWindowSurvivesUserSwitch: a mark from the gate (user 0) is seen by the chooser in a roamed user.
func TestEmergencyWindowSurvivesUserSwitch(t *testing.T) {
	peer, now := emwFixture(t)
	*peer = 0*100000 + emwApp
	emwExpect(t, t.TempDir(), emwMark, "OK")
	*peer = 11*100000 + emwApp
	emwExpect(t, t.TempDir(), emwRecent, "YES 0")
	*now += 61_000
	emwExpect(t, t.TempDir(), emwRecent, "YES 61")
}

// TestEmergencyWindowExpires: the window is 15 min on the boot clock, exclusive at the end.
func TestEmergencyWindowExpires(t *testing.T) {
	_, now := emwFixture(t)
	emwExpect(t, t.TempDir(), emwRecent, "NO")
	mark := *now
	emwExpect(t, t.TempDir(), emwMark, "OK")
	*now = mark + emergencyCallbackWindowMs - 1
	emwExpect(t, t.TempDir(), emwRecent, "YES 899")
	*now = mark + emergencyCallbackWindowMs
	emwExpect(t, t.TempDir(), emwRecent, "NO")
}

// TestEmergencyWindowRefusesOtherCallers: only the chooser app answers; a refused MARK records nothing.
func TestEmergencyWindowRefusesOtherCallers(t *testing.T) {
	peer, _ := emwFixture(t)
	for _, uid := range []int{-1, 0, 1000, emwApp + 1, 11*100000 + emwApp + 1} {
		*peer = uid
		for _, req := range []string{emwMark, emwRecent} {
			if got := driveLogin(t, t.TempDir(), req); got != "DENIED" {
				t.Fatalf("peer %d: %q replied %q, want DENIED", uid, req, got)
			}
		}
	}
	pinnedChooserApp = -1 // an unpinned daemon
	*peer = emwApp
	for _, req := range []string{emwMark, emwRecent} {
		if got := driveLogin(t, t.TempDir(), req); got != "DENIED" {
			t.Fatalf("unpinned daemon: %q replied %q, want DENIED", req, got)
		}
	}
	pinnedChooserApp = emwApp
	emwExpect(t, t.TempDir(), emwRecent, "NO")
}

// TestEmergencyWindowNeverWaitsOnLocks: both verbs answer while a session op holds sessionMu and a telephony op
// holds telMu. The 3 s bound is a deadlock guard, as in TestTelVerbsNeverWaitForSessionMu, not a speed bound.
func TestEmergencyWindowNeverWaitsOnLocks(t *testing.T) {
	emwFixture(t)
	sessionMu.Lock()
	telMu.Lock()
	held := true
	defer func() {
		if held {
			telMu.Unlock()
			sessionMu.Unlock()
		}
	}()
	for _, c := range []struct{ req, want string }{{emwMark, "OK"}, {emwRecent, "YES 0"}} {
		select {
		case got := <-driveLoginAsync(t, t.TempDir(), c.req):
			if got != c.want {
				t.Fatalf("%q replied %q while the locks were held, want %q", c.req, got, c.want)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%q waited on a lock: no reply in 3 s while sessionMu and telMu were held", c.req)
		}
	}
	telMu.Unlock()
	sessionMu.Unlock()
	held = false
}

// TestEmergencyWindowRAMOnly: neither verb writes a file under dest.
func TestEmergencyWindowRAMOnly(t *testing.T) {
	emwFixture(t)
	dest := t.TempDir()
	emwExpect(t, dest, emwMark, "OK")
	emwExpect(t, dest, emwRecent, "YES 0")
	ents, err := os.ReadDir(dest)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 0 {
		t.Fatalf("the verbs left %d entr(ies) under dest, first %q; the window is RAM only", len(ents), ents[0].Name())
	}
}

// TestEmergencyWindowClockUnreadable: an unreadable clock records nothing on MARK, and RECENT after a mark answers
// YES 0, so the call rings.
func TestEmergencyWindowClockUnreadable(t *testing.T) {
	_, now := emwFixture(t)
	*now = 0
	emwExpect(t, t.TempDir(), emwMark, "ERR clock")
	emwExpect(t, t.TempDir(), emwRecent, "NO")
	*now = 5000
	emwExpect(t, t.TempDir(), emwMark, "OK")
	*now = 0
	emwExpect(t, t.TempDir(), emwRecent, "YES 0")
}
