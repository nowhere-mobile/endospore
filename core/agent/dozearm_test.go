package main

// NWP-20261117-06 (dn-1023 #3): DOZE-ARM and GET-DOZE-ARM. The gate tells the daemon whether a sign-in's Doze apply
// armed; the daemon keeps it in RAM per uid, gate-only, and answers the live session lock-free. test-doze-arm.sh
// breaks the handlers and the concurrentSafeCmd entry and requires a failing test for each.

import (
	"net"
	"testing"
	"time"
)

const dozeArmChooserApp = 10123

// dozeArmSetup starts each test from an empty mark map and a pinned gate chooser, and restores every seam after.
func dozeArmSetup(t *testing.T) {
	t.Helper()
	prevPin, prevOwner, prevSess := pinnedChooserApp, ownerPeerUID, sessionPeerUID
	dozeArmMu.Lock()
	prevMap := dozeUnarmed
	dozeUnarmed = map[string]bool{}
	dozeArmMu.Unlock()
	pinnedChooserApp = dozeArmChooserApp
	ownerPeerUID = func(net.Conn) int { return dozeArmChooserApp }
	t.Cleanup(func() {
		pinnedChooserApp, ownerPeerUID, sessionPeerUID = prevPin, prevOwner, prevSess
		dozeArmMu.Lock()
		dozeUnarmed = prevMap
		dozeArmMu.Unlock()
	})
}

// dozeArmPeer presents an app of Android user u as the caller, to both seams.
func dozeArmPeer(u int) {
	ownerPeerUID = func(net.Conn) int { return u*100000 + dozeArmChooserApp }
	sessionPeerUID = func(net.Conn) int { return u*100000 + dozeArmChooserApp }
}

// dozeArmSession writes the live session marker for uid into dest and presents that session's chooser as the caller.
func dozeArmSession(t *testing.T, dest, profile string, u int, uid string) {
	t.Helper()
	if err := markRoamSession(dest, profile, "pw", uid, ""); err != nil {
		t.Fatal(err)
	}
	dozeArmPeer(u)
}

func dozeArmMarks() int {
	dozeArmMu.Lock()
	defer dozeArmMu.Unlock()
	return len(dozeUnarmed)
}

func TestDozeArmRefusesANonGatePeer(t *testing.T) {
	dozeArmSetup(t)
	dest := t.TempDir()
	ownerPeerUID = func(net.Conn) int { return 11*100000 + dozeArmChooserApp } // the session's own chooser
	if got := driveLogin(t, dest, "DOZE-ARM\n11\nunarmed\n"); got != "DENIED" {
		t.Errorf("the session's chooser got %q, want DENIED", got)
	}
	ownerPeerUID = func(net.Conn) int { return dozeArmChooserApp + 1 } // another user-0 app
	if got := driveLogin(t, dest, "DOZE-ARM\n11\nunarmed\n"); got != "DENIED" {
		t.Errorf("another user-0 app got %q, want DENIED", got)
	}
	if n := dozeArmMarks(); n != 0 {
		t.Errorf("a refused DOZE-ARM recorded %d mark(s)", n)
	}
	dozeArmSession(t, dest, "dozearm-a", 11, "11")
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "ARMED" {
		t.Errorf("after two refused marks session 11 read %q, want ARMED", got)
	}
}

func TestDozeArmUnarmedOnlyForTheMarkedUid(t *testing.T) {
	dozeArmSetup(t)
	dest := t.TempDir()
	if got := driveLogin(t, dest, "DOZE-ARM\n11\nunarmed\n"); got != "OK" {
		t.Fatalf("the gate's DOZE-ARM got %q, want OK", got)
	}
	dozeArmSession(t, dest, "dozearm-b", 11, "11")
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "UNARMED" {
		t.Errorf("the marked session read %q, want UNARMED", got)
	}
	dozeArmSession(t, dest, "dozearm-c", 12, "12")
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "ARMED" {
		t.Errorf("an unmarked uid read %q, want ARMED", got)
	}
	ownerPeerUID = func(net.Conn) int { return dozeArmChooserApp }
	if got := driveLogin(t, dest, "DOZE-ARM\n11\narmed\n"); got != "OK" {
		t.Fatalf("the gate's DOZE-ARM got %q, want OK", got)
	}
	dozeArmSession(t, dest, "dozearm-b", 11, "11")
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "ARMED" {
		t.Errorf("after an armed mark session 11 read %q, want ARMED", got)
	}
}

func TestDozeArmNoneWithoutASession(t *testing.T) {
	dozeArmSetup(t)
	dozeArmPeer(11)
	if got := driveLogin(t, t.TempDir(), "GET-DOZE-ARM\n"); got != "NONE" {
		t.Errorf("with no session the reply was %q, want NONE", got)
	}
	ownerPeerUID = func(net.Conn) int { return dozeArmChooserApp }
	dest := t.TempDir()
	if got := driveLogin(t, dest, "DOZE-ARM\n11\nunarmed\n"); got != "OK" {
		t.Fatalf("the gate's DOZE-ARM got %q, want OK", got)
	}
	dozeArmSession(t, dest, "dozearm-d", 12, "11") // session 11 is live; an app of user 12 asks
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "NONE" {
		t.Errorf("another user's caller got %q, want NONE", got)
	}
}

func TestDozeArmMarkSurvivesAnotherUidsSignIn(t *testing.T) {
	dozeArmSetup(t)
	dest := t.TempDir()
	if got := driveLogin(t, dest, "DOZE-ARM\n11\nunarmed\n"); got != "OK" {
		t.Fatalf("the gate's DOZE-ARM got %q, want OK", got)
	}
	// Session 11 cold-locks; profile e signs in as user 12 and its apply arms.
	if got := driveLogin(t, dest, "DOZE-ARM\n12\narmed\n"); got != "OK" {
		t.Fatalf("the gate's DOZE-ARM got %q, want OK", got)
	}
	dozeArmSession(t, dest, "dozearm-e", 12, "12")
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "ARMED" {
		t.Errorf("session 12 read %q, want ARMED", got)
	}
	// Session 11 resumes from the cold lock: its mark is still there.
	dozeArmSession(t, dest, "dozearm-f", 11, "11")
	if got := driveLogin(t, dest, "GET-DOZE-ARM\n"); got != "UNARMED" {
		t.Errorf("session 11, resumed after user 12's sign-in, read %q, want UNARMED", got)
	}
}

func TestDozeArmAnswersWhileSessionMuIsHeld(t *testing.T) {
	dozeArmSetup(t)
	for _, v := range []string{"DOZE-ARM", "GET-DOZE-ARM"} {
		if !concurrentSafeCmd(v) {
			t.Errorf("concurrentSafeCmd(%q) is false: the verb would queue behind a seal", v)
		}
	}
	dest := t.TempDir()
	if err := markRoamSession(dest, "dozearm-g", "pw", "11", ""); err != nil {
		t.Fatal(err)
	}
	// A seal or a materialise can hold sessionMu for minutes; both verbs must answer through it.
	for _, c := range []struct{ req, want string }{
		{"DOZE-ARM\n11\nunarmed\n", "OK"},
		{"GET-DOZE-ARM\n", "UNARMED"},
	} {
		if c.want == "UNARMED" {
			dozeArmPeer(11)
		}
		sessionMu.Lock()
		done := make(chan string, 1)
		go func() { done <- driveLogin(t, dest, c.req) }()
		var got string
		select {
		case got = <-done:
			sessionMu.Unlock()
		case <-time.After(5 * time.Second):
			sessionMu.Unlock()
			<-done
			t.Fatalf("%q waited on sessionMu", c.req)
		}
		if got != c.want {
			t.Errorf("%q under a held sessionMu got %q, want %q", c.req, got, c.want)
		}
	}
}

func TestDozeArmRefusesABadRequest(t *testing.T) {
	dozeArmSetup(t)
	dest := t.TempDir()
	for _, req := range []string{"DOZE-ARM\nabc\nunarmed\n", "DOZE-ARM\n0\nunarmed\n", "DOZE-ARM\n11\nmaybe\n"} {
		if got := driveLogin(t, dest, req); got != "ERR request" {
			t.Errorf("%q got %q, want ERR request", req, got)
		}
	}
	if n := dozeArmMarks(); n != 0 {
		t.Errorf("a bad request recorded %d mark(s)", n)
	}
}
